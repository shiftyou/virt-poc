#!/bin/bash
# =============================================================================
# 02-network.sh
#
# NNCP(NodeNetworkConfigurationPolicy) + NAD(NetworkAttachmentDefinition) 구성
# NAD 방식(VLAN 여부)과 NNCP 인터페이스 유형을 나눠 선택합니다.
#
# NAD:
#   1. 기본            — VLAN 없음
#   2. VLAN filtering  — NAD에 VLAN ID
#
# NNCP (새 생성 시):
#   1. Linux Bridge        — type: linux-bridge
#   2. OVS Bridge          — type: ovs-bridge + OVN localnet
#   3. Bond + Linux Bridge — type: bond + linux-bridge
#   4. VLAN + Linux Bridge — type: vlan + linux-bridge
#
# 사용법: ./02-network.sh
# =============================================================================

set -euo pipefail
trap 'echo -e "\n\033[0;31m[오류]\033[0m ${LINENO}번째 줄에서 명령 실패: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

BRIDGE_INTERFACE="${BRIDGE_INTERFACE:-ens4}"
BRIDGE_NAME="${BRIDGE_NAME:-br1}"
NNCP_NAME="${NNCP_NAME:-${BRIDGE_NAME}-nncp}"
NAD_NAMESPACE="poc-network"
VLAN_ID="${VLAN_ID:-100}"
SECONDARY_IP_PREFIX="${SECONDARY_IP_PREFIX:-192.168.200}"
SECONDARY_IP_START="${SECONDARY_IP_START:-60}"

# 방식별로 설정되는 변수
NET_TYPE=""
NAD_NAME=""
NNCP_IFACE_TYPE="${NNCP_IFACE_TYPE:-linux-bridge}"
LOCALNET_NAME="${LOCALNET_NAME:-poc-localnet}"
BOND_NAME="${BOND_NAME:-bond0}"
BOND_MODE="${BOND_MODE:-active-backup}"
BOND_INTERFACE_2="${BOND_INTERFACE_2:-}"

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
# 네트워크 방식 선택
# =============================================================================
choose_mode() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  NAD 구성 방식 선택${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} 기본 (VLAN 없음)"
    echo -e "     ${DIM}Linux Bridge / Bond → cnv-bridge  |  OVS → ovn-k8s-cni-overlay${NC}"
    echo ""
    echo -e "  ${GREEN}2)${NC} VLAN filtering (NAD에 VLAN ID 지정)"
    echo -e "     ${DIM}Linux Bridge trunk 또는 OVN localnet + vlanID${NC}"
    echo ""
    echo -e "  ${DIM}NNCP 인터페이스 유형(Linux Bridge / OVS / Bond / VLAN)은 새 NNCP를 만들 때 선택합니다.${NC}"
    echo ""
    echo -e "  현재 설정:"
    echo -e "    NNCP_NAME        : ${CYAN}${NNCP_NAME}${NC}"
    echo -e "    BRIDGE_NAME      : ${CYAN}${BRIDGE_NAME}${NC}"
    echo -e "    BRIDGE_INTERFACE : ${CYAN}${BRIDGE_INTERFACE}${NC}"
    echo -e "    Namespace        : ${CYAN}${NAD_NAMESPACE}${NC}"
    echo ""
    read -r -p "  선택 [1-2]: " NET_TYPE

    case "$NET_TYPE" in
        1)
            print_ok "선택됨: NAD 기본 (VLAN 없음)"
            ;;
        2)
            echo ""
            read -r -p "  VLAN ID 입력 [기본값: ${VLAN_ID}]: " input_vlan
            [ -n "$input_vlan" ] && VLAN_ID="$input_vlan"
            print_ok "선택됨: NAD VLAN filtering (VLAN ${VLAN_ID})"
            save_to_env "VLAN_ID" "$VLAN_ID"
            ;;
        *)
            print_error "1 또는 2를 입력해 주세요."
            exit 1
            ;;
    esac
    save_to_env "NET_TYPE" "$NET_TYPE"
}

# =============================================================================
# 사전 점검
# =============================================================================
preflight() {
    print_step "사전 점검"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 연결: $(oc whoami) @ $(oc whoami --show-server)"

    # NNCP 정보 표시
    echo ""
    print_info "── NNCP 정보 ──"
    print_info "  NNCP_NAME       : ${NNCP_NAME}"
    print_info "  BRIDGE_NAME     : ${BRIDGE_NAME}"
    print_info "  BRIDGE_INTERFACE: ${BRIDGE_INTERFACE}"
    _nncp_avail=$(oc get nncp "${NNCP_NAME}" \
        -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
    if [ -n "$_nncp_avail" ]; then
        print_info "  클러스터 NNCP 상태: Available=${_nncp_avail}"
        oc get nnce 2>/dev/null | grep "${NNCP_NAME}" | \
            awk '{printf "    %-40s %s\n", $1, $2}' || true
    else
        print_info "  클러스터 NNCP 상태: 미적용 (새로 생성됩니다)"
    fi

    if [ "${NMSTATE_INSTALLED:-false}" != "true" ]; then
        if ! oc get csv -A 2>/dev/null | grep -qi "kubernetes-nmstate"; then
            print_warn "Kubernetes NMState Operator가 설치되지 않았습니다 → 건너뜀."
            print_warn "  설치 가이드: operators/nmstate-operator.md"
            exit 77
        fi
    fi
    print_ok "NMState Operator 확인됨"

    if ! oc get nmstate 2>/dev/null | grep -q "."; then
        print_warn "NMState CR을 찾을 수 없습니다. NMState 인스턴스를 생성합니다..."
        cat > nmstate-cr.yaml <<'NMEOF'
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
NMEOF
        print_info "NMState CR 생성 중..."
        oc apply -f nmstate-cr.yaml
        print_info "NMState handler가 준비될 때까지 대기 중 (최대 60초)..."
        oc rollout status daemonset/nmstate-handler -n openshift-nmstate --timeout=60s 2>/dev/null || true
        if oc get nmstate nmstate &>/dev/null; then
            print_ok "NMState CR 생성됨"
        else
            print_error "NMState CR 생성 실패"
            return 1
        fi
    else
        print_ok "NMState CR 확인됨"
    fi
}

# =============================================================================
# NNCP 적용 완료 대기
# =============================================================================
_wait_nncp() {
    local name="$1"
    print_info "NNCP 적용됨 — 노드 설정 전파를 대기 중..."
    local retries=24 i=0
    while [ "$i" -lt "$retries" ]; do
        local status reason
        status=$(oc get nncp "$name" \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
        if [ "$status" = "True" ]; then
            print_ok "NNCP ${name} Available"
            break
        fi
        reason=$(oc get nncp "$name" \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].reason}' 2>/dev/null || echo "")
        printf "  [%d/%d] 상태 대기 중... (%s)\r" "$((i+1))" "$retries" "${reason:-Pending}"
        sleep 5
        i=$((i+1))
    done
    echo ""
    if [ "$i" -eq "$retries" ]; then
        print_warn "NNCP 적용 시간 초과. 상태를 수동으로 확인하세요: oc get nncp / oc get nnce"
        return 1
    fi
    print_info "노드별 적용 상태 (NNCE):"
    oc get nnce 2>/dev/null | grep "$name" | \
        awk '{printf "    %-40s %s\n", $1, $2}' || true
}

# =============================================================================
# NNCP 유형 감지 / NAD 이름
# =============================================================================
_detect_nncp_type() {
    detect_nncp_type "$@"
}

_nncp_type_label() {
    case "${1:-linux-bridge}" in
        ovs-bridge) echo "ovs-bridge" ;;
        bond)       echo "bond+bridge" ;;
        vlan)       echo "vlan+bridge" ;;
        *)          echo "linux-bridge" ;;
    esac
}

_set_nad_name() {
    if [ "$NNCP_IFACE_TYPE" = "ovs-bridge" ]; then
        if [ "$NET_TYPE" = "2" ]; then
            NAD_NAME="poc-localnet-vlan-nad"
        else
            NAD_NAME="poc-localnet-nad"
        fi
    else
        if [ "$NET_TYPE" = "2" ]; then
            NAD_NAME="poc-bridge-vlan-nad"
        else
            NAD_NAME="poc-bridge-nad"
        fi
    fi
}

_list_worker_nics() {
    local node
    node=$(oc get nodes -l node-role.kubernetes.io/worker \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    [ -z "$node" ] && return 0
    print_info "워커 노드 ${node} 이더넷 인터페이스:"
    oc get nns "$node" \
        -o jsonpath='{range .status.currentState.interfaces[?(@.type=="ethernet")]}    {.name}{"  state="}{.state}{"\n"}{end}' \
        2>/dev/null || true
}

_emit_linux_bridge_port() {
    local port_name="$1"
    local net_type="$2"
    if [ "$net_type" = "2" ]; then
        cat <<EOF
          port:
            - name: ${port_name}
              vlan:
                mode: trunk
                trunk-tags:
                  - id-range:
                      min: 1
                      max: 4094
EOF
    else
        cat <<EOF
          port:
            - name: ${port_name}
EOF
    fi
}

_apply_nncp_yaml() {
    echo ""
    print_info "적용할 NNCP YAML:"
    echo "────────────────────────────────────────"
    cat "nncp-${NNCP_NAME}.yaml"
    echo "────────────────────────────────────────"
    echo ""
    read -r -p "이 NNCP를 클러스터에 적용하시겠습니까? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_warn "NNCP 생성이 취소되었습니다."
        exit 1
    fi

    oc apply -f "nncp-${NNCP_NAME}.yaml"
    _wait_nncp "$NNCP_NAME" || {
        print_error "NNCP 생성 실패 또는 시간 초과."
        exit 1
    }
    resolve_nad_name
    save_network_env
    print_ok "NNCP '${NNCP_NAME}' 생성 완료 (유형: $(_nncp_type_label "$NNCP_IFACE_TYPE"), bridge: ${BRIDGE_NAME})"
}

# =============================================================================
# 새 NNCP 생성
# =============================================================================
_create_nncp() {
    local net_type="$1"
    local mtu=""

    echo ""
    print_step "새 NNCP 생성"

    echo ""
    echo -e "  ${GREEN}1)${NC} Linux Bridge"
    echo -e "     type: linux-bridge — 물리 NIC를 브릿지 포트로 연결"
    echo -e "     ${DIM}NAD: cnv-bridge / 테스트·개발에 가장 단순${NC}"
    echo ""
    echo -e "  ${GREEN}2)${NC} OVS Bridge (OVN Localnet)"
    echo -e "     type: ovs-bridge + ovn.bridge-mappings"
    echo -e "     ${DIM}NAD: ovn-k8s-cni-overlay / OVN port security·ACL${NC}"
    echo ""
    echo -e "  ${GREEN}3)${NC} Bond + Linux Bridge"
    echo -e "     type: bond + linux-bridge — NIC 2개를 본딩한 뒤 브릿지에 연결"
    echo -e "     ${DIM}NAD: cnv-bridge / NIC HA (active-backup 또는 LACP)${NC}"
    echo ""
    echo -e "  ${GREEN}4)${NC} VLAN + Linux Bridge"
    echo -e "     type: vlan + linux-bridge — VLAN 서브인터페이스를 브릿지 포트로 연결"
    echo -e "     ${DIM}NAD: cnv-bridge / 단일 VLAN access (스위치 Access 또는 tagged)${NC}"
    echo ""
    read -r -p "  NNCP 유형 선택 [1-4]: " _iface_sel
    case "$_iface_sel" in
        1) NNCP_IFACE_TYPE="linux-bridge" ;;
        2) NNCP_IFACE_TYPE="ovs-bridge" ;;
        3) NNCP_IFACE_TYPE="bond" ;;
        4) NNCP_IFACE_TYPE="vlan" ;;
        *)
            print_error "1–4를 입력해 주세요."
            exit 1
            ;;
    esac

    echo ""
    _list_worker_nics
    echo ""

    case "$NNCP_IFACE_TYPE" in
        ovs-bridge)
            [ "$BRIDGE_NAME" = "br1" ] || [ "$BRIDGE_NAME" = "br-poc" ] && BRIDGE_NAME="ovs-br-poc"
            NNCP_NAME="${BRIDGE_NAME}-nncp"
            ;;
        bond)
            NNCP_NAME="${NNCP_NAME:-${BRIDGE_NAME}-bond-nncp}"
            ;;
        vlan)
            NNCP_NAME="${NNCP_NAME:-${BRIDGE_NAME}-vlan-nncp}"
            ;;
    esac

    read -r -p "  NNCP 이름 입력 [${NNCP_NAME}]: " _input
    [ -n "$_input" ] && NNCP_NAME="$_input"

    read -r -p "  Bridge 이름 입력 [${BRIDGE_NAME}]: " _input
    [ -n "$_input" ] && BRIDGE_NAME="$_input"

    read -r -p "  물리 NIC 입력 [${BRIDGE_INTERFACE}]: " _input
    [ -n "$_input" ] && BRIDGE_INTERFACE="$_input"

    if [ "$NNCP_IFACE_TYPE" = "bond" ]; then
        local _def_nic2="${BOND_INTERFACE_2:-ens5}"
        read -r -p "  Bond 두 번째 NIC 입력 [${_def_nic2}]: " _input
        BOND_INTERFACE_2="${_input:-$_def_nic2}"
        read -r -p "  Bond 이름 입력 [${BOND_NAME}]: " _input
        [ -n "$_input" ] && BOND_NAME="$_input"
        echo ""
        echo -e "  Bond 모드:"
        echo -e "    ${GREEN}1)${NC} active-backup  ${DIM}스위치 설정 불필요${NC}"
        echo -e "    ${GREEN}2)${NC} 802.3ad (LACP)  ${DIM}스위치 LACP 필요${NC}"
        read -r -p "  선택 [1-2, 기본값: 1]: " _bond_sel
        case "${_bond_sel:-1}" in
            2) BOND_MODE="802.3ad" ;;
            *) BOND_MODE="active-backup" ;;
        esac
    fi

    if [ "$NNCP_IFACE_TYPE" = "ovs-bridge" ]; then
        read -r -p "  OVN localnet 이름 입력 [${LOCALNET_NAME}]: " _input
        [ -n "$_input" ] && LOCALNET_NAME="$_input"
    fi

    if [ "$NNCP_IFACE_TYPE" = "vlan" ]; then
        read -r -p "  VLAN ID 입력 [${VLAN_ID}]: " _input
        [ -n "$_input" ] && VLAN_ID="$_input"
        if [ -z "$VLAN_ID" ]; then
            print_error "VLAN + Linux Bridge에는 VLAN ID가 필요합니다."
            exit 1
        fi
    fi

    read -r -p "  MTU를 설정하시겠습니까? (기본값을 사용하려면 비워두세요): " mtu

    case "$NNCP_IFACE_TYPE" in
        linux-bridge)
            {
                cat <<EOF
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ${NNCP_NAME}
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ''
  desiredState:
    interfaces:
      - name: ${BRIDGE_NAME}
        description: Linux bridge with ${BRIDGE_INTERFACE} as a port
        type: linux-bridge
        state: up
EOF
                [ -n "${mtu}" ] && echo "        mtu: ${mtu}"
                cat <<EOF
        ipv4:
          enabled: false
        ipv6:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
EOF
                _emit_linux_bridge_port "$BRIDGE_INTERFACE" "$net_type"
            } > "nncp-${NNCP_NAME}.yaml"
            ;;
        ovs-bridge)
            {
                cat <<EOF
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ${NNCP_NAME}
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ''
  desiredState:
    interfaces:
      - name: ${BRIDGE_NAME}
        description: OVS bridge with ${BRIDGE_INTERFACE} as a port
        type: ovs-bridge
        state: up
EOF
                [ -n "${mtu}" ] && echo "        mtu: ${mtu}"
                cat <<EOF
        bridge:
          options:
            stp: false
          port:
            - name: ${BRIDGE_INTERFACE}
    ovn:
      bridge-mappings:
        - localnet: ${LOCALNET_NAME}
          bridge: ${BRIDGE_NAME}
          state: present
EOF
            } > "nncp-${NNCP_NAME}.yaml"
            ;;
        bond)
            {
                cat <<EOF
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ${NNCP_NAME}
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ''
  desiredState:
    interfaces:
      - name: ${BOND_NAME}
        description: Bond (${BOND_MODE}) of ${BRIDGE_INTERFACE} + ${BOND_INTERFACE_2}
        type: bond
        state: up
        ipv4:
          enabled: false
        ipv6:
          enabled: false
        link-aggregation:
          mode: ${BOND_MODE}
          port:
            - ${BRIDGE_INTERFACE}
            - ${BOND_INTERFACE_2}
      - name: ${BRIDGE_NAME}
        description: Linux bridge with ${BOND_NAME} as a port
        type: linux-bridge
        state: up
EOF
                [ -n "${mtu}" ] && echo "        mtu: ${mtu}"
                cat <<EOF
        ipv4:
          enabled: false
        ipv6:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
EOF
                _emit_linux_bridge_port "$BOND_NAME" "$net_type"
            } > "nncp-${NNCP_NAME}.yaml"
            ;;
        vlan)
            vlan_iface="${BRIDGE_INTERFACE}.${VLAN_ID}"
            {
                cat <<EOF
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ${NNCP_NAME}
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ''
  desiredState:
    interfaces:
      - name: ${vlan_iface}
        description: VLAN ${VLAN_ID} on ${BRIDGE_INTERFACE}
        type: vlan
        state: up
        vlan:
          base-iface: ${BRIDGE_INTERFACE}
          id: ${VLAN_ID}
        ipv4:
          enabled: false
        ipv6:
          enabled: false
      - name: ${BRIDGE_NAME}
        description: Linux bridge with ${vlan_iface} as a port
        type: linux-bridge
        state: up
EOF
                [ -n "${mtu}" ] && echo "        mtu: ${mtu}"
                cat <<EOF
        ipv4:
          enabled: false
        ipv6:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ${vlan_iface}
EOF
            } > "nncp-${NNCP_NAME}.yaml"
            ;;
    esac

    _apply_nncp_yaml
}

# =============================================================================
# NNCP 상태 확인 및 선택 또는 생성
# =============================================================================
step_nncp() {
    print_step "1/4  NNCP 구성"

    local nncp_names_raw
    nncp_names_raw=$(oc get nncp -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

    if [ -z "$nncp_names_raw" ]; then
        print_warn "클러스터에 NNCP가 없습니다."
        echo ""
        read -r -p "  지금 새 NNCP를 생성하시겠습니까? [Y/n]: " confirm
        if [[ "${confirm:-y}" =~ ^[Yy]$ ]]; then
            _create_nncp "$NET_TYPE"
        else
            print_error "NAD 생성에 NNCP가 필요합니다. 종료합니다."
            exit 1
        fi
    else
        echo ""
        print_info "클러스터의 기존 NNCP:"
        echo "──────────────────────────────────────────────────────────────────────────────"
        printf "  %-4s %-28s %-12s %-14s %s\n" "번호" "NNCP 이름" "Available" "유형" "Bridge"
        echo "──────────────────────────────────────────────────────────────────────────────"

        local idx=1
        local -a nncp_names nncp_avails
        while read -r name; do
            [ -z "$name" ] && continue
            local avail itype ibridge
            avail=$(oc get nncp "$name" \
                -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' \
                2>/dev/null || true)
            detect_nncp_type "$name"
            itype=$(_nncp_type_label "$NNCP_IFACE_TYPE")
            ibridge="${BRIDGE_NAME:-}"
            printf "  %-4s %-28s %-12s %-14s %s\n" "$idx)" "$name" "${avail:-Unknown}" "$itype" "${ibridge:-}"
            nncp_names+=("$name")
            nncp_avails+=("$avail")
            idx=$((idx+1))
        done <<< "$nncp_names_raw"

        echo "──────────────────────────────────────────────────────────────────────────────"
        echo ""
        echo "  0) 새 NNCP 생성 (Linux Bridge / OVS / Bond / VLAN 선택)"
        echo ""

        local selection
        read -r -p "  NNCP 선택 [1-$((idx-1)), 또는 0으로 새로 생성]: " selection

        if [ "$selection" = "0" ]; then
            _create_nncp "$NET_TYPE"
        elif [ "$selection" -ge 1 ] && [ "$selection" -lt "$idx" ]; then
            local arr_idx=$((selection-1))
            NNCP_NAME="${nncp_names[$arr_idx]}"
            local avail="${nncp_avails[$arr_idx]}"
            _detect_nncp_type "$NNCP_NAME"
            select_localnet
            print_ok "선택된 NNCP: ${NNCP_NAME} (유형: $(_nncp_type_label "$NNCP_IFACE_TYPE"), bridge: ${BRIDGE_NAME}, Available: ${avail})"

            echo ""
            print_info "노드별 적용 상태 (NNCE):"
            oc get nnce 2>/dev/null | grep "${NNCP_NAME}" | \
                awk '{printf "    %-40s %s\n", $1, $2}' || true
        else
            print_error "잘못된 선택: ${selection}"
            exit 1
        fi
    fi

    resolve_nad_name
    save_network_env
}

# =============================================================================
# NAD — 방식별 등록
# =============================================================================
_ensure_namespace() {
    oc new-project "${NAD_NAMESPACE}" >/dev/null 2>&1 || \
        oc project "${NAD_NAMESPACE}" >/dev/null 2>&1 || true
    print_ok "Namespace: ${NAD_NAMESPACE}"
}

step_nad_linux_bridge() {
    print_step "2/4  NAD — Linux Bridge (bridge)"
    _ensure_namespace

    cat > nad-${NAD_NAME}.yaml <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${NAD_NAMESPACE}
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/${BRIDGE_NAME}
spec:
  config: |-
    {
        "cniVersion": "0.3.1",
        "name": "${NAD_NAME}",
        "type": "bridge",
        "bridge": "${BRIDGE_NAME}",
        "ipam": {},
        "macspoofchk": true,
        "preserveDefaultVlan": false
    }
EOF
    echo "생성된 파일: nad-${NAD_NAME}.yaml"
    print_info "NAD ${NAD_NAME} 등록 중..."
    oc apply -f nad-${NAD_NAME}.yaml
    oc get net-attach-def ${NAD_NAME} -n ${NAD_NAMESPACE} &>/dev/null
    print_ok "NAD ${NAD_NAME} 등록됨"
}

step_nad_linux_bridge_vlan() {
    print_step "2/4  NAD — Linux Bridge + VLAN ${VLAN_ID} (bridge)"
    _ensure_namespace

    cat > nad-${NAD_NAME}.yaml <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${NAD_NAMESPACE}
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/${BRIDGE_NAME}
spec:
  config: |-
    {
        "cniVersion": "0.3.1",
        "name": "${NAD_NAME}",
        "type": "bridge",
        "bridge": "${BRIDGE_NAME}",
        "vlan": ${VLAN_ID},
        "ipam": {},
        "macspoofchk": true,
        "preserveDefaultVlan": false
    }
EOF
    echo "생성된 파일: nad-${NAD_NAME}.yaml"
    print_info "NAD ${NAD_NAME} 등록 중..."
    oc apply -f nad-${NAD_NAME}.yaml
    oc get net-attach-def ${NAD_NAME} -n ${NAD_NAMESPACE} &>/dev/null
    print_ok "NAD ${NAD_NAME} 등록됨 (VLAN ${VLAN_ID})"
}

# poc-로 시작하는 모든 namespace에 NAD 배포
_deploy_nad_to_poc_namespaces() {
    local nad_file="nad-${NAD_NAME}.yaml"

    # NAD_NAMESPACE를 제외한 poc- namespace 목록
    local poc_namespaces
    poc_namespaces=$(oc get namespaces \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
        tr ' ' '\n' | grep '^poc-' | grep -v "^${NAD_NAMESPACE}$" || true)

    [ -z "$poc_namespaces" ] && return 0

    print_info "NAD (${NAD_NAME})를 다음 poc- namespace에 추가 배포할 수 있습니다:"
    echo ""
    for ns in $poc_namespaces; do
        echo "    - ${ns}"
    done
    echo ""
    read -r -p "  이 namespace들에도 NAD를 배포하시겠습니까? [y/N]: " _nad_confirm
    if [[ "$_nad_confirm" != "y" && "$_nad_confirm" != "Y" ]]; then
        print_info "추가 배포를 건너뜁니다."
        return 0
    fi

    print_info "추가 poc- namespace에 NAD 배포 중..."
    for ns in $poc_namespaces; do
        sed "s|namespace: ${NAD_NAMESPACE}|namespace: ${ns}|g" \
            "$nad_file" | oc apply -f -
        oc get net-attach-def ${NAD_NAME} -n ${ns} &>/dev/null
        print_ok "  NAD ${NAD_NAME} → ${ns}"
    done
}

step_nad_ovn_localnet() {
    print_step "2/4  NAD — OVN Localnet (${LOCALNET_NAME})"
    _ensure_namespace

    cat > nad-${NAD_NAME}.yaml <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${NAD_NAMESPACE}
spec:
  config: |-
    {
        "cniVersion": "0.3.1",
        "name": "${LOCALNET_NAME}",
        "type": "ovn-k8s-cni-overlay",
        "topology": "localnet",
        "netAttachDefName": "${NAD_NAMESPACE}/${NAD_NAME}",
        "physicalNetworkName": "${LOCALNET_NAME}",
        "mtu": ${NAD_MTU:-1500}
    }
EOF
    echo "생성된 파일: nad-${NAD_NAME}.yaml"
    print_info "NAD ${NAD_NAME} 등록 중..."
    oc apply -f nad-${NAD_NAME}.yaml
    oc get net-attach-def ${NAD_NAME} -n ${NAD_NAMESPACE} &>/dev/null
    print_ok "NAD ${NAD_NAME} 등록됨 (localnet: ${LOCALNET_NAME})"
}

step_nad_ovn_localnet_vlan() {
    _ensure_namespace

    local _vlan_line=""
    if [ "${NNCP_BRIDGE_HAS_VLAN:-}" = "true" ]; then
        print_step "2/4  NAD — OVN Localnet (${LOCALNET_NAME}) — NNCP에서 VLAN 처리, NAD vlanID 생략"
        print_warn "NNCP 브릿지 포트가 VLAN 서브인터페이스(${BRIDGE_INTERFACE})이므로 NAD에 vlanID를 지정하지 않습니다."
    else
        print_step "2/4  NAD — OVN Localnet + VLAN ${VLAN_ID} (${LOCALNET_NAME})"
        _vlan_line="
        \"vlanID\": ${VLAN_ID},"
    fi

    cat > nad-${NAD_NAME}.yaml <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${NAD_NAMESPACE}
spec:
  config: |-
    {
        "cniVersion": "0.3.1",
        "name": "${LOCALNET_NAME}",
        "type": "ovn-k8s-cni-overlay",
        "topology": "localnet",${_vlan_line}
        "netAttachDefName": "${NAD_NAMESPACE}/${NAD_NAME}",
        "physicalNetworkName": "${LOCALNET_NAME}",
        "mtu": ${NAD_MTU:-1500}
    }
EOF
    echo "생성된 파일: nad-${NAD_NAME}.yaml"
    print_info "NAD ${NAD_NAME} 등록 중..."
    oc apply -f nad-${NAD_NAME}.yaml
    oc get net-attach-def ${NAD_NAME} -n ${NAD_NAMESPACE} &>/dev/null
    if [ "${NNCP_BRIDGE_HAS_VLAN:-}" = "true" ]; then
        print_ok "NAD ${NAD_NAME} 등록됨 (localnet: ${LOCALNET_NAME}, VLAN은 NNCP에서 처리)"
    else
        print_ok "NAD ${NAD_NAME} 등록됨 (localnet: ${LOCALNET_NAME}, VLAN ${VLAN_ID})"
    fi
}

step_nad() {
    if [ "$NNCP_IFACE_TYPE" = "ovs-bridge" ]; then
        case "$NET_TYPE" in
            2) step_nad_ovn_localnet_vlan ;;
            *) step_nad_ovn_localnet ;;
        esac
    else
        case "$NET_TYPE" in
            1) step_nad_linux_bridge ;;
            2)
                # VLAN 서브인터페이스 NNCP는 이미 단일 VLAN이므로 NAD에 vlan을 중복 지정하지 않음
                if [ "$NNCP_IFACE_TYPE" = "vlan" ]; then
                    step_nad_linux_bridge
                else
                    step_nad_linux_bridge_vlan
                fi
                ;;
        esac
    fi
    _deploy_nad_to_poc_namespaces
}

# =============================================================================
# VM 생성 (poc template + 선택된 NAD)
# =============================================================================
step_vm() {
    print_step "3/4  VM 생성 (poc template + ${NAD_NAME})"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc Template을 찾을 수 없습니다 — VM 생성을 건너뜁니다. (먼저 01-template을 실행하세요)"
        return
    fi

    local ip_suffixes=($(( SECONDARY_IP_START )) $(( SECONDARY_IP_START + 1 )))
    local idx=0

    for suffix in 1 2; do
        local VM_NAME="poc-network-vm-${suffix}"
        local ip_suffix="${ip_suffixes[$idx]}"
        idx=$((idx + 1))

        if oc get vm "$VM_NAME" -n "$NAD_NAMESPACE" &>/dev/null; then
            print_ok "VM $VM_NAME 이미 존재합니다 — 건너뜀"
            continue
        fi

        local vm_yaml="${SCRIPT_DIR}/vm-${VM_NAME}.yaml"
        oc process -n openshift poc -p NAME="$VM_NAME" | \
            sed 's/runStrategy: Always/runStrategy: Halted/' | sed 's/  running: false/  runStrategy: Halted/' > "${vm_yaml}"
        echo "생성된 파일: ${vm_yaml}"
        print_info "VM ${VM_NAME} 생성 중..."
        oc apply -n "$NAD_NAMESPACE" -f "${vm_yaml}"
        oc get vm ${VM_NAME} -n ${NAD_NAMESPACE} &>/dev/null

        ensure_runstrategy "$VM_NAME" "$NAD_NAMESPACE"

        # 보조 NIC 추가 (NAD) — OVN localnet vs Linux Bridge 구분
        local _net_label="secondary-net"
        local _net_ref="${NAD_NAME}"
        if [ "$NNCP_IFACE_TYPE" = "ovs-bridge" ]; then
            _net_ref="${NAD_NAMESPACE}/${NAD_NAME}"
        fi
        oc patch vm "$VM_NAME" -n "$NAD_NAMESPACE" --type=json -p='[
          {
            "op": "add",
            "path": "/spec/template/spec/domain/devices/interfaces/-",
            "value": {"name": "'"${_net_label}"'", "bridge": {}, "model": "virtio"}
          },
          {
            "op": "add",
            "path": "/spec/template/spec/networks/-",
            "value": {"name": "'"${_net_label}"'", "multus": {"networkName": "'"${_net_ref}"'"}}
          }
        ]'

        # cloud-init networkData — 기존 cloudinitdisk volume에 networkData 추가 (VM 시작 전)
        local ci_idx
        ci_idx=$(oc get vm "$VM_NAME" -n "$NAD_NAMESPACE" \
            -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' 2>/dev/null | \
            grep -n "cloudinitdisk" | cut -d: -f1 | head -1)
        # grep -n은 1-based, JSON patch는 0-based
        [ -n "$ci_idx" ] && ci_idx=$(( ci_idx - 1 ))

        if [ -n "$ci_idx" ]; then
            oc patch vm "$VM_NAME" -n "$NAD_NAMESPACE" --type=json -p="[
              {\"op\": \"add\",
               \"path\": \"/spec/template/spec/volumes/${ci_idx}/cloudInitNoCloud/networkData\",
               \"value\": \"version: 2\\nethernets:\\n  eth1:\\n    dhcp4: false\\n    addresses:\\n      - ${SECONDARY_IP_PREFIX}.${ip_suffix}/24\\n    gateway4: ${SECONDARY_IP_PREFIX}.1\\n    nameservers:\\n      addresses:\\n        - 8.8.8.8\\n\"}
            ]"
            print_ok "networkData 추가됨 → cloudinitdisk (index: ${ci_idx})"
        else
            print_warn "cloudinitdisk volume을 찾을 수 없습니다. networkData가 설정되지 않았습니다."
        fi

        virtctl start "$VM_NAME" -n "$NAD_NAMESPACE" 2>/dev/null || true
        print_ok "VM ${VM_NAME} 생성됨 (eth0: masquerade, eth1: ${NAD_NAME}, IP: ${SECONDARY_IP_PREFIX}.${ip_suffix}/24)"
    done
}

# =============================================================================
# ConsoleYAMLSample 등록
# =============================================================================
step_consoleyamlsamples() {
    print_step "4/4  ConsoleYAMLSample 등록"

    # NNCP 샘플 — 인터페이스 유형별
    local nncp_title nncp_desc nncp_yaml
    case "$NNCP_IFACE_TYPE" in
        ovs-bridge)
            nncp_title="POC OVS Bridge NNCP"
            nncp_desc="Creates an OVS Bridge (${BRIDGE_NAME}) mapped to OVN localnet ${LOCALNET_NAME}."
            nncp_yaml="$(cat <<YAML
    apiVersion: nmstate.io/v1
    kind: NodeNetworkConfigurationPolicy
    metadata:
      name: ${NNCP_NAME}
    spec:
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      desiredState:
        interfaces:
          - name: ${BRIDGE_NAME}
            type: ovs-bridge
            state: up
            bridge:
              options:
                stp: false
              port:
                - name: ${BRIDGE_INTERFACE}
        ovn:
          bridge-mappings:
            - localnet: ${LOCALNET_NAME}
              bridge: ${BRIDGE_NAME}
              state: present
YAML
)"
            ;;
        bond)
            nncp_title="POC Bond + Linux Bridge NNCP"
            nncp_desc="Creates bond ${BOND_NAME} (${BOND_MODE}) and Linux Bridge ${BRIDGE_NAME}."
            nncp_yaml="$(cat <<YAML
    apiVersion: nmstate.io/v1
    kind: NodeNetworkConfigurationPolicy
    metadata:
      name: ${NNCP_NAME}
    spec:
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      desiredState:
        interfaces:
          - name: ${BOND_NAME}
            type: bond
            state: up
            ipv4:
              enabled: false
            link-aggregation:
              mode: ${BOND_MODE}
              port:
                - ${BRIDGE_INTERFACE}
                - ${BOND_INTERFACE_2:-ens5}
          - name: ${BRIDGE_NAME}
            type: linux-bridge
            state: up
            ipv4:
              enabled: false
            bridge:
              options:
                stp:
                  enabled: false
              port:
                - name: ${BOND_NAME}
YAML
)"
            ;;
        vlan)
            nncp_title="POC VLAN + Linux Bridge NNCP"
            nncp_desc="Creates VLAN ${VLAN_ID} on ${BRIDGE_INTERFACE} and Linux Bridge ${BRIDGE_NAME}."
            nncp_yaml="$(cat <<YAML
    apiVersion: nmstate.io/v1
    kind: NodeNetworkConfigurationPolicy
    metadata:
      name: ${NNCP_NAME}
    spec:
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      desiredState:
        interfaces:
          - name: ${BRIDGE_INTERFACE}.${VLAN_ID}
            type: vlan
            state: up
            vlan:
              base-iface: ${BRIDGE_INTERFACE}
              id: ${VLAN_ID}
          - name: ${BRIDGE_NAME}
            type: linux-bridge
            state: up
            ipv4:
              enabled: false
            bridge:
              options:
                stp:
                  enabled: false
              port:
                - name: ${BRIDGE_INTERFACE}.${VLAN_ID}
YAML
)"
            ;;
        *)
            if [ "$NET_TYPE" = "2" ]; then
                nncp_title="POC Linux Bridge VLAN trunk NNCP"
                nncp_desc="Creates a Linux Bridge (${BRIDGE_NAME}) with VLAN trunk port on worker nodes."
                nncp_yaml="$(cat <<YAML
    apiVersion: nmstate.io/v1
    kind: NodeNetworkConfigurationPolicy
    metadata:
      name: ${NNCP_NAME}
    spec:
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      desiredState:
        interfaces:
          - name: ${BRIDGE_NAME}
            type: linux-bridge
            state: up
            ipv4:
              enabled: false
            bridge:
              options:
                stp:
                  enabled: false
              port:
                - name: ${BRIDGE_INTERFACE}
                  vlan:
                    mode: trunk
                    trunk-tags:
                      - id-range:
                          min: 1
                          max: 4094
YAML
)"
            else
                nncp_title="POC Linux Bridge NNCP"
                nncp_desc="Creates a Linux Bridge (${BRIDGE_NAME}) on worker nodes."
                nncp_yaml="$(cat <<YAML
    apiVersion: nmstate.io/v1
    kind: NodeNetworkConfigurationPolicy
    metadata:
      name: ${NNCP_NAME}
    spec:
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      desiredState:
        interfaces:
          - name: ${BRIDGE_NAME}
            type: linux-bridge
            state: up
            ipv4:
              enabled: false
            bridge:
              options:
                stp:
                  enabled: false
              port:
                - name: ${BRIDGE_INTERFACE}
YAML
)"
            fi
            ;;
    esac

    cat > consoleyamlsample-nncp.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: ${NNCP_NAME}
spec:
  title: "${nncp_title}"
  description: "${nncp_desc}"
  targetResource:
    apiVersion: nmstate.io/v1
    kind: NodeNetworkConfigurationPolicy
  yaml: |
${nncp_yaml}
EOF
    echo "생성된 파일: consoleyamlsample-nncp.yaml"
    print_info "ConsoleYAMLSample ${NNCP_NAME} 등록 중..."
    oc apply -f consoleyamlsample-nncp.yaml
    oc get consoleyamlsample ${NNCP_NAME} &>/dev/null
    print_ok "ConsoleYAMLSample ${NNCP_NAME} 등록됨"

    # NAD 샘플 — 방식별 config 블록 생성
    local nad_config_block nad_method_label
    if [ "$NNCP_IFACE_TYPE" = "ovs-bridge" ]; then
        if [ "$NET_TYPE" = "2" ] && [ "${NNCP_BRIDGE_HAS_VLAN:-}" != "true" ]; then
            nad_method_label="OVN Localnet+VLAN"
            nad_config_block="    {
        \"cniVersion\": \"0.3.1\",
        \"name\": \"${LOCALNET_NAME}\",
        \"type\": \"ovn-k8s-cni-overlay\",
        \"topology\": \"localnet\",
        \"vlanID\": ${VLAN_ID},
        \"netAttachDefName\": \"${NAD_NAMESPACE}/${NAD_NAME}\",
        \"physicalNetworkName\": \"${LOCALNET_NAME}\",
        \"mtu\": ${NAD_MTU:-1500}
    }"
        else
            nad_method_label="OVN Localnet"
            nad_config_block="    {
        \"cniVersion\": \"0.3.1\",
        \"name\": \"${LOCALNET_NAME}\",
        \"type\": \"ovn-k8s-cni-overlay\",
        \"topology\": \"localnet\",
        \"netAttachDefName\": \"${NAD_NAMESPACE}/${NAD_NAME}\",
        \"physicalNetworkName\": \"${LOCALNET_NAME}\",
        \"mtu\": ${NAD_MTU:-1500}
    }"
        fi
    else
        case "$NET_TYPE" in
            1) nad_method_label="Linux Bridge"
               nad_config_block="    {
        \"cniVersion\": \"0.3.1\",
        \"name\": \"${NAD_NAME}\",
        \"type\": \"bridge\",
        \"bridge\": \"${BRIDGE_NAME}\",
        \"ipam\": {},
        \"macspoofchk\": true,
        \"preserveDefaultVlan\": false
    }" ;;
            2) nad_method_label="Linux Bridge+VLAN"
               nad_config_block="    {
        \"cniVersion\": \"0.3.1\",
        \"name\": \"${NAD_NAME}\",
        \"type\": \"bridge\",
        \"bridge\": \"${BRIDGE_NAME}\",
        \"vlan\": ${VLAN_ID},
        \"ipam\": {},
        \"macspoofchk\": true,
        \"preserveDefaultVlan\": false
    }" ;;
        esac
    fi

    cat > consoleyamlsample-nad.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: ${NAD_NAME}
spec:
  title: "POC NAD — ${NAD_NAME}"
  description: "Register as VM secondary network after applying NNCP. (Method: ${nad_method_label})"
  targetResource:
    apiVersion: k8s.cni.cncf.io/v1
    kind: NetworkAttachmentDefinition
  yaml: |
    apiVersion: k8s.cni.cncf.io/v1
    kind: NetworkAttachmentDefinition
    metadata:
      name: ${NAD_NAME}
      namespace: ${NAD_NAMESPACE}
    spec:
      config: |-
${nad_config_block}
EOF
    echo "생성된 파일: consoleyamlsample-nad.yaml"
    print_info "ConsoleYAMLSample ${NAD_NAME} 등록 중..."
    oc apply -f consoleyamlsample-nad.yaml
    oc get consoleyamlsample ${NAD_NAME} &>/dev/null
    print_ok "ConsoleYAMLSample ${NAD_NAME} 등록됨"
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    local mode_label
    case "$NNCP_IFACE_TYPE" in
        ovs-bridge)
            if [ "$NET_TYPE" = "2" ]; then
                mode_label="OVS Bridge + OVN Localnet + VLAN ${VLAN_ID}"
            else
                mode_label="OVS Bridge + OVN Localnet"
            fi
            ;;
        bond)
            if [ "$NET_TYPE" = "2" ]; then
                mode_label="Bond (${BOND_MODE}) + Linux Bridge + VLAN ${VLAN_ID}"
            else
                mode_label="Bond (${BOND_MODE}) + Linux Bridge"
            fi
            ;;
        vlan)
            mode_label="VLAN ${VLAN_ID} + Linux Bridge"
            ;;
        *)
            if [ "$NET_TYPE" = "2" ]; then
                mode_label="Linux Bridge + VLAN ${VLAN_ID}"
            else
                mode_label="Linux Bridge"
            fi
            ;;
    esac

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! 네트워크 구성 (${mode_label})${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  NNCP 상태 : ${CYAN}oc get nncp${NC}"
    echo -e "  NNCE 상태 : ${CYAN}oc get nnce${NC}"
    echo -e "  NAD 확인  : ${CYAN}oc get net-attach-def -n ${NAD_NAMESPACE}${NC}"
    echo -e "  VM 상태   : ${CYAN}oc get vm,vmi -n ${NAD_NAMESPACE}${NC}"
    echo ""
    echo -e "  VM IP (eth1):"
    echo -e "    poc-network-vm-1 : ${CYAN}${SECONDARY_IP_PREFIX}.$(( SECONDARY_IP_START ))/24${NC}"
    echo -e "    poc-network-vm-2 : ${CYAN}${SECONDARY_IP_PREFIX}.$(( SECONDARY_IP_START + 1 ))/24${NC}"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 02-network 리소스 삭제"
    oc delete vm poc-network-vm-1 poc-network-vm-2 -n poc-network --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample "${NNCP_NAME:-poc-bridge-nncp}" \
        poc-bridge-nad poc-bridge-vlan-nad poc-localnet-nad poc-localnet-vlan-nad \
        --ignore-not-found 2>/dev/null || true
    oc delete project poc-network --ignore-not-found 2>/dev/null || true
    echo ""
    for _nncp in $(oc get nncp -o name 2>/dev/null | grep poc- || true); do
        local _name="${_nncp#*/}"
        read -r -p "NNCP ${_name}을(를) 삭제하시겠습니까? 노드 bridge가 제거됩니다. [y/N]: " _del
        [[ "$_del" = "y" || "$_del" = "Y" ]] && oc delete nncp "$_name" --ignore-not-found 2>/dev/null || true
    done
    print_ok "02-network 리소스 삭제됨"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  02-network: NNCP + NAD + VM 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}  virt-poc ${POC_VERSION}${NC}"

    choose_mode
    preflight
    step_nncp
    step_nad
    step_vm
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
