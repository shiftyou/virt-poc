#!/bin/bash
# =============================================================================
# virt-poc environment setup script
# Collects common environment variables for OpenShift Virtualization POC testing
# and generates the env.conf file.
#
# Lab-specific variables (S3, IPMI, Grafana, Alert, etc.) are collected by
# each lab script at runtime and appended to env.conf automatically.
#
# Usage: ./setup.sh
# =============================================================================

set -xeuo pipefail
trap 'echo -e "\n\033[0;31m[ERROR]\033[0m Command failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

ENV_FILE="./env.conf"
EXAMPLE_FILE="./env.conf.example"

source "$(dirname "${BASH_SOURCE[0]}")/utils/common.sh"

# Check oc command
check_oc() {
    if ! command -v oc &> /dev/null; then
        print_warn "oc command not found. Saving settings without connecting to OpenShift cluster."
        return 1
    fi

    if ! oc whoami &> /dev/null; then
        print_warn "Not logged into the OpenShift cluster. Saving settings only."
        return 1
    fi

    print_ok "OpenShift cluster connection confirmed: $(oc whoami)"
    return 0
}

# Check operator installation
check_operators() {
    print_header "Pre-requisites: Operator Installation Check"

    VIRT_INSTALLED=false
    MTV_INSTALLED=false
    DESCHEDULER_INSTALLED=false
    FAR_INSTALLED=false
    NMO_INSTALLED=false
    NHC_INSTALLED=false
    SNR_INSTALLED=false
    NMSTATE_INSTALLED=false
    OADP_INSTALLED=false
    OADP_NS="openshift-adp"
    GRAFANA_INSTALLED=false
    COO_INSTALLED=false
    ODF_INSTALLED=false
    LOGGING_INSTALLED=false
    LOKI_INSTALLED=false

    if check_oc 2>/dev/null; then
        oc get csv -A 2>/dev/null > /tmp/_poc_csv.txt || true

        grep -qi "kubevirt-hyperconverged"   /tmp/_poc_csv.txt 2>/dev/null && VIRT_INSTALLED=true
        grep -qi "mtv-operator"              /tmp/_poc_csv.txt 2>/dev/null && MTV_INSTALLED=true
        grep -qi "kube-descheduler"          /tmp/_poc_csv.txt 2>/dev/null && DESCHEDULER_INSTALLED=true
        grep -qi "fence-agents-remediation"  /tmp/_poc_csv.txt 2>/dev/null && FAR_INSTALLED=true
        grep -qi "node-maintenance"          /tmp/_poc_csv.txt 2>/dev/null && NMO_INSTALLED=true
        grep -qi "node-healthcheck"          /tmp/_poc_csv.txt 2>/dev/null && NHC_INSTALLED=true
        grep -qi "self-node-remediation"     /tmp/_poc_csv.txt 2>/dev/null && SNR_INSTALLED=true
        grep -qi "kubernetes-nmstate"        /tmp/_poc_csv.txt 2>/dev/null && NMSTATE_INSTALLED=true
        if grep -qi "oadp-operator" /tmp/_poc_csv.txt 2>/dev/null; then
            OADP_INSTALLED=true
            OADP_NS=$(oc get subscription -A 2>/dev/null | grep -i "oadp\|redhat-oadp" | awk '{print $1}' | head -1)
            OADP_NS="${OADP_NS:-openshift-adp}"
        fi
        grep -qi "grafana-operator"               /tmp/_poc_csv.txt 2>/dev/null && GRAFANA_INSTALLED=true
        grep -qi "cluster-observability-operator" /tmp/_poc_csv.txt 2>/dev/null && COO_INSTALLED=true
        grep -qi "odf-operator\|ocs-operator"     /tmp/_poc_csv.txt 2>/dev/null && ODF_INSTALLED=true
        grep -qi "cluster-logging"                /tmp/_poc_csv.txt 2>/dev/null && LOGGING_INSTALLED=true
        grep -qi "loki-operator"                  /tmp/_poc_csv.txt 2>/dev/null && LOKI_INSTALLED=true
        rm -f /tmp/_poc_csv.txt
        NMSTATE_CR_EXISTS=false
        if [ "$NMSTATE_INSTALLED" = "true" ]; then
            oc get nmstate 2>/dev/null | grep -q "." && NMSTATE_CR_EXISTS=true || true
        fi
    else
        print_warn "Cannot check operator status because the cluster is not connected."
        print_info "How to install operators: refer to operators/README.md"
        echo ""
        return
    fi

    local ok="${GREEN}[✔]${NC}"
    local ng="${RED}[✘]${NC}"
    local wa="${YELLOW}[~]${NC}"

    echo ""
    printf "  %-45s %s\n" "Operator" "Status"
    echo "  ──────────────────────────────────────────────────────────"
    if [ "$VIRT_INSTALLED" = "true" ]; then
        echo -e "  $ok OpenShift Virtualization Operator  → Virtualization available"
    else
        echo -e "  $ng OpenShift Virtualization Operator  → Not installed  (operators/)"
    fi
    if [ "$MTV_INSTALLED" = "true" ]; then
        echo -e "  $ok Migration Toolkit for Virt Operator → MTV available"
    else
        echo -e "  $ng Migration Toolkit for Virt Operator → Not installed"
    fi
    if [ "$NMSTATE_INSTALLED" = "true" ] && [ "${NMSTATE_CR_EXISTS:-false}" = "true" ]; then
        echo -e "  $ok Kubernetes NMState Operator        → NodeNetworkState query available"
    elif [ "$NMSTATE_INSTALLED" = "true" ]; then
        echo -e "  $wa Kubernetes NMState Operator        → No NMState CR (oc apply -f nmstate-cr.yaml required)  (operators/nmstate-operator.md)"
    else
        echo -e "  $ng Kubernetes NMState Operator        → NNCP/NNS unavailable  (operators/nmstate-operator.md)"
    fi
    if [ "$DESCHEDULER_INSTALLED" = "true" ]; then
        echo -e "  $ok Kube Descheduler Operator          → descheduler configurable"
    else
        echo -e "  $ng Kube Descheduler Operator          → descheduler skipped  (operators/descheduler-operator.md)"
    fi
    if [ "$ODF_INSTALLED" = "true" ]; then
        echo -e "  $ok ODF Operator                       → OpenShift Data Foundation available"
    else
        echo -e "  $ng ODF Operator                       → Not installed"
    fi
    if [ "$OADP_INSTALLED" = "true" ]; then
        echo -e "  $ok OADP Operator                      → Backup/restore configurable  (ns: ${OADP_NS})"
    else
        echo -e "  $ng OADP Operator                      → Backup/restore skipped  (operators/oadp-operator.md)"
    fi
    if [ "$GRAFANA_INSTALLED" = "true" ]; then
        echo -e "  $ok Grafana Community Operator         → Grafana dashboard configurable"
    else
        echo -e "  $ng Grafana Community Operator         → Not installed  (refer to 11-monitoring.md)"
    fi
    if [ "$COO_INSTALLED" = "true" ]; then
        echo -e "  $ok Cluster Observability Operator     → MonitoringStack available"
    else
        echo -e "  $ng Cluster Observability Operator     → Skipped  (operators/coo-operator.md)"
    fi
    if [ "$FAR_INSTALLED" = "true" ]; then
        echo -e "  $ok Fence Agents Remediation Operator  → FAR configurable"
    else
        echo -e "  $ng Fence Agents Remediation Operator  → FAR skipped  (operators/far-operator.md)"
    fi
    if [ "$NMO_INSTALLED" = "true" ]; then
        echo -e "  $ok Node Maintenance Operator          → Node maintenance available"
    else
        echo -e "  $ng Node Maintenance Operator          → Node maintenance skipped  (operators/node-maintenance-operator.md)"
    fi
    if [ "$NHC_INSTALLED" = "true" ]; then
        echo -e "  $ok Node Health Check Operator         → NHC configurable"
    else
        echo -e "  $ng Node Health Check Operator         → NHC skipped  (operators/nhc-operator.md)"
    fi
    if [ "$SNR_INSTALLED" = "true" ]; then
        echo -e "  $ok Self Node Remediation Operator     → SNR configurable"
    else
        echo -e "  $ng Self Node Remediation Operator     → SNR skipped  (operators/snr-operator.md)"
    fi
    if [ "$LOGGING_INSTALLED" = "true" ]; then
        echo -e "  $ok OpenShift Logging Operator         → Log collection configurable"
    else
        echo -e "  $ng OpenShift Logging Operator         → Not installed"
    fi
    if [ "$LOKI_INSTALLED" = "true" ]; then
        echo -e "  $ok Loki Operator                      → LokiStack configurable"
    else
        echo -e "  $ng Loki Operator                      → Not installed"
    fi
    echo "  ──────────────────────────────────────────────────────────"
    echo ""
}

# Cluster information auto-detection
auto_detect_cluster() {
    if check_oc; then
        DETECTED_API=$(oc whoami --show-server 2>/dev/null || echo "")
        DETECTED_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null | sed 's/^apps\.//' || echo "")
        if [ -n "$DETECTED_API" ]; then
            print_info "Detected API server: $DETECTED_API"
        fi
        if [ -n "$DETECTED_DOMAIN" ]; then
            print_info "Detected cluster domain: $DETECTED_DOMAIN"
        fi

        # StorageClass auto-detection: virtualization-specific → ceph-rbd family → default
        DETECTED_SC=$(oc get sc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | \
            grep -i "virtualization" | head -1 || true)
        if [ -z "$DETECTED_SC" ]; then
            DETECTED_SC=$(oc get sc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | \
                grep -i "ceph-rbd" | head -1 || true)
        fi
        if [ -z "$DETECTED_SC" ]; then
            DETECTED_SC=$(oc get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")
        fi
        if [ -n "$DETECTED_SC" ]; then
            print_info "Detected StorageClass: $DETECTED_SC"
        fi
        ALL_SC=$(oc get sc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | tr '\n' ' ' || echo "")
        if [ -n "$ALL_SC" ]; then
            print_info "Available StorageClasses: $ALL_SC"
        fi

        # Node network interface auto-detection
        FIRST_WORKER_FOR_NNS=$(oc get nodes -l node-role.kubernetes.io/worker \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        DETECTED_IFACES=""
        if [ -n "$FIRST_WORKER_FOR_NNS" ]; then
            local brex_slaves
            brex_slaves=$(oc get nns "$FIRST_WORKER_FOR_NNS" \
                -o jsonpath='{range .status.currentState.interfaces[*]}{.name}{" "}{.controller}{"\n"}{end}' \
                2>/dev/null | awk '$2=="br-ex"{print $1}' | tr '\n' '|' | sed 's/|$//' || true)
            DETECTED_IFACES=$(oc get nns "$FIRST_WORKER_FOR_NNS" \
                -o jsonpath='{range .status.currentState.interfaces[*]}{.name}{" "}{.type}{" "}{.state}{"\n"}{end}' \
                2>/dev/null | awk '$2=="ethernet" && $3=="up"{print $1}' | \
                grep -vE "^(br-ex|ovs-system)${brex_slaves:+|${brex_slaves}}" | \
                tr '\n' ' ' | xargs || true)
        fi
        if [ -z "$DETECTED_IFACES" ] && [ -n "$FIRST_WORKER_FOR_NNS" ]; then
            if [ "${NMSTATE_INSTALLED:-false}" = "true" ] && [ "${NMSTATE_CR_EXISTS:-false}" != "true" ]; then
                print_warn "NMState Operator is installed but no NMState CR exists."
                print_info "To use NodeNetworkState: oc apply -f - <<'EOF'
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
EOF"
            fi
            print_info "No NodeNetworkState → detecting interfaces via oc debug node (approx. 30 seconds)..."
            DETECTED_IFACES=$(oc debug node/"$FIRST_WORKER_FOR_NNS" -- \
                chroot /host ip -o link show 2>/dev/null | \
                awk '/[Ss]tate UP/ && !/master ovs-system/ && !/master br-ex/ {split($2,a,"@"); gsub(/:$/,"",a[1]); print a[1]}' | \
                grep -vE '^(lo|ovs-system|br-ex|br-int|genev_sys|veth|tun|docker|ovn)' | \
                grep -E '^(ens|eth|eno|enp|em|bond)' | tr '\n' ' ' | xargs || true)
        fi
        DETECTED_IFACE=$(echo "$DETECTED_IFACES" | awk '{print $1}')
        if [ -n "$DETECTED_IFACES" ]; then
            print_info "Detected network interfaces (node: $FIRST_WORKER_FOR_NNS): $DETECTED_IFACES"
        fi
    else
        DETECTED_API=""
        DETECTED_DOMAIN=""
        DETECTED_SC=""
        DETECTED_IFACE=""
        DETECTED_IFACES=""
    fi
}

# =============================================================================
# Main execution
# =============================================================================

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  OpenShift Virtualization POC Environment Setup${NC}"
echo -e "${CYAN}  virt-poc setup.sh${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check OpenShift cluster login
if ! command -v oc &>/dev/null; then
    print_error "oc command not found. Please install the OpenShift CLI."
    exit 1
fi
if ! oc whoami &>/dev/null; then
    print_error "Not logged into the OpenShift cluster."
    print_info "Please log in to the cluster first with 'oc login'."
    exit 1
fi
print_ok "Cluster connection confirmed: $(oc whoami) @ $(oc whoami --show-server 2>/dev/null)"
echo ""

# Check existing env.conf
if [ -f "$ENV_FILE" ]; then
    print_warn "An existing env.conf file was found."
    echo -n -e "${YELLOW}  Do you want to overwrite it? (y/N): ${NC}"
    read overwrite
    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
        print_info "Setup cancelled. Using existing env.conf file."
        exit 0
    fi
fi

# Cluster auto-detection and operator check
auto_detect_cluster
check_operators

# =============================================================================
# [01] Template — DataVolume / DataSource / Template registration
# =============================================================================
print_step_header "[01]" "Template — DataVolume / DataSource / Template registration"

ask "StorageClass to use for VM image upload" "${DETECTED_SC:-ocs-external-storagecluster-ceph-rbd}" STORAGE_CLASS
ask "poc-golden.qcow2 image download URL" "http://146.56.160.95/poc-golden.qcow2" GOLDEN_IMAGE_URL

# =============================================================================
# [02] Network — NNCP / NAD / VM creation
# =============================================================================
print_step_header "[02]" "Network — NNCP / NAD / VM creation"

# Display NNCP list and select by type
NNCP_NAME="br-poc-nncp"
NNCP_IFACE_TYPE="linux-bridge"
NET_TYPE="1"
NAD_NAME="poc-bridge-nad"
LOCALNET_NAME="poc-localnet"
VLAN_ID="100"
BOND_NAME="bond0"
BOND_MODE="active-backup"
BOND_INTERFACE_2="ens5"
_USE_EXISTING_NNCP=false
_NNCP_NAMES=()

if command -v oc &>/dev/null && oc whoami &>/dev/null 2>&1; then
    _ALL_NNCPS=$(oc get nncp -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' || true)

    if [ -n "$_ALL_NNCPS" ]; then
        echo ""
        print_info "Current cluster NNCP list:"
        echo ""
        printf "  %-4s %-28s %-12s %-14s %-8s %s\n" "No." "NNCP Name" "Type" "Bridge" "Status" "NIC"
        echo "  ──────────────────────────────────────────────────────────────────────────────"
        _idx=1
        while read -r _n; do
            [ -z "$_n" ] && continue
            detect_nncp_type "$_n"
            _avail=$(oc get nncp "$_n" \
                -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' \
                2>/dev/null || true)
            printf "  ${GREEN}%-4s %-28s %-12s %-14s %-8s %s${NC}\n" \
                "${_idx})" "$_n" "$(nncp_type_label "$NNCP_IFACE_TYPE")" \
                "${BRIDGE_NAME:-N/A}" "${_avail:-Unknown}" "${BRIDGE_INTERFACE:-N/A}"
            _NNCP_NAMES+=("$_n")
            _idx=$((_idx + 1))
        done <<< "$_ALL_NNCPS"
        echo ""
        echo "  0) Create a new NNCP (Linux Bridge / OVS / Bond / VLAN)"
        echo ""
        read -r -p "  Select NNCP [1-$((_idx-1)), or 0 to create new, Enter=skip]: " _sel_input
        if [ -n "$_sel_input" ] && [ "$_sel_input" != "0" ]; then
            if [[ "$_sel_input" =~ ^[0-9]+$ ]] && [ "$_sel_input" -ge 1 ] && [ "$_sel_input" -lt "$_idx" ]; then
                NNCP_NAME="${_NNCP_NAMES[$((_sel_input-1))]}"
                detect_nncp_type "$NNCP_NAME"
                select_localnet
                _USE_EXISTING_NNCP=true
                print_ok "Selected: ${NNCP_NAME} (type: $(nncp_type_label "$NNCP_IFACE_TYPE"), bridge: ${BRIDGE_NAME})"
            else
                NNCP_NAME="$_sel_input"
                detect_nncp_type "$NNCP_NAME"
                select_localnet
                _USE_EXISTING_NNCP=true
                print_ok "Selected: ${NNCP_NAME}"
            fi
        elif [ "$_sel_input" = "0" ]; then
            _USE_EXISTING_NNCP=false
        fi
    else
        echo ""
        print_info "No NNCPs exist in the cluster."
    fi
fi

if [ "$_USE_EXISTING_NNCP" = "false" ]; then
    echo ""
    if [ -n "${DETECTED_IFACES:-}" ]; then
        print_info "Detected interface list: $DETECTED_IFACES"
    else
        print_info "Check node network interfaces: oc debug node/<node> -- ip link show"
    fi
    BRIDGE_INTERFACE="${DETECTED_IFACE:-ens4}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Linux Bridge"
    echo -e "  ${GREEN}2)${NC} OVS Bridge (OVN Localnet)"
    echo -e "  ${GREEN}3)${NC} Bond + Linux Bridge"
    echo -e "  ${GREEN}4)${NC} VLAN + Linux Bridge"
    echo ""
    read -r -p "  Select NNCP type [1-4, Enter=1]: " _iface_sel
    case "${_iface_sel:-1}" in
        1) NNCP_IFACE_TYPE="linux-bridge"; BRIDGE_NAME="br-poc"; NNCP_NAME="${BRIDGE_NAME}-nncp"; _gen_type=1 ;;
        2) NNCP_IFACE_TYPE="ovs-bridge"; BRIDGE_NAME="ovs-br-poc"; NNCP_NAME="${BRIDGE_NAME}-nncp"; _gen_type=3 ;;
        3) NNCP_IFACE_TYPE="bond"; BRIDGE_NAME="br-poc"; NNCP_NAME="${BRIDGE_NAME}-bond-nncp"; _gen_type=4 ;;
        4) NNCP_IFACE_TYPE="vlan"; BRIDGE_NAME="br-poc"; NNCP_NAME="${BRIDGE_NAME}-vlan-nncp"; _gen_type=5 ;;
        *) NNCP_IFACE_TYPE="linux-bridge"; BRIDGE_NAME="br-poc"; NNCP_NAME="${BRIDGE_NAME}-nncp"; _gen_type=1 ;;
    esac
    print_info "  NIC       : ${BRIDGE_INTERFACE}"
    print_info "  NNCP Name : ${NNCP_NAME}"
    echo ""
    echo -n -e "${YELLOW}  Do you want to run nncp-gen.sh to create the NNCP now? (Y/n): ${NC}"
    read _run_nncp_gen
    if [[ ! "${_run_nncp_gen:-}" =~ ^[Nn]$ ]]; then
        _SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        export BRIDGE_NAME BRIDGE_INTERFACE NNCP_NAME LOCALNET_NAME BOND_NAME BOND_MODE BOND_INTERFACE_2 VLAN_ID
        bash "${_SETUP_DIR}/02-network/nncp-gen.sh" "$_gen_type"
    fi
fi

resolve_nad_name
print_info "  NAD_NAME          : ${NAD_NAME}"
print_info "  NNCP_IFACE_TYPE   : ${NNCP_IFACE_TYPE}"

echo ""
print_info "SECONDARY_IP_PREFIX: The network prefix used for static IP assignment to secondary NIC (eth1) via cloud-init."
print_info "SECONDARY_IP_START / END: IP range (last octet). IPs are assigned sequentially per lab."
print_info "  e.g.) prefix=192.168.200, range=1~254 → 02-network: .1,.2 / 03-vm: .3,.4 / 05-netpol: .5,.6"
ask "Secondary NIC IP prefix (first 3 octets)" "192.168.200" SECONDARY_IP_PREFIX
ask "Secondary NIC IP range start (last octet)" "1" SECONDARY_IP_START
ask "Secondary NIC IP range end   (last octet)" "254" SECONDARY_IP_END
if (( SECONDARY_IP_END - SECONDARY_IP_START < 5 )); then
    print_warn "IP range too small (need at least 6 IPs). Adjusting end to $(( SECONDARY_IP_START + 10 ))."
    SECONDARY_IP_END=$(( SECONDARY_IP_START + 10 ))
fi
print_info "  IP range: ${SECONDARY_IP_PREFIX}.${SECONDARY_IP_START} ~ ${SECONDARY_IP_PREFIX}.${SECONDARY_IP_END}"

# =============================================================================
# Save env.conf
# =============================================================================
print_header "Saving env.conf..."

cat > "$ENV_FILE" << EOF
# =============================================================================
# virt-poc environment configuration file
# Auto-generated by setup.sh: $(date)
# Lab-specific variables are appended by each lab script at runtime.
# This file is registered in .gitignore and will not be committed to git.
# =============================================================================

# Network configuration
NNCP_NAME=${NNCP_NAME}
BRIDGE_INTERFACE=${BRIDGE_INTERFACE}
BRIDGE_NAME=${BRIDGE_NAME}
NNCP_IFACE_TYPE=${NNCP_IFACE_TYPE}
NAD_NAME=${NAD_NAME}
NET_TYPE=${NET_TYPE}
LOCALNET_NAME=${LOCALNET_NAME}
VLAN_ID=${VLAN_ID}
BOND_NAME=${BOND_NAME}
BOND_MODE=${BOND_MODE}
BOND_INTERFACE_2=${BOND_INTERFACE_2}
SECONDARY_IP_PREFIX=${SECONDARY_IP_PREFIX}
SECONDARY_IP_START=${SECONDARY_IP_START}
SECONDARY_IP_END=${SECONDARY_IP_END}

# StorageClass
STORAGE_CLASS=${STORAGE_CLASS}

# Golden Image URL (DataVolume HTTP import)
GOLDEN_IMAGE_URL=${GOLDEN_IMAGE_URL}

# Operator installation status (auto-detected when setup.sh runs)
VIRT_INSTALLED=${VIRT_INSTALLED:-false}
MTV_INSTALLED=${MTV_INSTALLED:-false}
NMSTATE_INSTALLED=${NMSTATE_INSTALLED:-false}
OADP_INSTALLED=${OADP_INSTALLED:-false}
OADP_NS=${OADP_NS}
GRAFANA_INSTALLED=${GRAFANA_INSTALLED:-false}
COO_INSTALLED=${COO_INSTALLED:-false}
DESCHEDULER_INSTALLED=${DESCHEDULER_INSTALLED:-false}
FAR_INSTALLED=${FAR_INSTALLED:-false}
NMO_INSTALLED=${NMO_INSTALLED:-false}
NHC_INSTALLED=${NHC_INSTALLED:-false}
SNR_INSTALLED=${SNR_INSTALLED:-false}
ODF_INSTALLED=${ODF_INSTALLED:-false}
LOGGING_INSTALLED=${LOGGING_INSTALLED:-false}
LOKI_INSTALLED=${LOKI_INSTALLED:-false}
EOF

print_ok "env.conf file has been created: $ENV_FILE"

# =============================================================================
# Completion message
# =============================================================================
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Setup complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  Next steps:"
echo -e ""
echo -e "  ${CYAN}[1] Install operators${NC}"
echo -e "      operators/README.md"
echo -e ""
echo -e "  ${CYAN}[2] Run poc.sh${NC}"
echo -e "      ./poc.sh"
echo ""
