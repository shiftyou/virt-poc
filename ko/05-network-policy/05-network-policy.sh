#!/bin/bash
# =============================================================================
# 05-network-policy.sh
#
# NetworkPolicy (Pod 네트워크) 실습 환경 구성
#
#   - Namespace: poc-network-policy-1, poc-network-policy-2
#   - Policy: networking.k8s.io/v1 NetworkPolicy (Pod 네트워크 / eth0)
#     1. deny-all               : 모든 Ingress 차단
#     2. allow-same-network     : 동일 namespace 내 Pod 간 Ingress 허용
#     3. allow-access-from-ns1  : NS2에서 NS1 namespace Pod의 Ingress 허용
#
# 사용법: ./05-network-policy.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS1="poc-network-policy-1"
NS2="poc-network-policy-2"
TOTAL_STEPS=6

if [ -f "${SCRIPT_DIR}/../utils/common.sh" ]; then
    source "${SCRIPT_DIR}/../utils/common.sh"
else
    # ── 독립 실행 모드: common.sh 없이 인라인 헬퍼 사용 ──
    RED='\033[0;31m'; GREEN='\033[0;32m'; DIM='\033[2m'
    YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
    print_info()  { echo -e "${BLUE}[정보]${NC} $1"; }
    print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
    print_warn()  { echo -e "${YELLOW}[경고]${NC} $1"; }
    print_error() { echo -e "${RED}[오류]${NC} $1"; }
    print_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }
    print_header() {
        echo -e "\n${CYAN}================================================================${NC}"
        echo -e "${CYAN}  $1${NC}"
        echo -e "${CYAN}================================================================${NC}\n"
    }
    print_step_header() {
        echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}  $1  $2${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    }
    ask() {
        local prompt="$1" default="$2" var_name="$3" is_secret="${4:-false}"
        if [ "$is_secret" = "true" ]; then
            echo -n -e "${YELLOW}  $prompt${NC} [기본값: ****]: "; read -s input_val; echo
        else
            echo -n -e "${YELLOW}  $prompt${NC} [기본값: ${default}]: "; read input_val
        fi
        [ -z "$input_val" ] && input_val="$default"
        eval "$var_name='$input_val'"
    }
    save_to_env() {
        local key="$1" value="$2" env_file="${3:-${ENV_FILE:-}}"
        [ -z "$env_file" ] || [ ! -f "$env_file" ] && return 0
        if grep -q "^${key}=" "$env_file" 2>/dev/null; then
            if [[ "$OSTYPE" == darwin* ]]; then sed -i '' "s|^${key}=.*|${key}=${value}|" "$env_file"
            else sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"; fi
        else echo "${key}=${value}" >> "$env_file"; fi
    }
    load_or_ask() {
        local var_name="$1" prompt="$2" default="$3" is_secret="${4:-false}" current_val
        eval "current_val=\${${var_name}:-}"; [ -n "$current_val" ] && return 0
        ask "$prompt" "$default" "$var_name" "$is_secret"
        eval "local _val=\$$var_name"; save_to_env "$var_name" "$_val"
    }
    confirm_and_apply() {
        local file="$1" auto="${2:-true}"
        if [ "$auto" != "true" ]; then
            print_info "적용할 YAML:"; cat "$file"
            read -r -p "클러스터에 적용하시겠습니까? [y/N]: " confirm
            [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { print_warn "취소됨."; return 1; }
        fi
        oc apply -f "$file"
    }
    detect_worker_nodes() {
        WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        TEST_NODE=$(echo "$WORKER_NODES" | awk '{print $1}')
        [ -z "$WORKER_NODES" ] && { print_error "워커 노드를 찾을 수 없습니다."; exit 1; }
        print_info "워커 노드: ${WORKER_NODES}"
    }
    auto_detect_garage() {
        GARAGE_ENDPOINT=""; GARAGE_BUCKET="velero"; GARAGE_ACCESS_KEY="garage"
        GARAGE_SECRET_KEY="garage123"; GARAGE_FOUND=false
        local ns; ns=$(oc get svc -A -l app=garage -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
        if [ -n "$ns" ]; then
            local svc port
            svc=$(oc get svc -n "$ns" -l app=garage -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
                oc get svc -n "$ns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
            port=$(oc get svc -n "$ns" "$svc" -o jsonpath='{.spec.ports[?(@.name=="s3-api")].port}' 2>/dev/null || echo "3900")
            GARAGE_ENDPOINT="http://${svc}.${ns}.svc.cluster.local:${port}"
            local sn; sn=$(oc get secret -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
                tr ' ' '\n' | grep -iE "garage|credentials|s3" | head -1 || true)
            if [ -n "$sn" ]; then
                local ak sk
                ak=$(oc get secret -n "$ns" "$sn" -o jsonpath='{.data.accessKey}' 2>/dev/null | base64 -d 2>/dev/null || \
                    oc get secret -n "$ns" "$sn" -o jsonpath='{.data.access_key_id}' 2>/dev/null | base64 -d 2>/dev/null || true)
                sk=$(oc get secret -n "$ns" "$sn" -o jsonpath='{.data.secretKey}' 2>/dev/null | base64 -d 2>/dev/null || \
                    oc get secret -n "$ns" "$sn" -o jsonpath='{.data.secret_access_key}' 2>/dev/null | base64 -d 2>/dev/null || true)
                [ -n "$ak" ] && GARAGE_ACCESS_KEY="$ak"; [ -n "$sk" ] && GARAGE_SECRET_KEY="$sk"
            fi
            GARAGE_FOUND=true
            print_info "Garage endpoint : ${GARAGE_ENDPOINT}  (ns: ${ns})"
            print_info "Garage bucket   : ${GARAGE_BUCKET}"
            print_info "Garage accessKey: ${GARAGE_ACCESS_KEY}"
        else print_warn "Garage Service (app=garage) 감지 실패 → Garage 설정을 건너뜁니다."; fi
    }
    auto_detect_odf() {
        ODF_S3_ENDPOINT=""; ODF_S3_BUCKET="velero"; ODF_S3_REGION="localstorage"
        ODF_S3_ACCESS_KEY=""; ODF_S3_SECRET_KEY=""
        local ns="openshift-storage"
        ODF_S3_ENDPOINT=$(oc get noobaa -n "$ns" -o jsonpath='{.status.services.serviceS3.internalDNS[0]}' 2>/dev/null || true)
        if [ -z "$ODF_S3_ENDPOINT" ]; then
            local p; p=$(oc get svc s3 -n "$ns" -o jsonpath='{.spec.ports[?(@.name=="s3")].port}' 2>/dev/null || echo "80")
            ODF_S3_ENDPOINT="http://s3.${ns}.svc.cluster.local:${p}"
        fi
        ODF_S3_ACCESS_KEY=$(oc get secret noobaa-admin -n "$ns" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d 2>/dev/null || true)
        ODF_S3_SECRET_KEY=$(oc get secret noobaa-admin -n "$ns" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)
        if [ -n "$ODF_S3_ACCESS_KEY" ]; then
            print_info "ODF MCG S3 endpoint : ${ODF_S3_ENDPOINT}"
            print_info "ODF MCG region      : ${ODF_S3_REGION}"
            print_info "ODF MCG bucket      : ${ODF_S3_BUCKET}"
            print_info "ODF MCG 인증 정보   : noobaa-admin secret에서 가져옴"
        else print_warn "ODF MCG 인증 정보 감지 실패 (noobaa-admin secret 없음)"; fi
    }
fi

# =============================================================================
# 사전 점검
# =============================================================================
preflight() {
    print_step "사전 점검"

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator가 설치되지 않았습니다 → 건너뜀."
        exit 77
    fi

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 연결: $(oc whoami) @ $(oc whoami --show-server)"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_error "poc Template을 찾을 수 없습니다. 먼저 01-template을 실행하세요."
        exit 1
    fi
    print_ok "poc Template 확인됨"

    print_info "  NS1 : ${NS1}"
    print_info "  NS2 : ${NS2}"
}

# =============================================================================
# Step 1: Namespace 생성
# =============================================================================
step_namespaces() {
    print_step "1/${TOTAL_STEPS}  Namespace 생성"

    for NS in "$NS1" "$NS2"; do
        if oc get namespace "$NS" &>/dev/null; then
            print_ok "Namespace $NS 이미 존재합니다 — 건너뜀"
        else
            oc new-project "$NS" > /dev/null
            print_ok "Namespace $NS 생성됨"
        fi
        # namespaceSelector matchLabels에서 사용하는 레이블 설정
        # Kubernetes 1.21+에서 자동 할당되지만 누락 방지를 위해 명시적으로 설정
        oc label namespace "$NS" kubernetes.io/metadata.name="$NS" --overwrite > /dev/null
        print_ok "레이블 확인됨: kubernetes.io/metadata.name=${NS}"
    done
}

# =============================================================================
# Step 2: Default Deny All 정책
# =============================================================================
step_deny_all() {
    print_step "2/${TOTAL_STEPS}  Default Deny All 정책 적용"

    for NS in "$NS1" "$NS2"; do
        cat > "netpol-deny-all-${NS}.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
  namespace: ${NS}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
EOF
        echo "생성된 파일: netpol-deny-all-${NS}.yaml"
        oc apply -f "netpol-deny-all-${NS}.yaml"
        print_ok "deny-all 적용됨 (namespace: ${NS})"
    done
}

# =============================================================================
# Step 3: Allow Same Network 정책
# =============================================================================
step_allow_same_network() {
    print_step "3/${TOTAL_STEPS}  Allow Same Network 정책 적용"

    for NS in "$NS1" "$NS2"; do
        cat > "netpol-allow-same-network-${NS}.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-network
  namespace: ${NS}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}
EOF
        echo "생성된 파일: netpol-allow-same-network-${NS}.yaml"
        oc apply -f "netpol-allow-same-network-${NS}.yaml"
        print_ok "allow-same-network 적용됨 (namespace: ${NS})"
    done
}

# =============================================================================
# Step 4: Allow Access From NS1 정책 (NS2에만 적용)
# =============================================================================
step_allow_from_ns1() {
    print_step "4/${TOTAL_STEPS}  Allow Access From ${NS1} 정책 적용 (${NS2})"

    cat > "netpol-allow-from-ns1-${NS2}.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-access-from-project1
  namespace: ${NS2}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ${NS1}
EOF
    echo "생성된 파일: netpol-allow-from-ns1-${NS2}.yaml"
    oc apply -f "netpol-allow-from-ns1-${NS2}.yaml"
    print_ok "allow-access-from-project1 적용됨 (namespace: ${NS2}, 허용 소스: ${NS1})"
}

# =============================================================================
# Step 5: VM 배포
# =============================================================================
step_vms() {
    print_step "5/${TOTAL_STEPS}  VM 배포 (poc template)"

    for NS in "$NS1" "$NS2"; do
        local suffix
        suffix=$(echo "$NS" | awk -F'-' '{print $NF}')
        local VM_NAME="poc-vm-${suffix}"

        if oc get vm "$VM_NAME" -n "$NS" &>/dev/null; then
            print_ok "VM $VM_NAME 이미 존재합니다 (namespace: $NS) — 건너뜀"
            continue
        fi

        oc process -n openshift poc -p NAME="$VM_NAME" | \
            sed 's/runStrategy: Always/runStrategy: Halted/' | \
            sed 's/  running: false/  runStrategy: Halted/' > "${VM_NAME}-${NS}.yaml"
        echo "생성된 파일: ${VM_NAME}-${NS}.yaml"
        oc apply -n "$NS" -f "${VM_NAME}-${NS}.yaml"

        virtctl start "$VM_NAME" -n "$NS" 2>/dev/null || true
        print_ok "VM $VM_NAME 배포됨 (namespace: $NS)"
    done
}

# =============================================================================
# Step 6: ConsoleYAMLSample 등록
# =============================================================================
step_consoleyamlsamples() {
    print_step "6/${TOTAL_STEPS}  ConsoleYAMLSample 등록"

    # Deny All 샘플
    cat > consoleyamlsample-deny-all.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-netpol-deny-all
spec:
  title: "POC NetworkPolicy — Deny All"
  description: "Blocks all Ingress for the namespace."
  targetResource:
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
  yaml: |
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: deny-all
      namespace: ${NS1}
    spec:
      podSelector: {}
      policyTypes:
        - Ingress
EOF
    echo "생성된 파일: consoleyamlsample-deny-all.yaml"
    oc apply -f consoleyamlsample-deny-all.yaml
    print_ok "ConsoleYAMLSample poc-netpol-deny-all 등록됨"

    # Allow Same Network 샘플
    cat > consoleyamlsample-allow-same-network.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-netpol-allow-same-network
spec:
  title: "POC NetworkPolicy — Allow Same Network"
  description: "Allows Ingress communication between Pods in the same namespace."
  targetResource:
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
  yaml: |
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: allow-same-network
      namespace: ${NS1}
    spec:
      podSelector: {}
      policyTypes:
        - Ingress
      ingress:
        - from:
            - podSelector: {}
EOF
    echo "생성된 파일: consoleyamlsample-allow-same-network.yaml"
    oc apply -f consoleyamlsample-allow-same-network.yaml
    print_ok "ConsoleYAMLSample poc-netpol-allow-same-network 등록됨"

    # Allow Access From Project1 샘플
    cat > consoleyamlsample-allow-from-project1.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-netpol-allow-from-project1
spec:
  title: "POC NetworkPolicy — Allow Access From Project1"
  description: "Allows Ingress access from a specific namespace (project1)."
  targetResource:
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
  yaml: |
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: allow-access-from-project1
      namespace: ${NS2}
    spec:
      podSelector: {}
      policyTypes:
        - Ingress
      ingress:
        - from:
            - namespaceSelector:
                matchLabels:
                  kubernetes.io/metadata.name: ${NS1}
EOF
    echo "생성된 파일: consoleyamlsample-allow-from-project1.yaml"
    oc apply -f consoleyamlsample-allow-from-project1.yaml
    print_ok "ConsoleYAMLSample poc-netpol-allow-from-project1 등록됨"
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! NetworkPolicy 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  적용된 NetworkPolicy:"
    echo -e "    - deny-all                  : 모든 Ingress 차단 (${NS1}, ${NS2})"
    echo -e "    - allow-same-network        : namespace 내부 통신 허용 (${NS1}, ${NS2})"
    echo -e "    - allow-access-from-project1: ${NS1} → ${NS2} Ingress 허용"
    echo ""
    echo -e "  정책 확인:"
    echo -e "    ${CYAN}oc get networkpolicy -n ${NS1}${NC}"
    echo -e "    ${CYAN}oc get networkpolicy -n ${NS2}${NC}"
    echo ""
    echo -e "  VM 상태 확인:"
    echo -e "    ${CYAN}oc get vmi -n ${NS1}${NC}"
    echo -e "    ${CYAN}oc get vmi -n ${NS2}${NC}"
    echo ""
    echo -e "  다음 단계: 05-network-policy.md 참조"
    echo -e "    1. VM 시작 후 VM 콘솔에서 통신 테스트 수행"
    echo -e "    2. ${NS1} VM → ${NS2} VM: 허용됨 (allow-access-from-project1)"
    echo -e "    3. ${NS2} VM → ${NS1} VM: 차단됨 (deny-all)"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 05-network-policy 리소스 삭제"
    oc delete project poc-network-policy-1 poc-network-policy-2 --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample \
        poc-netpol-deny-all \
        poc-netpol-allow-same-network \
        poc-netpol-allow-from-project1 \
        --ignore-not-found 2>/dev/null || true
    print_ok "05-network-policy 리소스 삭제됨"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  05-network-policy: NetworkPolicy 실습${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespaces
    step_deny_all
    step_allow_same_network
    step_allow_from_ns1
    step_vms
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
