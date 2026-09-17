#!/bin/bash
trap '[[ "$BASH_COMMAND" =~ ^(oc|kubectl|virtctl) ]] && echo "+ $BASH_COMMAND"' DEBUG
# =============================================================================
# utils/common.sh
#
# virt-poc 모든 lab 스크립트의 공통 함수 모음.
# 인라인 color/print 헬퍼를 직접 정의하지 말고 이 파일을 source 하세요.
#
#   source "${SCRIPT_DIR}/../utils/common.sh"
#
# 제공 기능:
#   색상 상수, print_info/ok/warn/error/step/header,
#   ask(), save_to_env(), load_or_ask(),
#   detect_worker_nodes(), auto_detect_garage(), auto_detect_odf(),
#   confirm_and_apply()
# =============================================================================

# 이중 source 방지
[ -n "${_COMMON_SH_LOADED:-}" ] && return 0
_COMMON_SH_LOADED=1

_COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_VERSION=$(cat "${_COMMON_SH_DIR}/../../VERSION" 2>/dev/null || echo "dev")

# ---------------------------------------------------------------------------
# 색상 상수
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
DIM='\033[2m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# 출력 헬퍼
# ---------------------------------------------------------------------------
print_info()  { echo -e "${BLUE}[정보]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[경고]${NC} $1"; }
print_error() { echo -e "${RED}[오류]${NC} $1"; }
print_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

# ---------------------------------------------------------------------------
# wait_for_resource() — oc apply 후 리소스가 실제로 존재하는지 확인
#   wait_for_resource TYPE NAME NAMESPACE [RETRIES]
#   예: wait_for_resource pvc grafana-plugins-pvc poc-grafana
#   RETRIES 기본값: 6 (30초)
# ---------------------------------------------------------------------------
wait_for_resource() {
    local type="$1" name="$2" ns="$3" retries="${4:-6}" i
    for i in $(seq 1 "$retries"); do
        if oc get "$type" "$name" -n "$ns" &>/dev/null; then
            return 0
        fi
        sleep 5
    done
    return 1
}

print_header() {
    echo ""
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo ""
}

print_step_header() {
    local num="$1"
    local title="$2"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  ${num}  ${title}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# ask() — 기본값이 있는 대화형 프롬프트
# ---------------------------------------------------------------------------
ask() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local is_secret="${4:-false}"

    if [ "$is_secret" = "true" ]; then
        echo -n -e "${YELLOW}  $prompt${NC} [기본값: ****]: "
        read -s input_val
        echo ""
    else
        echo -n -e "${YELLOW}  $prompt${NC} [기본값: ${default}]: "
        read input_val
    fi

    if [ -z "$input_val" ]; then
        input_val="$default"
    fi

    eval "$var_name='$input_val'"
}

# ---------------------------------------------------------------------------
# save_to_env() — env.conf에 변수를 업데이트하거나 추가
#   save_to_env KEY VALUE [ENV_FILE]
# ---------------------------------------------------------------------------
save_to_env() {
    local key="$1"
    local value="$2"
    local env_file="${3:-${ENV_FILE:-}}"

    if [ -z "$env_file" ]; then
        local caller_dir
        caller_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
        env_file="${caller_dir}/../env.conf"
    fi

    [ ! -f "$env_file" ] && return 0

    if grep -q "^${key}=" "$env_file" 2>/dev/null; then
        if [[ "$OSTYPE" == darwin* ]]; then
            sed -i '' "s|^${key}=.*|${key}=${value}|" "$env_file"
        else
            sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
        fi
    else
        echo "${key}=${value}" >> "$env_file"
    fi
}

# ---------------------------------------------------------------------------
# load_or_ask() — env.conf의 기존 값 사용 또는 입력 후 저장
#   load_or_ask VAR_NAME "prompt" "default" [is_secret]
# ---------------------------------------------------------------------------
load_or_ask() {
    local var_name="$1"
    local prompt="$2"
    local default="$3"
    local is_secret="${4:-false}"

    local current_val
    eval "current_val=\${${var_name}:-}"

    if [ -n "$current_val" ]; then
        return 0
    fi

    ask "$prompt" "$default" "$var_name" "$is_secret"
    eval "local _val=\$$var_name"
    save_to_env "$var_name" "$_val"
}

# ---------------------------------------------------------------------------
# confirm_and_apply() — YAML 미리보기 후 적용
#   confirm_and_apply FILE [auto]
#   auto=true → 확인 없이 적용; 기본값 → 사용자에게 확인
# ---------------------------------------------------------------------------
confirm_and_apply() {
    local file="$1"
    local auto="${2:-true}"
    if [ "$auto" != "true" ]; then
        echo ""
        print_info "적용할 YAML:"
        echo "────────────────────────────────────────"
        cat "$file"
        echo "────────────────────────────────────────"
        read -r -p "위 YAML을 클러스터에 적용하시겠습니까? [y/N]: " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { print_warn "취소됨."; return 1; }
    fi
    oc apply -f "$file"
}

# ---------------------------------------------------------------------------
# auto_detect_operators() — 클러스터 CSV에서 Operator 설치 여부 자동 감지
#   env.conf에서 false로 설정되어 있더라도 실제 클러스터에 Operator가
#   설치되어 있으면 해당 변수를 true로 업데이트합니다.
# ---------------------------------------------------------------------------
auto_detect_operators() {
    local _csv_list
    _csv_list=$(oc get csv --all-namespaces --no-headers 2>/dev/null || true)
    [ -z "$_csv_list" ] && return 0

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        echo "$_csv_list" | grep -qi "kubevirt-hyperconverged" && VIRT_INSTALLED=true
    fi
    if [ "${MTV_INSTALLED:-false}" != "true" ]; then
        echo "$_csv_list" | grep -qi "mtv-operator" && MTV_INSTALLED=true
    fi
    if [ "${OADP_INSTALLED:-false}" != "true" ]; then
        echo "$_csv_list" | grep -qi "oadp-operator" && OADP_INSTALLED=true
    fi
    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        echo "$_csv_list" | grep -qi "grafana-operator" && GRAFANA_INSTALLED=true
    fi
    if [ "${COO_INSTALLED:-false}" != "true" ]; then
        echo "$_csv_list" | grep -qi "cluster-observability-operator" && COO_INSTALLED=true
    fi
    if [ "${NMO_INSTALLED:-false}" != "true" ]; then
        echo "$_csv_list" | grep -qi "node-maintenance" && NMO_INSTALLED=true
    fi
    if [ "${DESCHEDULER_INSTALLED:-false}" != "true" ]; then
        echo "$_csv_list" | grep -qi "kube-descheduler" && DESCHEDULER_INSTALLED=true
    fi
    return 0
}

# ---------------------------------------------------------------------------
# detect_worker_nodes() — 클러스터에서 워커 노드 감지
#   설정: WORKER_NODES (공백 구분), TEST_NODE (첫 번째 워커)
# ---------------------------------------------------------------------------
detect_worker_nodes() {
    WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    TEST_NODE=$(echo "$WORKER_NODES" | awk '{print $1}')

    if [ -z "$WORKER_NODES" ]; then
        print_error "워커 노드를 찾을 수 없습니다."
        exit 1
    fi
    print_info "워커 노드: ${WORKER_NODES}"
}

# ---------------------------------------------------------------------------
# auto_detect_garage() — 클러스터 내 Garage S3 서비스 감지
#   설정: GARAGE_ENDPOINT, GARAGE_BUCKET, GARAGE_ACCESS_KEY,
#          GARAGE_SECRET_KEY, GARAGE_FOUND
# ---------------------------------------------------------------------------
auto_detect_garage() {
    GARAGE_ENDPOINT=""
    GARAGE_BUCKET="velero"
    GARAGE_ACCESS_KEY="garage"
    GARAGE_SECRET_KEY="garage123"

    local garage_ns
    garage_ns=$(oc get svc -A -l app=garage -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)

    GARAGE_FOUND=false

    if [ -n "$garage_ns" ]; then
        local garage_svc garage_port
        garage_svc=$(oc get svc -n "$garage_ns" -l app=garage \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
            oc get svc -n "$garage_ns" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        garage_port=$(oc get svc -n "$garage_ns" "$garage_svc" \
            -o jsonpath='{.spec.ports[?(@.name=="s3-api")].port}' 2>/dev/null || echo "3900")
        GARAGE_ENDPOINT="http://${garage_svc}.${garage_ns}.svc.cluster.local:${garage_port}"

        local secret_name
        secret_name=$(oc get secret -n "$garage_ns" \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
            tr ' ' '\n' | grep -iE "garage|credentials|s3" | head -1 || true)
        if [ -n "$secret_name" ]; then
            local ak sk
            ak=$(oc get secret -n "$garage_ns" "$secret_name" \
                -o jsonpath='{.data.accessKey}' 2>/dev/null | base64 -d 2>/dev/null || \
                oc get secret -n "$garage_ns" "$secret_name" \
                -o jsonpath='{.data.access_key_id}' 2>/dev/null | base64 -d 2>/dev/null || true)
            sk=$(oc get secret -n "$garage_ns" "$secret_name" \
                -o jsonpath='{.data.secretKey}' 2>/dev/null | base64 -d 2>/dev/null || \
                oc get secret -n "$garage_ns" "$secret_name" \
                -o jsonpath='{.data.secret_access_key}' 2>/dev/null | base64 -d 2>/dev/null || true)
            [ -n "$ak" ] && GARAGE_ACCESS_KEY="$ak"
            [ -n "$sk" ] && GARAGE_SECRET_KEY="$sk"
        fi

        GARAGE_FOUND=true
        print_info "Garage endpoint : ${GARAGE_ENDPOINT}  (ns: ${garage_ns})"
        print_info "Garage bucket   : ${GARAGE_BUCKET}"
        print_info "Garage accessKey: ${GARAGE_ACCESS_KEY}"
    else
        print_warn "Garage Service (app=garage) 감지 실패 → Garage 설정을 건너뜁니다."
    fi
}

# ---------------------------------------------------------------------------
# auto_detect_odf() — ODF (NooBaa MCG) S3 endpoint 감지
#   설정: ODF_S3_ENDPOINT, ODF_S3_BUCKET, ODF_S3_REGION,
#          ODF_S3_ACCESS_KEY, ODF_S3_SECRET_KEY
# ---------------------------------------------------------------------------
auto_detect_odf() {
    ODF_S3_ENDPOINT=""
    ODF_S3_BUCKET="velero"
    ODF_S3_REGION="localstorage"
    ODF_S3_ACCESS_KEY=""
    ODF_S3_SECRET_KEY=""

    local odf_ns="openshift-storage"

    ODF_S3_ENDPOINT=$(oc get noobaa -n "$odf_ns" \
        -o jsonpath='{.status.services.serviceS3.internalDNS[0]}' 2>/dev/null || true)
    if [ -z "$ODF_S3_ENDPOINT" ]; then
        local s3_port
        s3_port=$(oc get svc s3 -n "$odf_ns" \
            -o jsonpath='{.spec.ports[?(@.name=="s3")].port}' 2>/dev/null || echo "80")
        ODF_S3_ENDPOINT="http://s3.${odf_ns}.svc.cluster.local:${s3_port}"
    fi

    ODF_S3_ACCESS_KEY=$(oc get secret noobaa-admin -n "$odf_ns" \
        -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d 2>/dev/null || true)
    ODF_S3_SECRET_KEY=$(oc get secret noobaa-admin -n "$odf_ns" \
        -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)

    if [ -n "$ODF_S3_ACCESS_KEY" ]; then
        print_info "ODF MCG S3 endpoint : ${ODF_S3_ENDPOINT}"
        print_info "ODF MCG region      : ${ODF_S3_REGION}"
        print_info "ODF MCG bucket      : ${ODF_S3_BUCKET}"
        print_info "ODF MCG 인증 정보   : noobaa-admin secret에서 가져옴"
    else
        print_warn "ODF MCG 인증 정보 감지 실패 (noobaa-admin secret 없음)"
    fi
}

# ---------------------------------------------------------------------------
# detect_nncp_type() — NNCP에서 인터페이스 유형·bridge 정보 추출
#   detect_nncp_type <nncp-name>
#   설정: NNCP_IFACE_TYPE, BRIDGE_NAME, BRIDGE_INTERFACE, LOCALNET_NAME, BOND_NAME
# ---------------------------------------------------------------------------
detect_nncp_type() {
    local name="$1"
    local _prev_opts; _prev_opts=$(set +o); set +euo pipefail

    local types="" _raw=""
    _raw=$(oc get nncp "$name" \
        -o jsonpath='{range .spec.desiredState.interfaces[*]}{.state}{"\t"}{.type}{"\n"}{end}' \
        2>/dev/null) || true
    if [ -n "$_raw" ]; then
        types=$(echo "$_raw" | awk -F'\t' '$1 != "absent" {print $2}') || true
    fi

    # ── 인터페이스 유형 감지 ──
    if echo "$types" | grep -qx "ovs-bridge"; then
        NNCP_IFACE_TYPE="ovs-bridge"
        BRIDGE_NAME=$(oc get nncp "$name" \
            -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="ovs-bridge")]}{.name}{end}' \
            2>/dev/null) || true
        BRIDGE_INTERFACE=$(oc get nncp "$name" \
            -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="ovs-bridge")]}{.bridge.port[0].name}{end}' \
            2>/dev/null) || true
    elif echo "$types" | grep -qx "linux-bridge"; then
        BRIDGE_NAME=$(oc get nncp "$name" \
            -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.name}{end}' \
            2>/dev/null) || true
        BRIDGE_INTERFACE=$(oc get nncp "$name" \
            -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.bridge.port[0].name}{end}' \
            2>/dev/null) || true
        if echo "$types" | grep -qx "bond"; then
            NNCP_IFACE_TYPE="bond"
            BOND_NAME=$(oc get nncp "$name" \
                -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="bond")]}{.name}{end}' \
                2>/dev/null) || true
        elif echo "$types" | grep -qx "vlan"; then
            NNCP_IFACE_TYPE="vlan"
        else
            NNCP_IFACE_TYPE="linux-bridge"
        fi
    else
        NNCP_IFACE_TYPE="linux-bridge"
        BRIDGE_NAME=$(oc get nncp "$name" \
            -o jsonpath='{.spec.desiredState.interfaces[0].name}' 2>/dev/null) || true
    fi

    # ── bridge-mapping 감지 (인터페이스 유무와 무관하게 항상 확인) ──
    local _all_mappings=""
    _all_mappings=$(oc get nncp "$name" \
        -o jsonpath='{range .spec.desiredState.ovn.bridge-mappings[*]}{.localnet}{"\t"}{.bridge}{"\n"}{end}' \
        2>/dev/null) || true
    if [ -n "$_all_mappings" ]; then
        # bridge-mapping이 있으면 ovs-bridge 유형으로 취급
        NNCP_IFACE_TYPE="ovs-bridge"
        LOCALNET_MAPPINGS="$_all_mappings"
        # 기본 선택: br-ex가 아닌 첫 번째 매핑 우선, 없으면 첫 번째 매핑 사용
        local _best="" _first=""
        while IFS=$'\t' read -r _ln _br; do
            [ -z "$_ln" ] && continue
            [ -z "$_first" ] && _first="$_ln"
            if [ "$_br" != "br-ex" ] && [ -z "$_best" ]; then
                _best="$_ln"
            fi
        done <<< "$_all_mappings"
        LOCALNET_NAME="${_best:-$_first}"
    fi

    # ── NNCP에 VLAN 서브인터페이스가 있는지 감지 ──
    #   OVS bridge 포트가 VLAN 서브인터페이스이면 NAD에 vlanID를 중복 지정하면 안 됨
    NNCP_BRIDGE_HAS_VLAN=""
    if [ "$NNCP_IFACE_TYPE" = "ovs-bridge" ] && [ -n "$BRIDGE_INTERFACE" ]; then
        local _vlan_ifaces=""
        _vlan_ifaces=$(oc get nncp "$name" \
            -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="vlan")]}{.name}{"\n"}{end}' \
            2>/dev/null) || true
        if [ -n "$_vlan_ifaces" ] && echo "$_vlan_ifaces" | grep -qxF "$BRIDGE_INTERFACE"; then
            NNCP_BRIDGE_HAS_VLAN=true
        fi
    fi

    eval "$_prev_opts"
}

# ---------------------------------------------------------------------------
# select_localnet() — bridge-mapping 목록을 보여주고 localnet 선택
#   NNCP에 bridge-mapping이 2개 이상이면 목록 표시 후 선택, 1개면 자동 사용
#   설정: LOCALNET_NAME
# ---------------------------------------------------------------------------
select_localnet() {
    [ "${NNCP_IFACE_TYPE:-}" != "ovs-bridge" ] && return 0
    local _mappings="${LOCALNET_MAPPINGS:-}"
    [ -z "$_mappings" ] && return 0

    # 빈 줄 제거 후 매핑 수 확인
    local _clean
    _clean=$(echo "$_mappings" | grep -v '^$' || true)
    local _count
    _count=$(echo "$_clean" | wc -l | tr -d ' ')

    if [ "$_count" -le 1 ]; then
        # 매핑 1개 — 자동 사용
        print_info "Localnet: ${LOCALNET_NAME}"
        return 0
    fi

    echo ""
    print_info "NNCP bridge-mapping 목록:"
    local _idx=0
    while IFS=$'\t' read -r _ln _br; do
        [ -z "$_ln" ] && continue
        _idx=$((_idx + 1))
        local _marker=""
        [ "$_ln" = "$LOCALNET_NAME" ] && _marker=" ${GREEN}← 기본${NC}"
        echo -e "    ${GREEN}${_idx})${NC} ${_ln}  →  ${_br}${_marker}"
    done <<< "$_clean"
    echo -e "    ${GREEN}$((_idx + 1)))${NC} 직접 입력"
    echo ""

    read -r -p "  선택 [1-$((_idx + 1)), 기본값: ${LOCALNET_NAME}]: " _sel
    if [ -n "$_sel" ]; then
        if [ "$_sel" = "$((_idx + 1))" ]; then
            read -r -p "  Localnet 이름 입력: " _custom
            [ -n "$_custom" ] && LOCALNET_NAME="$_custom"
        elif [[ "$_sel" =~ ^[0-9]+$ ]] && [ "$_sel" -ge 1 ] && [ "$_sel" -le "$_idx" ]; then
            LOCALNET_NAME=$(echo "$_clean" | sed -n "${_sel}p" | cut -f1)
        fi
    fi
    print_ok "Localnet: ${LOCALNET_NAME}"
}

# ---------------------------------------------------------------------------
# nncp_type_label() — NNCP 유형 표시 문자열
# ---------------------------------------------------------------------------
nncp_type_label() {
    case "${1:-linux-bridge}" in
        ovs-bridge) echo "ovs-bridge" ;;
        bond)       echo "bond+bridge" ;;
        vlan)       echo "vlan+bridge" ;;
        *)          echo "linux-bridge" ;;
    esac
}

# ---------------------------------------------------------------------------
# resolve_nad_name() — NNCP 유형·NAD VLAN 모드에 맞는 NAD 이름 결정
#   NET_TYPE: 1=기본, 2=VLAN filtering (NAD)
#   설정: NAD_NAME
# ---------------------------------------------------------------------------
resolve_nad_name() {
    NNCP_IFACE_TYPE="${NNCP_IFACE_TYPE:-linux-bridge}"
    NET_TYPE="${NET_TYPE:-1}"
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

# ---------------------------------------------------------------------------
# save_network_env() — env.conf에 네트워크 관련 변수 저장
# ---------------------------------------------------------------------------
save_network_env() {
    [ -n "${NNCP_NAME:-}" ] && save_to_env "NNCP_NAME" "$NNCP_NAME"
    [ -n "${BRIDGE_NAME:-}" ] && save_to_env "BRIDGE_NAME" "$BRIDGE_NAME"
    [ -n "${BRIDGE_INTERFACE:-}" ] && save_to_env "BRIDGE_INTERFACE" "$BRIDGE_INTERFACE"
    [ -n "${NNCP_IFACE_TYPE:-}" ] && save_to_env "NNCP_IFACE_TYPE" "$NNCP_IFACE_TYPE"
    [ -n "${NAD_NAME:-}" ] && save_to_env "NAD_NAME" "$NAD_NAME"
    [ -n "${NET_TYPE:-}" ] && save_to_env "NET_TYPE" "$NET_TYPE"
    [ -n "${LOCALNET_NAME:-}" ] && save_to_env "LOCALNET_NAME" "$LOCALNET_NAME"
    [ -n "${BOND_NAME:-}" ] && save_to_env "BOND_NAME" "$BOND_NAME"
    [ -n "${BOND_MODE:-}" ] && save_to_env "BOND_MODE" "$BOND_MODE"
    [ -n "${BOND_INTERFACE_2:-}" ] && save_to_env "BOND_INTERFACE_2" "$BOND_INTERFACE_2"
    [ -n "${VLAN_ID:-}" ] && save_to_env "VLAN_ID" "$VLAN_ID"
    [ -n "${SECONDARY_IP_PREFIX:-}" ] && save_to_env "SECONDARY_IP_PREFIX" "$SECONDARY_IP_PREFIX"
}
