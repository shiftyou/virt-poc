#!/bin/bash
# =============================================================================
# 05-network-policy.sh
#
# NetworkPolicy / MultiNetworkPolicy 실습 환경 구성
#
#   방법 1 — NetworkPolicy (eth0, pod network)
#     Namespace: poc-network-policy-1, poc-network-policy-2
#
#   방법 2 — MultiNetworkPolicy (eth1, OVN localnet secondary NIC)
#     Namespace: poc-multi-network-policy-1, poc-multi-network-policy-2
#     사전 요구: 02-network OVS Bridge (ovs-bridge) + useMultiNetworkPolicy
#
# 사용법: ./05-network-policy.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

POLICY_MODE="${POLICY_MODE:-}"
NNCP_IFACE_TYPE="${NNCP_IFACE_TYPE:-linux-bridge}"
NET_TYPE="${NET_TYPE:-1}"
NAD_NAME="${NAD_NAME:-}"
LOCALNET_NAME="${LOCALNET_NAME:-poc-localnet}"
VLAN_ID="${VLAN_ID:-100}"
SECONDARY_IP_PREFIX="${SECONDARY_IP_PREFIX:-192.168.200}"
SECONDARY_IP_START="${SECONDARY_IP_START:-60}"
NS1="poc-network-policy-1"
NS2="poc-network-policy-2"
TOTAL_STEPS=6
POLICY_KIND="networkpolicy"
SECONDARY_IFACE="secondary"

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
# 정책 방식 선택
# =============================================================================
choose_policy_mode() {
    if [ -n "$POLICY_MODE" ]; then
        configure_from_mode
        return 0
    fi

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  정책 방식 선택${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} NetworkPolicy (eth0, pod network)"
    echo -e "     ${DIM}02-network Linux Bridge / Bond / VLAN${NC}"
    echo ""
    echo -e "  ${GREEN}2)${NC} MultiNetworkPolicy (eth1, OVN localnet secondary NIC)"
    echo -e "     ${DIM}02-network OVS Bridge + useMultiNetworkPolicy${NC}"
    echo ""

    local selection
    read -r -p "  선택 [1/2, 기본값: 1]: " selection
    [ -z "$selection" ] && selection="1"
    case "$selection" in
        1) POLICY_MODE="1" ;;
        2) POLICY_MODE="2" ;;
        *)
            print_error "1 또는 2를 입력해 주세요."
            exit 1
            ;;
    esac
    save_to_env "POLICY_MODE" "$POLICY_MODE"
    configure_from_mode
}

configure_from_mode() {
    case "$POLICY_MODE" in
        2)
            NS1="poc-multi-network-policy-1"
            NS2="poc-multi-network-policy-2"
            TOTAL_STEPS=8
            POLICY_KIND="multinetworkpolicy"
            ;;
        *)
            POLICY_MODE="1"
            NS1="poc-network-policy-1"
            NS2="poc-network-policy-2"
            TOTAL_STEPS=6
            POLICY_KIND="networkpolicy"
            ;;
    esac
}

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

    if [ "$POLICY_MODE" = "2" ]; then
        if [ -n "${NNCP_NAME:-}" ] && oc get nncp "$NNCP_NAME" &>/dev/null; then
            detect_nncp_type "$NNCP_NAME"
        fi
        resolve_nad_name
        save_network_env
        if [ "$NNCP_IFACE_TYPE" != "ovs-bridge" ]; then
            print_warn "MultiNetworkPolicy는 OVN localnet(02-network OVS Bridge)이 권장됩니다."
            print_warn "  현재 NNCP_IFACE_TYPE=${NNCP_IFACE_TYPE} — 계속 진행합니다."
        fi
        print_info "  NAD_NAME         : ${NAD_NAME}"
        print_info "  LOCALNET_NAME    : ${LOCALNET_NAME}"
    fi

    print_info "  POLICY_MODE      : ${POLICY_MODE} (${POLICY_KIND})"
    print_info "  NS1              : ${NS1}"
    print_info "  NS2              : ${NS2}"
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
# Step 2 (mode 2): MultiNetworkPolicy 활성화
# =============================================================================
step_enable_mnp() {
    [ "$POLICY_MODE" != "2" ] && return 0
    print_step "2/${TOTAL_STEPS}  MultiNetworkPolicy 활성화"

    local enabled
    enabled=$(oc get network.operator.openshift.io cluster \
        -o jsonpath='{.spec.useMultiNetworkPolicy}' 2>/dev/null || true)
    if [ "$enabled" = "true" ]; then
        print_ok "useMultiNetworkPolicy 이미 활성화됨"
        return 0
    fi

    oc patch network.operator.openshift.io cluster --type=merge \
        -p '{"spec":{"useMultiNetworkPolicy":true}}'
    print_ok "useMultiNetworkPolicy 활성화됨"
}

# =============================================================================
# Step 3 (mode 2): NAD 등록
# =============================================================================
step_nad() {
    [ "$POLICY_MODE" != "2" ] && return 0
    print_step "3/${TOTAL_STEPS}  NAD 등록 (${NAD_NAME})"

    for NS in "$NS1" "$NS2"; do
        if oc get network-attachment-definition "$NAD_NAME" -n "$NS" &>/dev/null; then
            print_ok "NAD ${NAD_NAME} 이미 존재 (namespace: ${NS}) — 건너뜀"
            continue
        fi

        local nad_file="nad-${NAD_NAME}-${NS}.yaml"
        if [ "$NET_TYPE" = "2" ]; then
            cat > "$nad_file" <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${NS}
spec:
  config: |-
    {
        "cniVersion": "0.3.1",
        "name": "${LOCALNET_NAME}",
        "type": "ovn-k8s-cni-overlay",
        "topology": "localnet",
        "vlanID": ${VLAN_ID},
        "netAttachDefName": "${NS}/${NAD_NAME}"
    }
EOF
        else
            cat > "$nad_file" <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${NS}
spec:
  config: |-
    {
        "cniVersion": "0.3.1",
        "name": "${LOCALNET_NAME}",
        "type": "ovn-k8s-cni-overlay",
        "topology": "localnet",
        "netAttachDefName": "${NS}/${NAD_NAME}"
    }
EOF
        fi
        echo "생성된 파일: ${nad_file}"
        oc apply -f "$nad_file"
        print_ok "NAD ${NAD_NAME} 등록됨 (namespace: ${NS})"
    done
}

_policy_step_num() {
    case "$POLICY_MODE" in
        2) echo "$(( $1 + 2 ))" ;;
        *) echo "$1" ;;
    esac
}

# =============================================================================
# Default Deny All 정책
# =============================================================================
step_deny_all() {
    local step
    step=$(_policy_step_num 2)
    print_step "${step}/${TOTAL_STEPS}  Default Deny All 정책 적용"

    for NS in "$NS1" "$NS2"; do
        if [ "$POLICY_MODE" = "2" ]; then
            cat > "multi-netpol-deny-all-${NS}.yaml" <<EOF
apiVersion: k8s.cni.cncf.io/v1beta1
kind: MultiNetworkPolicy
metadata:
  name: deny-all
  namespace: ${NS}
  annotations:
    k8s.v1.cni.cncf.io/policy-for: ${NS}/${NAD_NAME}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
EOF
            echo "생성된 파일: multi-netpol-deny-all-${NS}.yaml"
            oc apply -f "multi-netpol-deny-all-${NS}.yaml"
        else
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
        fi
        print_ok "deny-all 적용됨 (namespace: ${NS})"
    done
}

# =============================================================================
# Step 3: Allow Same Network 정책
# =============================================================================
step_allow_same_network() {
    local step
    step=$(_policy_step_num 3)
    print_step "${step}/${TOTAL_STEPS}  Allow Same Network 정책 적용"

    for NS in "$NS1" "$NS2"; do
        if [ "$POLICY_MODE" = "2" ]; then
            cat > "multi-netpol-allow-same-network-${NS}.yaml" <<EOF
apiVersion: k8s.cni.cncf.io/v1beta1
kind: MultiNetworkPolicy
metadata:
  name: allow-same-network
  namespace: ${NS}
  annotations:
    k8s.v1.cni.cncf.io/policy-for: ${NS}/${NAD_NAME}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}
EOF
            echo "생성된 파일: multi-netpol-allow-same-network-${NS}.yaml"
            oc apply -f "multi-netpol-allow-same-network-${NS}.yaml"
        else
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
        fi
        print_ok "allow-same-network 적용됨 (namespace: ${NS})"
    done
}

# =============================================================================
# Step 4: Allow Access From NS1 정책 (NS2에만 적용)
# =============================================================================
step_allow_from_ns1() {
    local step
    step=$(_policy_step_num 4)
    print_step "${step}/${TOTAL_STEPS}  Allow Access From ${NS1} 정책 적용 (${NS2})"

    if [ "$POLICY_MODE" = "2" ]; then
        cat > "multi-netpol-allow-from-ns1-${NS2}.yaml" <<EOF
apiVersion: k8s.cni.cncf.io/v1beta1
kind: MultiNetworkPolicy
metadata:
  name: allow-access-from-project1
  namespace: ${NS2}
  annotations:
    k8s.v1.cni.cncf.io/policy-for: ${NS2}/${NAD_NAME}
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
        echo "생성된 파일: multi-netpol-allow-from-ns1-${NS2}.yaml"
        oc apply -f "multi-netpol-allow-from-ns1-${NS2}.yaml"
    else
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
    fi
    print_ok "allow-access-from-project1 적용됨 (namespace: ${NS2}, 허용 소스: ${NS1})"
}

# =============================================================================
# Step 5: VM 배포
# =============================================================================
step_vms() {
    local step
    step=$(_policy_step_num 5)
    print_step "${step}/${TOTAL_STEPS}  VM 배포 (poc template)"

    local ip_suffixes=($(( SECONDARY_IP_START + 4 )) $(( SECONDARY_IP_START + 5 )))
    local idx=0

    for NS in "$NS1" "$NS2"; do
        local suffix ip_suffix
        suffix=$(echo "$NS" | awk -F'-' '{print $NF}')
        ip_suffix="${ip_suffixes[$idx]}"
        idx=$((idx + 1))
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
        ensure_runstrategy "$VM_NAME" "$NS"

        if [ "$POLICY_MODE" = "2" ]; then
            oc patch vm "$VM_NAME" -n "$NS" --type=json -p="[
              {
                \"op\": \"add\",
                \"path\": \"/spec/template/spec/domain/devices/interfaces/-\",
                \"value\": {\"name\": \"${SECONDARY_IFACE}\", \"bridge\": {}, \"model\": \"virtio\"}
              },
              {
                \"op\": \"add\",
                \"path\": \"/spec/template/spec/networks/-\",
                \"value\": {\"name\": \"${SECONDARY_IFACE}\", \"multus\": {\"networkName\": \"${NAD_NAME}\"}}
              }
            ]"

            local ci_idx
            ci_idx=$(oc get vm "$VM_NAME" -n "$NS" \
                -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' 2>/dev/null | \
                grep -n "cloudinitdisk" | cut -d: -f1 | head -1)
            [ -n "$ci_idx" ] && ci_idx=$(( ci_idx - 1 ))

            if [ -n "$ci_idx" ]; then
                oc patch vm "$VM_NAME" -n "$NS" --type=json -p="[
                  {\"op\": \"add\",
                   \"path\": \"/spec/template/spec/volumes/${ci_idx}/cloudInitNoCloud/networkData\",
                   \"value\": \"version: 2\\nethernets:\\n  eth1:\\n    dhcp4: false\\n    addresses:\\n      - ${SECONDARY_IP_PREFIX}.${ip_suffix}/24\\n    gateway4: ${SECONDARY_IP_PREFIX}.1\\n    nameservers:\\n      addresses:\\n        - 8.8.8.8\\n\"}
                ]"
                print_ok "networkData 추가됨 (eth1: ${SECONDARY_IP_PREFIX}.${ip_suffix}/24)"
            else
                print_warn "cloudinitdisk volume을 찾을 수 없습니다. networkData가 설정되지 않았습니다."
            fi
            virtctl start "$VM_NAME" -n "$NS" 2>/dev/null || true
            print_ok "VM $VM_NAME 배포됨 (eth0: masquerade, eth1: ${NAD_NAME}, IP: ${SECONDARY_IP_PREFIX}.${ip_suffix}/24)"
        else
            virtctl start "$VM_NAME" -n "$NS" 2>/dev/null || true
            print_ok "VM $VM_NAME 배포됨 (namespace: $NS, eth0 pod network)"
        fi
    done
}

# =============================================================================
# Step 6: ConsoleYAMLSample 등록
# =============================================================================
step_consoleyamlsamples() {
    local step
    step=$(_policy_step_num 6)
    print_step "${step}/${TOTAL_STEPS}  ConsoleYAMLSample 등록"

    if [ "$POLICY_MODE" = "2" ]; then
        cat > consoleyamlsample-multi-deny-all.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-multi-netpol-deny-all
spec:
  title: "POC MultiNetworkPolicy — Deny All"
  description: "Blocks all Ingress on the secondary NIC (OVN localnet)."
  targetResource:
    apiVersion: k8s.cni.cncf.io/v1beta1
    kind: MultiNetworkPolicy
  yaml: |
    apiVersion: k8s.cni.cncf.io/v1beta1
    kind: MultiNetworkPolicy
    metadata:
      name: deny-all
      namespace: ${NS1}
      annotations:
        k8s.v1.cni.cncf.io/policy-for: ${NS1}/${NAD_NAME}
    spec:
      podSelector: {}
      policyTypes:
        - Ingress
EOF
        echo "생성된 파일: consoleyamlsample-multi-deny-all.yaml"
        oc apply -f consoleyamlsample-multi-deny-all.yaml
        print_ok "ConsoleYAMLSample poc-multi-netpol-deny-all 등록됨"
        return 0
    fi

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
    if [ "$POLICY_MODE" = "2" ]; then
        echo -e "${GREEN}  완료! MultiNetworkPolicy 실습 환경이 준비되었습니다.${NC}"
    else
        echo -e "${GREEN}  완료! NetworkPolicy 실습 환경이 준비되었습니다.${NC}"
    fi
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    if [ "$POLICY_MODE" = "2" ]; then
        echo -e "  적용된 MultiNetworkPolicy (NAD: ${NAD_NAME}):"
        echo -e "    ${CYAN}oc get multinetworkpolicy -n ${NS1}${NC}"
        echo -e "    ${CYAN}oc get multinetworkpolicy -n ${NS2}${NC}"
        echo ""
        echo -e "  VM secondary NIC IP 확인:"
        echo -e "    ${CYAN}oc get vmi -n ${NS1} -o jsonpath='{.items[0].status.interfaces[?(@.name==\"${SECONDARY_IFACE}\")].ipAddress}'${NC}"
    else
        echo -e "  적용된 NetworkPolicy:"
        echo -e "    ${CYAN}oc get networkpolicy -n ${NS1}${NC}"
        echo -e "    ${CYAN}oc get networkpolicy -n ${NS2}${NC}"
    fi
    echo ""
    echo -e "  VM 상태 확인:"
    echo -e "    ${CYAN}oc get vmi -n ${NS1}${NC}"
    echo -e "    ${CYAN}oc get vmi -n ${NS2}${NC}"
    echo ""
    echo -e "  다음 단계: 05-network-policy.md 참조"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 05-network-policy 리소스 삭제"
    oc delete project poc-network-policy-1 poc-network-policy-2 \
        poc-multi-network-policy-1 poc-multi-network-policy-2 \
        --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample \
        poc-netpol-deny-all \
        poc-netpol-allow-same-network \
        poc-netpol-allow-from-project1 \
        poc-multi-netpol-deny-all \
        --ignore-not-found 2>/dev/null || true
    print_ok "05-network-policy 리소스 삭제됨"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  05-network-policy: NetworkPolicy / MultiNetworkPolicy 실습${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    choose_policy_mode
    preflight
    step_namespaces
    step_enable_mnp
    step_nad
    step_deny_all
    step_allow_same_network
    step_allow_from_ns1
    step_vms
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
