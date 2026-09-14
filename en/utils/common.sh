#!/bin/bash
# =============================================================================
# utils/common.sh
#
# Shared functions for all virt-poc lab scripts.
# Source this file instead of defining inline color/print helpers.
#
#   source "${SCRIPT_DIR}/../utils/common.sh"
#
# Provides:
#   Color constants, print_info/ok/warn/error/step/header,
#   ask(), save_to_env(), load_or_ask(),
#   detect_worker_nodes(), auto_detect_garage(), auto_detect_odf(),
#   confirm_and_apply()
# =============================================================================

# Guard against double-sourcing
[ -n "${_COMMON_SH_LOADED:-}" ] && return 0
_COMMON_SH_LOADED=1

# ---------------------------------------------------------------------------
# Color constants
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
DIM='\033[2m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Print helpers
# ---------------------------------------------------------------------------
print_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERR ]${NC} $1"; }
print_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

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
# ask() — interactive prompt with default value
# ---------------------------------------------------------------------------
ask() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local is_secret="${4:-false}"

    if [ "$is_secret" = "true" ]; then
        echo -n -e "${YELLOW}  $prompt${NC} [default: ****]: "
        read -s input_val
        echo ""
    else
        echo -n -e "${YELLOW}  $prompt${NC} [default: ${default}]: "
        read input_val
    fi

    if [ -z "$input_val" ]; then
        input_val="$default"
    fi

    eval "$var_name='$input_val'"
}

# ---------------------------------------------------------------------------
# save_to_env() — update or append a variable in env.conf
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
# load_or_ask() — use existing value from env.conf, or prompt and save
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
# confirm_and_apply() — preview YAML then apply
#   confirm_and_apply FILE [auto]
#   auto=true → apply without asking; default → ask user
# ---------------------------------------------------------------------------
confirm_and_apply() {
    local file="$1"
    local auto="${2:-true}"
    if [ "$auto" != "true" ]; then
        echo ""
        print_info "YAML to apply:"
        echo "────────────────────────────────────────"
        cat "$file"
        echo "────────────────────────────────────────"
        read -r -p "Apply the above YAML to the cluster? [y/N]: " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { print_warn "Cancelled."; return 1; }
    fi
    oc apply -f "$file"
}

# ---------------------------------------------------------------------------
# detect_worker_nodes() — detect worker nodes from the cluster
#   Sets: WORKER_NODES (space-separated), TEST_NODE (first worker)
# ---------------------------------------------------------------------------
detect_worker_nodes() {
    WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    TEST_NODE=$(echo "$WORKER_NODES" | awk '{print $1}')

    if [ -z "$WORKER_NODES" ]; then
        print_error "No worker nodes found."
        exit 1
    fi
    print_info "Worker nodes: ${WORKER_NODES}"
}

# ---------------------------------------------------------------------------
# auto_detect_garage() — detect Garage S3 service in the cluster
#   Sets: GARAGE_ENDPOINT, GARAGE_BUCKET, GARAGE_ACCESS_KEY,
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
        print_warn "Garage Service (app=garage) detection failed → Skipping Garage configuration."
    fi
}

# ---------------------------------------------------------------------------
# auto_detect_odf() — detect ODF (NooBaa MCG) S3 endpoint
#   Sets: ODF_S3_ENDPOINT, ODF_S3_BUCKET, ODF_S3_REGION,
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
        print_info "ODF MCG credentials : Retrieved from noobaa-admin secret"
    else
        print_warn "ODF MCG credentials detection failed (no noobaa-admin secret)"
    fi
}

# ---------------------------------------------------------------------------
# detect_nncp_type() — extract interface type and bridge info from NNCP
#   detect_nncp_type <nncp-name>
#   sets: NNCP_IFACE_TYPE, BRIDGE_NAME, BRIDGE_INTERFACE, LOCALNET_NAME, BOND_NAME
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
    echo "  [debug] detect_nncp_type($name) types: $(echo $types | tr '\n' ' ')" >&2

    if echo "$types" | grep -qx "ovs-bridge"; then
        NNCP_IFACE_TYPE="ovs-bridge"
        BRIDGE_NAME=$(oc get nncp "$name" \
            -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="ovs-bridge")]}{.name}{end}' \
            2>/dev/null) || true
        BRIDGE_INTERFACE=$(oc get nncp "$name" \
            -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="ovs-bridge")]}{.bridge.port[0].name}{end}' \
            2>/dev/null) || true
        local _ln=""
        _ln=$(oc get nncp "$name" \
            -o jsonpath='{.spec.desiredState.ovn.bridge-mappings[0].localnet}' \
            2>/dev/null) || true
        [ -n "$_ln" ] && LOCALNET_NAME="$_ln"
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

    echo "  [debug] result: type=${NNCP_IFACE_TYPE} bridge=${BRIDGE_NAME:-N/A} nic=${BRIDGE_INTERFACE:-N/A}" >&2
    eval "$_prev_opts"
}

# ---------------------------------------------------------------------------
# nncp_type_label() — display label for NNCP type
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
# resolve_nad_name() — pick NAD name from NNCP type and NAD VLAN mode
#   NET_TYPE: 1=default, 2=VLAN filtering on NAD
#   sets: NAD_NAME
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
# save_network_env() — persist network variables to env.conf
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
