#!/bin/bash
# =============================================================================
# 02-network.sh
#
# NNCP(NodeNetworkConfigurationPolicy) + NAD(NetworkAttachmentDefinition) configuration
# Select one of 4 network methods to set up a secondary network for VMs.
#
#   1. Linux Bridge          — cnv-bridge CNI, NMState NNCP
#   2. OVN Localnet          — ovn-k8s-cni-overlay, OVN bridge-mappings
#   3. Linux Bridge + VLAN   — cnv-bridge CNI + VLAN ID, trunk port
#   4. OVN Localnet + VLAN   — ovn-k8s-cni-overlay + vlanID
#
# Usage: ./02-network.sh
# =============================================================================

set -euo pipefail

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
SECONDARY_IP_PREFIX="${SECONDARY_IP_PREFIX:-192.168.100}"

# Variables set per mode
NET_TYPE=""
NAD_NAME=""

if [ -f "${SCRIPT_DIR}/../utils/common.sh" ]; then
    source "${SCRIPT_DIR}/../utils/common.sh"
else
    # ── standalone mode: inline common helpers ──
    RED='\033[0;31m'; GREEN='\033[0;32m'; DIM='\033[2m'
    YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
    print_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
    print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
    print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
    print_error() { echo -e "${RED}[ERR ]${NC} $1"; }
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
            echo -n -e "${YELLOW}  $prompt${NC} [default: ****]: "; read -s input_val; echo
        else
            echo -n -e "${YELLOW}  $prompt${NC} [default: ${default}]: "; read input_val
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
            print_info "YAML to apply:"; cat "$file"
            read -r -p "Apply this YAML to the cluster? [y/N]: " confirm
            [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { print_warn "Cancelled."; return 1; }
        fi
        oc apply -f "$file"
    }
    detect_worker_nodes() {
        WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        TEST_NODE=$(echo "$WORKER_NODES" | awk '{print $1}')
        [ -z "$WORKER_NODES" ] && { print_error "No worker nodes found."; exit 1; }
        print_info "Worker nodes: ${WORKER_NODES}"
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
        else print_warn "Garage Service (app=garage) not detected — skipping Garage config."; fi
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
            print_info "ODF MCG credentials : from noobaa-admin secret"
        else print_warn "ODF MCG credentials not detected (no noobaa-admin secret)"; fi
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
# Select network method
# =============================================================================
choose_mode() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Select a network configuration method${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Linux Bridge"
    echo -e "     NNCP → Linux Bridge → cnv-bridge CNI"
    echo -e "     ${DIM}Switch: Access or Trunk port (no extra switch config needed)${NC}"
    echo -e "     ${DIM}Use   : Test/dev environments, quick setup${NC}"
    echo ""
    echo -e "  ${GREEN}2)${NC} Linux Bridge + VLAN filtering"
    echo -e "     NNCP → Linux Bridge trunk port → cnv-bridge + VLAN ID"
    echo -e "     ${DIM}Switch: Trunk port required + VLAN must be in the allowed list${NC}"
    echo -e "     ${DIM}Use   : Tenant/department network isolation (multiple VLANs on one NIC)${NC}"
    echo ""
    echo -e "  Current settings:"
    echo -e "    NNCP_NAME        : ${CYAN}${NNCP_NAME}${NC}"
    echo -e "    BRIDGE_NAME      : ${CYAN}${BRIDGE_NAME}${NC}"
    echo -e "    BRIDGE_INTERFACE : ${CYAN}${BRIDGE_INTERFACE}${NC}"
    echo -e "    Namespace        : ${CYAN}${NAD_NAMESPACE}${NC}"
    echo ""
    read -r -p "  Select [1-2]: " NET_TYPE

    case "$NET_TYPE" in
        1)
            NAD_NAME="poc-bridge-nad"
            print_ok "Selected: Linux Bridge"
            ;;
        2)
            NAD_NAME="poc-bridge-vlan-nad"
            echo ""
            read -r -p "  Enter VLAN ID [default: ${VLAN_ID}]: " input_vlan
            [ -n "$input_vlan" ] && VLAN_ID="$input_vlan"
            print_ok "Selected: Linux Bridge + VLAN ${VLAN_ID}"
            ;;
        *)
            print_error "Please enter 1 or 2."
            exit 1
            ;;
    esac
}

# =============================================================================
# Pre-flight checks
# =============================================================================
preflight() {
    print_step "Pre-flight checks"

    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift."
        exit 1
    fi
    print_ok "Cluster connection: $(oc whoami) @ $(oc whoami --show-server)"

    # Display NNCP information
    echo ""
    print_info "── NNCP Info ──"
    print_info "  NNCP_NAME       : ${NNCP_NAME}"
    print_info "  BRIDGE_NAME     : ${BRIDGE_NAME}"
    print_info "  BRIDGE_INTERFACE: ${BRIDGE_INTERFACE}"
    _nncp_avail=$(oc get nncp "${NNCP_NAME}" \
        -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
    if [ -n "$_nncp_avail" ]; then
        print_info "  Cluster NNCP status: Available=${_nncp_avail}"
        oc get nnce 2>/dev/null | grep "${NNCP_NAME}" | \
            awk '{printf "    %-40s %s\n", $1, $2}' || true
    else
        print_info "  Cluster NNCP status: Not applied (will be created)"
    fi

    if [ "${NMSTATE_INSTALLED:-false}" != "true" ]; then
        if ! oc get csv -A 2>/dev/null | grep -qi "kubernetes-nmstate"; then
            print_warn "Kubernetes NMState Operator not installed → skipping."
            print_warn "  Installation guide: operators/nmstate-operator.md"
            exit 77
        fi
    fi
    print_ok "NMState Operator confirmed"

    if ! oc get nmstate 2>/dev/null | grep -q "."; then
        print_warn "NMState CR not found. Creating NMState instance..."
        cat > nmstate-cr.yaml <<'NMEOF'
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
NMEOF
        oc apply -f nmstate-cr.yaml
        print_info "Waiting for NMState handler to be ready (up to 60s)..."
        oc rollout status daemonset/nmstate-handler -n openshift-nmstate --timeout=60s 2>/dev/null || true
        print_ok "NMState CR created"
    else
        print_ok "NMState CR confirmed"
    fi
}

# =============================================================================
# Wait for NNCP application to complete
# =============================================================================
_wait_nncp() {
    local name="$1"
    print_info "NNCP applied — waiting for node configuration propagation..."
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
        printf "  [%d/%d] Waiting for status... (%s)\r" "$((i+1))" "$retries" "${reason:-Pending}"
        sleep 5
        i=$((i+1))
    done
    echo ""
    if [ "$i" -eq "$retries" ]; then
        print_warn "NNCP application timed out. Check status manually: oc get nncp / oc get nnce"
        return 1
    fi
    print_info "Per-node application status (NNCE):"
    oc get nnce 2>/dev/null | grep "$name" | \
        awk '{printf "    %-40s %s\n", $1, $2}' || true
}

# =============================================================================
# Create new NNCP
# =============================================================================
_create_nncp() {
    local net_type="$1"

    echo ""
    print_step "Create new NNCP"

    # Get NNCP name
    read -r -p "  Enter NNCP name [${NNCP_NAME}]: " _input
    [ -n "$_input" ] && NNCP_NAME="$_input"

    # Get bridge name
    read -r -p "  Enter Bridge name [${BRIDGE_NAME}]: " _input
    [ -n "$_input" ] && BRIDGE_NAME="$_input"

    # Get bridge interface
    read -r -p "  Enter Bridge interface (physical NIC) [${BRIDGE_INTERFACE}]: " _input
    [ -n "$_input" ] && BRIDGE_INTERFACE="$_input"

    # Get MTU (optional)
    local mtu=""
    read -r -p "  Set MTU? (leave blank for default): " mtu

    # Generate NNCP YAML
    if [ "$net_type" = "2" ]; then
        # Linux Bridge + VLAN
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
        description: Linux bridge (VLAN trunk) with ${BRIDGE_INTERFACE} as a port
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
            - name: ${BRIDGE_INTERFACE}
              vlan:
                mode: trunk
                trunk-tags:
                  - id-range:
                      min: 1
                      max: 4094
EOF
        } > nncp-${NNCP_NAME}.yaml
    else
        # Linux Bridge (no VLAN)
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
          port:
            - name: ${BRIDGE_INTERFACE}
EOF
        } > nncp-${NNCP_NAME}.yaml
    fi

    echo ""
    print_info "NNCP YAML to apply:"
    echo "────────────────────────────────────────"
    cat nncp-${NNCP_NAME}.yaml
    echo "────────────────────────────────────────"
    echo ""
    read -r -p "Apply this NNCP to the cluster? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_warn "NNCP creation cancelled."
        exit 1
    fi

    oc apply -f nncp-${NNCP_NAME}.yaml
    _wait_nncp "$NNCP_NAME" || {
        print_error "NNCP creation failed or timed out."
        exit 1
    }
    print_ok "NNCP '${NNCP_NAME}' created successfully (bridge: ${BRIDGE_NAME})"
}

# =============================================================================
# Check NNCP status and select or create
# =============================================================================
step_nncp() {
    print_step "1/4  NNCP Configuration"

    # Get existing NNCPs
    local nncp_list
    nncp_list=$(oc get nncp -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Available")].status}{"\t"}{.spec.desiredState.interfaces[0].name}{"\n"}{end}' 2>/dev/null || true)

    if [ -z "$nncp_list" ]; then
        print_warn "No NNCP found in cluster."
        echo ""
        read -r -p "  Create a new NNCP now? [Y/n]: " confirm
        if [[ "${confirm:-y}" =~ ^[Yy]$ ]]; then
            _create_nncp "$NET_TYPE"
        else
            print_error "NNCP is required to create NAD. Exiting."
            exit 1
        fi
    else
        echo ""
        print_info "Existing NNCPs in cluster:"
        echo "────────────────────────────────────────────────────────────────────"
        printf "  %-4s %-30s %-12s %s\n" "No." "NNCP Name" "Available" "Bridge Name"
        echo "────────────────────────────────────────────────────────────────────"

        local idx=1
        local -a nncp_names nncp_avails nncp_bridges
        while IFS=$'\t' read -r name avail bridge; do
            printf "  %-4s %-30s %-12s %s\n" "$idx)" "$name" "${avail:-Unknown}" "$bridge"
            nncp_names+=("$name")
            nncp_avails+=("$avail")
            nncp_bridges+=("$bridge")
            idx=$((idx+1))
        done <<< "$nncp_list"

        echo "────────────────────────────────────────────────────────────────────"
        echo ""
        echo "  0) Create a new NNCP"
        echo ""

        local selection
        read -r -p "  Select NNCP [1-$((idx-1)), or 0 to create new]: " selection

        if [ "$selection" = "0" ]; then
            _create_nncp "$NET_TYPE"
        elif [ "$selection" -ge 1 ] && [ "$selection" -lt "$idx" ]; then
            local arr_idx=$((selection-1))
            NNCP_NAME="${nncp_names[$arr_idx]}"
            BRIDGE_NAME="${nncp_bridges[$arr_idx]}"
            local avail="${nncp_avails[$arr_idx]}"
            print_ok "Selected NNCP: ${NNCP_NAME} (bridge: ${BRIDGE_NAME}, Available: ${avail})"

            # Show per-node status
            echo ""
            print_info "Per-node application status (NNCE):"
            oc get nnce 2>/dev/null | grep "${NNCP_NAME}" | \
                awk '{printf "    %-40s %s\n", $1, $2}' || true
        else
            print_error "Invalid selection: ${selection}"
            exit 1
        fi
    fi
}

# =============================================================================
# NAD — register per method
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
    echo "Generated file: nad-${NAD_NAME}.yaml"
    oc apply -f nad-${NAD_NAME}.yaml
    print_ok "NAD ${NAD_NAME} registered"
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
    echo "Generated file: nad-${NAD_NAME}.yaml"
    oc apply -f nad-${NAD_NAME}.yaml
    print_ok "NAD ${NAD_NAME} registered (VLAN ${VLAN_ID})"
}

# Deploy NAD to all namespaces starting with poc-
_deploy_nad_to_poc_namespaces() {
    local nad_file="nad-${NAD_NAME}.yaml"

    # List of poc- namespaces excluding NAD_NAMESPACE
    local poc_namespaces
    poc_namespaces=$(oc get namespaces \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
        tr ' ' '\n' | grep '^poc-' | grep -v "^${NAD_NAMESPACE}$" || true)

    [ -z "$poc_namespaces" ] && return 0

    print_info "NAD (${NAD_NAME}) can be additionally deployed to the following poc- namespaces:"
    echo ""
    for ns in $poc_namespaces; do
        echo "    - ${ns}"
    done
    echo ""
    read -r -p "  Deploy NAD to these namespaces as well? [y/N]: " _nad_confirm
    if [[ "$_nad_confirm" != "y" && "$_nad_confirm" != "Y" ]]; then
        print_info "Skipping additional deployment."
        return 0
    fi

    print_info "Deploying NAD to additional poc- namespaces..."
    for ns in $poc_namespaces; do
        sed "s|namespace: ${NAD_NAMESPACE}|namespace: ${ns}|g" \
            "$nad_file" | oc apply -f -
        print_ok "  NAD ${NAD_NAME} → ${ns}"
    done
}

step_nad() {
    case "$NET_TYPE" in
        1) step_nad_linux_bridge ;;
        2) step_nad_linux_bridge_vlan ;;
    esac
    _deploy_nad_to_poc_namespaces
}

# =============================================================================
# VM creation (poc template + selected NAD)
# =============================================================================
step_vm() {
    print_step "3/4  Create VMs (poc template + ${NAD_NAME})"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc Template not found — skipping VM creation. (Run 01-template first)"
        return
    fi

    local ip_suffixes=(21 22)
    local idx=0

    for suffix in 1 2; do
        local VM_NAME="poc-network-vm-${suffix}"
        local ip_suffix="${ip_suffixes[$idx]}"
        idx=$((idx + 1))

        if oc get vm "$VM_NAME" -n "$NAD_NAMESPACE" &>/dev/null; then
            print_ok "VM $VM_NAME already exists — skipping"
            continue
        fi

        local vm_yaml="${SCRIPT_DIR}/vm-${VM_NAME}.yaml"
        oc process -n openshift poc -p NAME="$VM_NAME" | \
            sed 's/runStrategy: Always/runStrategy: Halted/' | sed 's/  running: false/  runStrategy: Halted/' > "${vm_yaml}"
        echo "Generated file: ${vm_yaml}"
        oc apply -n "$NAD_NAMESPACE" -f "${vm_yaml}"

        ensure_runstrategy "$VM_NAME" "$NAD_NAMESPACE"

        # Add secondary NIC (NAD)
        oc patch vm "$VM_NAME" -n "$NAD_NAMESPACE" --type=json -p='[
          {
            "op": "add",
            "path": "/spec/template/spec/domain/devices/interfaces/-",
            "value": {"name": "bridge-net", "bridge": {}, "model": "virtio"}
          },
          {
            "op": "add",
            "path": "/spec/template/spec/networks/-",
            "value": {"name": "bridge-net", "multus": {"networkName": "'"${NAD_NAME}"'"}}
          }
        ]'

        # cloud-init networkData — add networkData to existing cloudinitdisk volume (before VM start)
        local ci_idx
        ci_idx=$(oc get vm "$VM_NAME" -n "$NAD_NAMESPACE" \
            -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' 2>/dev/null | \
            grep -n "cloudinitdisk" | cut -d: -f1 | head -1)
        # grep -n is 1-based, JSON patch is 0-based
        [ -n "$ci_idx" ] && ci_idx=$(( ci_idx - 1 ))

        if [ -n "$ci_idx" ]; then
            oc patch vm "$VM_NAME" -n "$NAD_NAMESPACE" --type=json -p="[
              {\"op\": \"add\",
               \"path\": \"/spec/template/spec/volumes/${ci_idx}/cloudInitNoCloud/networkData\",
               \"value\": \"version: 2\\nethernets:\\n  eth1:\\n    dhcp4: false\\n    addresses:\\n      - ${SECONDARY_IP_PREFIX}.${ip_suffix}/24\\n    gateway4: ${SECONDARY_IP_PREFIX}.1\\n    nameservers:\\n      addresses:\\n        - 8.8.8.8\\n\"}
            ]"
            print_ok "networkData added → cloudinitdisk (index: ${ci_idx})"
        else
            print_warn "cloudinitdisk volume not found. networkData not configured."
        fi

        virtctl start "$VM_NAME" -n "$NAD_NAMESPACE" 2>/dev/null || true
        print_ok "VM ${VM_NAME} created (eth0: masquerade, eth1: ${NAD_NAME}, IP: ${SECONDARY_IP_PREFIX}.${ip_suffix}/24)"
    done
}

# =============================================================================
# Register ConsoleYAMLSample
# =============================================================================
step_consoleyamlsamples() {
    print_step "4/4  Register ConsoleYAMLSample"

    # NNCP sample — per method
    local nncp_title nncp_desc nncp_yaml
    case "$NET_TYPE" in
        1)
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
            ;;
        2)
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
    echo "Generated file: consoleyamlsample-nncp.yaml"
    oc apply -f consoleyamlsample-nncp.yaml
    print_ok "ConsoleYAMLSample ${NNCP_NAME} registered"

    # NAD sample — generate config block per method
    local nad_config_block
    case "$NET_TYPE" in
        1) nad_config_block="    {
        \"cniVersion\": \"0.3.1\",
        \"name\": \"${NAD_NAME}\",
        \"type\": \"bridge\",
        \"bridge\": \"${BRIDGE_NAME}\",
        \"ipam\": {},
        \"macspoofchk\": true,
        \"preserveDefaultVlan\": false
    }" ;;
        2) nad_config_block="    {
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

    cat > consoleyamlsample-nad.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: ${NAD_NAME}
spec:
  title: "POC NAD — ${NAD_NAME}"
  description: "Register as VM secondary network after applying NNCP. (Method: $(echo "$NET_TYPE" | sed 's/1/Linux Bridge/;s/2/Linux Bridge+VLAN/'))"
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
    echo "Generated file: consoleyamlsample-nad.yaml"
    oc apply -f consoleyamlsample-nad.yaml
    print_ok "ConsoleYAMLSample ${NAD_NAME} registered"
}

# =============================================================================
# Completion summary
# =============================================================================
print_summary() {
    local mode_label
    case "$NET_TYPE" in
        1) mode_label="Linux Bridge" ;;
        2) mode_label="Linux Bridge + VLAN ${VLAN_ID}" ;;
    esac

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! Network configuration (${mode_label})${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  NNCP status : ${CYAN}oc get nncp${NC}"
    echo -e "  NNCE status : ${CYAN}oc get nnce${NC}"
    echo -e "  NAD check   : ${CYAN}oc get net-attach-def -n ${NAD_NAMESPACE}${NC}"
    echo -e "  VM status   : ${CYAN}oc get vm,vmi -n ${NAD_NAMESPACE}${NC}"
    echo ""
    echo -e "  VM IP (eth1):"
    echo -e "    poc-network-vm-1 : ${CYAN}${SECONDARY_IP_PREFIX}.21/24${NC}"
    echo -e "    poc-network-vm-2 : ${CYAN}${SECONDARY_IP_PREFIX}.22/24${NC}"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Delete 02-network resources"
    oc delete vm poc-network-vm-1 poc-network-vm-2 -n poc-network --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-bridge-nncp poc-bridge-nad poc-bridge-vlan-nad --ignore-not-found 2>/dev/null || true
    oc delete project poc-network --ignore-not-found 2>/dev/null || true
    echo ""
    for _nncp in $(oc get nncp -o name 2>/dev/null | grep poc- || true); do
        local _name="${_nncp#*/}"
        read -r -p "Delete NNCP ${_name}? This will remove the node bridge. [y/N]: " _del
        [[ "$_del" = "y" || "$_del" = "Y" ]] && oc delete nncp "$_name" --ignore-not-found 2>/dev/null || true
    done
    print_ok "02-network resources deleted"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  02-network: NNCP + NAD + VM configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

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
