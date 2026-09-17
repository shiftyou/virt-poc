#!/bin/bash
# =============================================================================
# 06-resource-quota.sh
#
# ResourceQuota 실습 환경 구성
#   1. poc-resource-quota namespace 생성
#   2. CPU / Memory / Pod / PVC 등 ResourceQuota 적용
#   3. 2개 VM 배포 (Quota 내 통과) → 3번째 VM 생성 시도 → Quota 초과로 거부
#
# 사용법: ./06-resource-quota.sh
# =============================================================================

set -euo pipefail
trap '[[ "$BASH_COMMAND" =~ ^(oc|kubectl|virtctl) ]] && echo "+ $BASH_COMMAND"' DEBUG
trap 'echo -e "\n\033[0;31m[오류]\033[0m ${LINENO}번째 줄에서 명령 실패: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# env.conf 자동 로드 (단독 실행 시)
ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-resource-quota"

# 기본 VM/Quota 리소스 (런타임에 detect_node_resources로 재설정됨)
VM_CPU_REQUEST_M=750
VM_MEM_REQUEST_MI=1024
VM_CPU_REQUEST="750m"
VM_CPU_LIMIT="1500m"
VM_MEM_REQUEST="1Gi"
VM_MEM_LIMIT="2Gi"
QUOTA_CPU_REQUEST="2"
QUOTA_CPU_LIMIT="4"
QUOTA_MEM_REQUEST="4Gi"
QUOTA_MEM_LIMIT="8Gi"

if [ -f "${SCRIPT_DIR}/../utils/common.sh" ]; then
    source "${SCRIPT_DIR}/../utils/common.sh"
else
    # ── 독립 실행 모드: common.sh 없이 인라인 헬퍼 사용 ──
    RED='\033[0;31m'; GREEN='\033[0;32m'; DIM='\033[2m'
    POC_VERSION=$(cat "${SCRIPT_DIR}/../../VERSION" 2>/dev/null || echo "dev")
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
    auto_detect_operators() { :; }
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

# spec.running (deprecated) -> spec.runStrategy 마이그레이션
# admission webhook 경고 제거를 위해 oc patch vm 전에 호출
ensure_runstrategy() {
    local vm="$1" ns="$2"
    local running
    running=$(oc get vm "$vm" -n "$ns" \
        -o jsonpath='{.spec.running}' 2>/dev/null || true)
    [ -z "$running" ] && return 0
    local rs="Halted"
    [ "$running" = "true" ] && rs="Always"
    oc patch vm "$vm" -n "$ns" --type=json -p "[
      {\"op\":\"remove\",\"path\":\"/spec/running\"},
      {\"op\":\"add\",\"path\":\"/spec/runStrategy\",\"value\":\"${rs}\"}
    ]" &>/dev/null || true
}

# =============================================================================
# 워커 노드 리소스 감지 및 VM/Quota 값 계산
# =============================================================================
detect_node_resources() {
    print_step "워커 노드 리소스 감지"

    local raw_cpu raw_mem node_cpu_m node_mem_mi

    raw_cpu=$(oc get nodes -l node-role.kubernetes.io/worker \
        -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null || true)
    raw_mem=$(oc get nodes -l node-role.kubernetes.io/worker \
        -o jsonpath='{.items[0].status.allocatable.memory}' 2>/dev/null || true)

    if [ -z "$raw_cpu" ] || [ -z "$raw_mem" ]; then
        print_warn "노드 리소스를 감지할 수 없습니다 — 기본값 사용"
        return 1
    fi

    if [[ "$raw_cpu" =~ ^([0-9]+)m$ ]]; then
        node_cpu_m="${BASH_REMATCH[1]}"
    elif [[ "$raw_cpu" =~ ^[0-9]+$ ]]; then
        node_cpu_m=$(( raw_cpu * 1000 ))
    else
        print_warn "예상치 못한 CPU 형식: ${raw_cpu} — 기본값 사용"
        return 1
    fi

    if [[ "$raw_mem" =~ ^([0-9]+)Ki$ ]]; then
        node_mem_mi=$(( ${BASH_REMATCH[1]} / 1024 ))
    elif [[ "$raw_mem" =~ ^([0-9]+)Mi$ ]]; then
        node_mem_mi="${BASH_REMATCH[1]}"
    elif [[ "$raw_mem" =~ ^([0-9]+)Gi$ ]]; then
        node_mem_mi=$(( ${BASH_REMATCH[1]} * 1024 ))
    else
        print_warn "예상치 못한 메모리 형식: ${raw_mem} — 기본값 사용"
        return 1
    fi

    # VM request ≈ 노드 allocatable의 1/8, 250m / 256Mi 단위로 반올림
    VM_CPU_REQUEST_M=$(( (node_cpu_m / 8 / 250) * 250 ))
    (( VM_CPU_REQUEST_M < 250 )) && VM_CPU_REQUEST_M=250
    local vm_cpu_limit_m=$(( VM_CPU_REQUEST_M * 2 ))

    VM_MEM_REQUEST_MI=$(( (node_mem_mi / 8 / 256) * 256 ))
    (( VM_MEM_REQUEST_MI < 256 )) && VM_MEM_REQUEST_MI=256
    local vm_mem_limit_mi=$(( VM_MEM_REQUEST_MI * 2 ))

    # Quota = VM request의 2.5배 → 2개 VM 통과, 3번째 초과
    local quota_cpu_req_m=$(( VM_CPU_REQUEST_M * 5 / 2 ))
    local quota_cpu_lim_m=$(( quota_cpu_req_m * 2 ))
    local quota_mem_req_mi=$(( VM_MEM_REQUEST_MI * 5 / 2 ))
    local quota_mem_lim_mi=$(( quota_mem_req_mi * 2 ))

    VM_CPU_REQUEST="${VM_CPU_REQUEST_M}m"
    VM_CPU_LIMIT="${vm_cpu_limit_m}m"
    VM_MEM_REQUEST="${VM_MEM_REQUEST_MI}Mi"
    VM_MEM_LIMIT="${vm_mem_limit_mi}Mi"
    QUOTA_CPU_REQUEST="${quota_cpu_req_m}m"
    QUOTA_CPU_LIMIT="${quota_cpu_lim_m}m"
    QUOTA_MEM_REQUEST="${quota_mem_req_mi}Mi"
    QUOTA_MEM_LIMIT="${quota_mem_lim_mi}Mi"

    (( VM_MEM_REQUEST_MI % 1024 == 0 )) && VM_MEM_REQUEST="$(( VM_MEM_REQUEST_MI / 1024 ))Gi"
    (( vm_mem_limit_mi % 1024 == 0 )) && VM_MEM_LIMIT="$(( vm_mem_limit_mi / 1024 ))Gi"
    (( quota_mem_req_mi % 1024 == 0 )) && QUOTA_MEM_REQUEST="$(( quota_mem_req_mi / 1024 ))Gi"
    (( quota_mem_lim_mi % 1024 == 0 )) && QUOTA_MEM_LIMIT="$(( quota_mem_lim_mi / 1024 ))Gi"

    print_ok  "노드 allocatable: ${node_cpu_m}m CPU, ${node_mem_mi}Mi 메모리"
    print_info "  VM request : ${VM_CPU_REQUEST} cpu / ${VM_MEM_REQUEST} mem"
    print_info "  VM limit   : ${VM_CPU_LIMIT} cpu / ${VM_MEM_LIMIT} mem"
    print_info "  Quota req  : ${QUOTA_CPU_REQUEST} cpu / ${QUOTA_MEM_REQUEST} mem (2개 통과, 3번째 초과)"
    print_info "  Quota lim  : ${QUOTA_CPU_LIMIT} cpu / ${QUOTA_MEM_LIMIT} mem"
}

# =============================================================================
# 사전 점검
# =============================================================================
preflight() {
    print_step "사전 점검"
    auto_detect_operators

    # OpenShift Virtualization Operator 확인
    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator가 설치되지 않았습니다 → 건너뜀."
        print_warn "  설치 가이드: operators/kubevirt-hyperconverged-operator.md"
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

    print_info "  NS : ${NS}"
}

# =============================================================================
# Step 1: Namespace 생성
# =============================================================================
step_namespace() {
    print_step "1/4  Namespace 생성 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "Namespace $NS 이미 존재합니다 — 건너뜀"
    else
        print_info "Namespace $NS 생성 중..."
        oc new-project "$NS" > /dev/null
        if oc get namespace "$NS" &>/dev/null; then
            print_ok "Namespace $NS 생성됨"
        else
            print_error "Namespace $NS 생성 실패"
            return 1
        fi
    fi
}

# =============================================================================
# Step 2: ResourceQuota 적용 (detect_node_resources에서 계산된 값 사용)
# =============================================================================
step_quota() {
    print_step "2/4  ResourceQuota 적용 (${NS})"

    cat > resourcequota-poc.yaml <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: poc-quota
  namespace: ${NS}
spec:
  hard:
    pods: "10"
    requests.cpu: "${QUOTA_CPU_REQUEST}"
    limits.cpu: "${QUOTA_CPU_LIMIT}"
    requests.memory: ${QUOTA_MEM_REQUEST}
    limits.memory: ${QUOTA_MEM_LIMIT}
    persistentvolumeclaims: "10"
    requests.storage: 100Gi
    services: "10"
    services.loadbalancers: "2"
    services.nodeports: "0"
    configmaps: "20"
    secrets: "20"
EOF
    echo "생성된 파일: resourcequota-poc.yaml"
    print_info "ResourceQuota poc-quota 적용 중..."
    oc apply -f resourcequota-poc.yaml

    print_ok "ResourceQuota poc-quota 적용됨"
    print_info "  requests.cpu: ${QUOTA_CPU_REQUEST} (2개 VM × ${VM_CPU_REQUEST} = $(( VM_CPU_REQUEST_M * 2 ))m 통과, 3개 VM = $(( VM_CPU_REQUEST_M * 3 ))m 초과)"
}

# =============================================================================
# Step 3: ConsoleYAMLSample 등록
# =============================================================================
step_consoleyamlsamples() {
    print_step "3/4  ConsoleYAMLSample 등록"

    cat > consoleyamlsample-resourcequota.yaml <<'EOF'
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-resource-quota
spec:
  title: "POC ResourceQuota Configuration"
  description: "Limits resource usage such as CPU, Memory, Pod, and PVC in a namespace. Apply after creating the namespace. New resource creation is rejected when limits are exceeded."
  targetResource:
    apiVersion: v1
    kind: ResourceQuota
  yaml: |
    apiVersion: v1
    kind: ResourceQuota
    metadata:
      name: poc-quota
      namespace: poc-resource-quota    # Change to target namespace
    spec:
      hard:
        pods: "10"
        requests.cpu: "2"
        limits.cpu: "4"
        requests.memory: 4Gi
        limits.memory: 8Gi
        persistentvolumeclaims: "10"
        requests.storage: 100Gi
        services: "10"
        services.loadbalancers: "2"
        services.nodeports: "0"
        configmaps: "20"
        secrets: "20"
EOF
    echo "생성된 파일: consoleyamlsample-resourcequota.yaml"
    print_info "ConsoleYAMLSample poc-resource-quota 등록 중..."
    oc apply -f consoleyamlsample-resourcequota.yaml
    print_ok "ConsoleYAMLSample poc-resource-quota 등록됨"
}

# =============================================================================
# Step 4: VM 배포 및 Quota 초과 시연
#   - poc-quota-vm-1, poc-quota-vm-2: 생성 성공 (requests.cpu 합계 1500m < 2000m)
#   - poc-quota-vm-3: 생성 시도 → Quota 초과로 거부 (2250m > 2000m)
# =============================================================================
step_vms() {
    print_step "4/4  VM 배포 및 ResourceQuota 초과 시연"

    # VM 1, 2: 정상 생성
    for VM in poc-quota-vm-1 poc-quota-vm-2; do
        if oc get vm "$VM" -n "$NS" &>/dev/null; then
            print_ok "VM $VM 이미 존재합니다 — 건너뜀"
            continue
        fi

        print_info "VM $VM 생성 중..."
        oc process -n openshift poc -p NAME="$VM" | \
        sed 's/runStrategy: Always/runStrategy: Halted/' | sed 's/  running: false/  runStrategy: Halted/' > "${VM}.yaml"
        echo "생성된 파일: ${VM}.yaml"
        oc apply -n "$NS" -f "${VM}.yaml"

        ensure_runstrategy "$VM" "$NS"
        oc patch vm "$VM" -n "$NS" --type=merge -p "{
          \"spec\": {
            \"template\": {
              \"spec\": {
                \"evictionStrategy\": \"LiveMigrate\",
                \"domain\": {
                  \"resources\": {
                    \"requests\": {
                      \"cpu\": \"${VM_CPU_REQUEST}\",
                      \"memory\": \"${VM_MEM_REQUEST}\"
                    },
                    \"limits\": {
                      \"cpu\": \"${VM_CPU_LIMIT}\",
                      \"memory\": \"${VM_MEM_LIMIT}\"
                    }
                  }
                }
              }
            }
          }
        }"

        virtctl start "$VM" -n "$NS" 2>/dev/null || true
        print_ok "VM $VM 생성됨 (cpu request: ${VM_CPU_REQUEST})"
    done

    # VM 3: Quota 초과 시연
    VM3="poc-quota-vm-3"
    if oc get vm "$VM3" -n "$NS" &>/dev/null; then
        print_warn "VM $VM3 이미 존재합니다 — Quota 초과 시연을 건너뜁니다"
        return
    fi

    print_info ""
    print_info "━━━ Quota 초과 시연 ━━━"
    print_info "현재 requests.cpu 사용량: $(oc get resourcequota poc-quota -n "$NS" \
        -o jsonpath='{.status.used.requests\.cpu}' 2>/dev/null || echo '?') / 2"
    print_info "VM $VM3 생성 시도 (requests.cpu ${VM_CPU_REQUEST} 추가 → 초과 예상)"

    oc process -n openshift poc -p NAME="$VM3" | \
        sed 's/runStrategy: Always/runStrategy: Halted/' | sed 's/  running: false/  runStrategy: Halted/' > "${VM3}.yaml"
    echo "생성된 파일: ${VM3}.yaml"

    # Quota 초과는 virt-launcher Pod 생성 시 발생 → VM 오브젝트는 생성되지만 Pod 시작 불가
    oc apply -n "$NS" -f "${VM3}.yaml"

    ensure_runstrategy "$VM3" "$NS"
    oc patch vm "$VM3" -n "$NS" --type=merge -p "{
      \"spec\": {
        \"template\": {
          \"spec\": {
            \"evictionStrategy\": \"LiveMigrate\",
            \"domain\": {
              \"resources\": {
                \"requests\": {
                  \"cpu\": \"${VM_CPU_REQUEST}\",
                  \"memory\": \"${VM_MEM_REQUEST}\"
                },
                \"limits\": {
                  \"cpu\": \"${VM_CPU_LIMIT}\",
                  \"memory\": \"${VM_MEM_LIMIT}\"
                }
              }
            }
          }
        }
      }
    }"

    virtctl start "$VM3" -n "$NS" 2>/dev/null || true

    print_warn "VM $VM3 오브젝트 생성됨 — 시작 시 Quota 초과로 virt-launcher Pod가 거부됩니다."
    print_info "  확인: oc get events -n ${NS} --field-selector reason=FailedCreate"
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! ResourceQuota 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ResourceQuota 상태:"
    echo -e "    ${CYAN}oc describe resourcequota poc-quota -n ${NS}${NC}"
    echo ""
    echo -e "  VM 상태:"
    echo -e "    ${CYAN}oc get vm -n ${NS}${NC}"
    echo ""
    echo -e "  Quota 초과 이벤트 확인:"
    echo -e "    ${CYAN}oc get events -n ${NS} --field-selector reason=FailedCreate${NC}"
    echo ""
    echo -e "  Quota (노드에서 자동 감지):"
    echo -e "    requests.cpu: ${QUOTA_CPU_REQUEST}  limits.cpu: ${QUOTA_CPU_LIMIT}"
    echo -e "    requests.memory: ${QUOTA_MEM_REQUEST}  limits.memory: ${QUOTA_MEM_LIMIT}"
    echo ""
    echo -e "  예상 결과:"
    echo -e "    poc-quota-vm-1  → Running  (cpu request: ${VM_CPU_REQUEST})"
    echo -e "    poc-quota-vm-2  → Running  (cpu request: ${VM_CPU_REQUEST})"
    echo -e "    poc-quota-vm-3  → Pending  ($(( VM_CPU_REQUEST_M * 3 ))m > ${QUOTA_CPU_REQUEST} — Quota 초과로 virt-launcher Pod 거부됨)"
    echo ""
    echo -e "  자세한 내용: 06-resource-quota/06-resource-quota.md 참조"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 06-resource-quota 리소스 삭제"
    oc delete project poc-resource-quota --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-resource-quota --ignore-not-found 2>/dev/null || true
    print_ok "06-resource-quota 리소스 삭제됨"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  ResourceQuota 실습 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}  virt-poc ${POC_VERSION}${NC}"

    preflight
    detect_node_resources || true
    step_namespace
    step_quota
    step_consoleyamlsamples
    step_vms
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
