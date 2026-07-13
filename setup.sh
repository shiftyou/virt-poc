#!/bin/bash
# =============================================================================
# virt-poc environment setup script
# Collects environment variables for OpenShift Virtualization POC testing
# and generates the env.conf file.
#
# Usage: ./setup.sh
# =============================================================================

set -euo pipefail

ENV_FILE="./env.conf"
EXAMPLE_FILE="./env.conf.example"

# Color output settings
RED='\033[0;31m'
GREEN='\033[0;32m'
DIM='\033[2m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

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

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_ok() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Value input function: prompt message, default value, variable name
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
            # Detect the namespaces where OADP is installed
            local _oadp_ns_list
            _oadp_ns_list=$(oc get csv -A 2>/dev/null | grep -i "oadp-operator" | awk '{print $1}')
            local _oadp_ns_count
            _oadp_ns_count=$(echo "$_oadp_ns_list" | grep -c . || true)
            if [ "$_oadp_ns_count" -eq 1 ]; then
                OADP_NS=$(echo "$_oadp_ns_list")
            elif [ "$_oadp_ns_count" -gt 1 ]; then
                echo ""
                print_info "OADP Operator is installed in multiple namespaces:"
                local _i=1
                while IFS= read -r _ns; do
                    echo "    ${_i}) ${_ns}"
                    _i=$((_i+1))
                done <<< "$_oadp_ns_list"
                read -r -p "  Enter namespace number or name to use [1]: " _sel
                _sel="${_sel:-1}"
                if [[ "$_sel" =~ ^[0-9]+$ ]]; then
                    OADP_NS=$(echo "$_oadp_ns_list" | sed -n "${_sel}p")
                else
                    OADP_NS="$_sel"
                fi
            else
                OADP_NS="openshift-adp"
            fi
        fi
        grep -qi "grafana-operator"               /tmp/_poc_csv.txt 2>/dev/null && GRAFANA_INSTALLED=true
        grep -qi "cluster-observability-operator" /tmp/_poc_csv.txt 2>/dev/null && COO_INSTALLED=true
        grep -qi "odf-operator\|ocs-operator"     /tmp/_poc_csv.txt 2>/dev/null && ODF_INSTALLED=true
        grep -qi "cluster-logging"                /tmp/_poc_csv.txt 2>/dev/null && LOGGING_INSTALLED=true
        grep -qi "loki-operator"                  /tmp/_poc_csv.txt 2>/dev/null && LOKI_INSTALLED=true
        rm -f /tmp/_poc_csv.txt
        # Check separately whether NMState CR instance exists
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

# Garage auto-detection
auto_detect_garage() {
    GARAGE_ENDPOINT=""
    GARAGE_BUCKET="velero"
    GARAGE_ACCESS_KEY="garage"
    GARAGE_SECRET_KEY="garage123"

    # Search namespaces by app=garage label service (detect community standalone deployment)
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

        # Search credentials secret
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

# ODF (NooBaa MCG) auto-detection
auto_detect_odf() {
    ODF_S3_ENDPOINT=""
    ODF_S3_BUCKET="velero"
    ODF_S3_REGION="localstorage"
    ODF_S3_ACCESS_KEY=""
    ODF_S3_SECRET_KEY=""

    local odf_ns="openshift-storage"

    # NooBaa MCG S3 internal endpoint
    ODF_S3_ENDPOINT=$(oc get noobaa -n "$odf_ns" \
        -o jsonpath='{.status.services.serviceS3.internalDNS[0]}' 2>/dev/null || true)
    if [ -z "$ODF_S3_ENDPOINT" ]; then
        # Construct directly from s3 service
        local s3_port
        s3_port=$(oc get svc s3 -n "$odf_ns" \
            -o jsonpath='{.spec.ports[?(@.name=="s3")].port}' 2>/dev/null || echo "80")
        ODF_S3_ENDPOINT="http://s3.${odf_ns}.svc.cluster.local:${s3_port}"
    fi

    # Get credentials from noobaa-admin secret
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
        # Method 1: NodeNetworkState (NMState operator, fast)
        FIRST_WORKER_FOR_NNS=$(oc get nodes -l node-role.kubernetes.io/worker \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        DETECTED_IFACES=""
        if [ -n "$FIRST_WORKER_FOR_NNS" ]; then
            # Collect interfaces attached to br-ex (controller=br-ex)
            local brex_slaves
            brex_slaves=$(oc get nns "$FIRST_WORKER_FOR_NNS" \
                -o jsonpath='{range .status.currentState.interfaces[*]}{.name}{" "}{.controller}{"\n"}{end}' \
                2>/dev/null | awk '$2=="br-ex"{print $1}' | tr '\n' '|' | sed 's/|$//' || true)
            # Ethernet interfaces with state=up, excluding br-ex and its slaves
            DETECTED_IFACES=$(oc get nns "$FIRST_WORKER_FOR_NNS" \
                -o jsonpath='{range .status.currentState.interfaces[*]}{.name}{" "}{.type}{" "}{.state}{"\n"}{end}' \
                2>/dev/null | awk '$2=="ethernet" && $3=="up"{print $1}' | \
                grep -vE "^(br-ex|ovs-system)${brex_slaves:+|${brex_slaves}}" | \
                tr '\n' ' ' | xargs || true)
        fi
        # Method 2: oc debug node (fallback, slow ~30s)
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
            # Include only NICs that are UP and not subordinate to br-ex/ovs-system
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

CONSOLE_ALLOWED_CIDRS="0.0.0.0/0"
API_ALLOWED_CIDRS="0.0.0.0/0"

# =============================================================================
# [ Cluster ] Cluster basic information
# =============================================================================
print_step_header "[ Cluster ]" "Cluster basic information"

ask "Cluster base domain (e.g. example.com)" "${DETECTED_DOMAIN:-example.com}" CLUSTER_DOMAIN
ask "API server URL" "${DETECTED_API:-https://api.${CLUSTER_DOMAIN}:6443}" CLUSTER_API

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

# Display NNCP list and select linux-bridge
NNCP_NAME="br-poc-nncp"
_USE_EXISTING_NNCP=false
_LB_NNCPS=()

if command -v oc &>/dev/null && oc whoami &>/dev/null 2>&1; then
    _ALL_NNCPS=$(oc get nncp -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' || true)

    if [ -n "$_ALL_NNCPS" ]; then
        echo ""
        print_info "Current cluster NNCP list:"
        echo ""
        printf "  %-4s %-32s %-15s %-18s %-8s %s\n" "No." "NNCP Name" "Type" "Bridge Name" "Status" "NIC"
        echo "  ──────────────────────────────────────────────────────────────────────────────────"
        _idx=1
        for _n in $_ALL_NNCPS; do
            _br=$(oc get nncp "$_n" \
                -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.name}{end}' \
                2>/dev/null || true)
            _avail=$(oc get nncp "$_n" \
                -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' \
                2>/dev/null || true)
            if [ -n "$_br" ]; then
                _nic=$(oc get nncp "$_n" \
                    -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.bridge.port[0].name}{end}' \
                    2>/dev/null || true)
                _type="linux-bridge"
                _LB_NNCPS+=("$_n")
                printf "  ${GREEN}%-4s %-32s %-15s %-18s %-8s %s${NC}\n" \
                    "${_idx})" "$_n" "$_type" "${_br:-N/A}" "${_avail:-Unknown}" "${_nic:-N/A}"
            else
                printf "  ${DIM}%-4s %-32s %-15s %-18s %-8s %s${NC}\n" \
                    "${_idx})" "$_n" "other" "-" "${_avail:-Unknown}" "-"
            fi
            _idx=$((_idx + 1))
        done
        echo ""
    else
        echo ""
        print_info "No NNCPs exist in the cluster."
    fi
fi

if [ ${#_LB_NNCPS[@]} -gt 0 ]; then
    _FIRST_LB="${_LB_NNCPS[0]}"
    if [ ${#_LB_NNCPS[@]} -eq 1 ]; then
        _cand_br=$(oc get nncp "$_FIRST_LB" \
            -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.name}{end}' \
            2>/dev/null || true)
        _cand_nic=$(oc get nncp "$_FIRST_LB" \
            -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.bridge.port[0].name}{end}' \
            2>/dev/null || true)
        echo -n -e "${YELLOW}  Use linux-bridge NNCP '${_FIRST_LB}' (bridge: ${_cand_br}, NIC: ${_cand_nic:-N/A})? (Y/n): ${NC}"
        read _use_existing
        if [[ ! "${_use_existing:-}" =~ ^[Nn]$ ]]; then
            _USE_EXISTING_NNCP=true
            NNCP_NAME="$_FIRST_LB"
            BRIDGE_NAME="${_cand_br:-br-poc}"
            BRIDGE_INTERFACE="${_cand_nic:-${DETECTED_IFACE:-ens4}}"
            print_ok "Selected: ${NNCP_NAME}  (bridge: ${BRIDGE_NAME}, NIC: ${BRIDGE_INTERFACE})"
        fi
    else
        echo -n -e "${YELLOW}  Enter linux-bridge NNCP number or name [default: ${_FIRST_LB}] (press Enter then n to skip): ${NC}"
        read _sel_input
        if [ -z "$_sel_input" ]; then
            _sel_nncp="$_FIRST_LB"
        elif [[ "$_sel_input" =~ ^[0-9]+$ ]]; then
            _sel_nncp="${_LB_NNCPS[$((_sel_input - 1))]:-$_FIRST_LB}"
        else
            _sel_nncp="$_sel_input"
        fi
        _sel_br=$(oc get nncp "$_sel_nncp" \
            -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.name}{end}' \
            2>/dev/null || true)
        _sel_nic=$(oc get nncp "$_sel_nncp" \
            -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.bridge.port[0].name}{end}' \
            2>/dev/null || true)
        echo -n -e "${YELLOW}  Use '${_sel_nncp}' (bridge: ${_sel_br}, NIC: ${_sel_nic:-N/A})? (Y/n): ${NC}"
        read _use_existing
        if [[ ! "${_use_existing:-}" =~ ^[Nn]$ ]]; then
            _USE_EXISTING_NNCP=true
            NNCP_NAME="$_sel_nncp"
            BRIDGE_NAME="${_sel_br:-br-poc}"
            BRIDGE_INTERFACE="${_sel_nic:-${DETECTED_IFACE:-ens4}}"
            print_ok "Selected: ${NNCP_NAME}  (bridge: ${BRIDGE_NAME}, NIC: ${BRIDGE_INTERFACE})"
        fi
    fi
fi

if [ "$_USE_EXISTING_NNCP" = "false" ]; then
    echo ""
    if [ -n "${DETECTED_IFACES:-}" ]; then
        print_info "Detected interface list: $DETECTED_IFACES"
    else
        print_info "Check node network interfaces: oc debug node/<node> -- ip link show"
    fi
    ask "Linux Bridge name to create" "br-poc" BRIDGE_NAME
    BRIDGE_INTERFACE="${DETECTED_IFACE:-ens4}"
    NNCP_NAME="${BRIDGE_NAME}-nncp"
    print_info "  NIC       : ${BRIDGE_INTERFACE}"
    print_info "  NNCP Name : ${NNCP_NAME}"
    echo ""
    echo -n -e "${YELLOW}  Do you want to run nncp-gen.sh to create the NNCP now? (Y/n): ${NC}"
    read _run_nncp_gen
    if [[ ! "${_run_nncp_gen:-}" =~ ^[Nn]$ ]]; then
        _SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        export BRIDGE_NAME BRIDGE_INTERFACE NNCP_NAME
        bash "${_SETUP_DIR}/02-network/nncp-gen.sh" 1
    fi
fi

echo ""
print_info "SECONDARY_IP_PREFIX: The network prefix used for static IP assignment to secondary NIC (eth1) via cloud-init."
print_info "  e.g.) 192.168.100 → 02-network VM: .21, .22 / 03-vm: .31 / 05-network-policy: .51, .52"
ask "Secondary NIC IP prefix (cloud-init networkData)" "192.168.100" SECONDARY_IP_PREFIX

# =============================================================================
# [10] Monitoring — Grafana dashboard
# =============================================================================
if [ "${GRAFANA_INSTALLED:-false}" = "true" ]; then
    print_step_header "[10]" "Monitoring — Grafana dashboard"
    ask "Grafana admin password" "grafana123" GRAFANA_ADMIN_PASS "true"
else
    print_info "[10] Monitoring — Grafana Operator not installed, skipping."
    GRAFANA_ADMIN_PASS="grafana123"
fi

# =============================================================================
# [11] MTV — VMware → OpenShift migration
# =============================================================================
if [ "${MTV_INSTALLED:-false}" = "true" ]; then
    print_step_header "[11]" "MTV — VMware → OpenShift migration"
    print_info "VDDK 7 download url http://146.56.160.95/VMware-vix-disklib-7.0.3-23007270.x86_64.tar.gz"
    print_info "VDDK 8 download url http://146.56.160.95/VMware-vix-disklib-8.0.3-23950268.x86_64.tar.gz"
    print_info "VDDK image path (enter after pushing directly to the internal registry)"
    ask "VDDK image path" "image-registry.openshift-image-registry.svc:5000/openshift/vddk:latest" VDDK_IMAGE
else
    print_info "[11] MTV — MTV Operator not installed, skipping."
    VDDK_IMAGE="image-registry.openshift-image-registry.svc:5000/openshift/vddk:latest"
fi

# =============================================================================
# [12] OADP — VM backup/restore (Garage / ODF backend auto-detection)
# =============================================================================
if [ "${OADP_INSTALLED:-false}" = "true" ]; then
    print_step_header "[12]" "OADP — VM backup/restore backend configuration"

    # Detect if Garage is running
    auto_detect_garage

    if [ "${GARAGE_FOUND}" = "true" ]; then
        print_ok "Garage running detected — please verify connection info."
        echo ""

        # If a Route exists, suggest the external URL
        local garage_route
        garage_route=$(oc get route garage-api -n garage \
            -o jsonpath='https://{.status.ingress[0].host}' 2>/dev/null || true)
        [ -n "$garage_route" ] && GARAGE_ENDPOINT="$garage_route"

        ask "Garage API Endpoint" "${GARAGE_ENDPOINT}" GARAGE_ENDPOINT
        ask "Garage Access Key"   "${GARAGE_ACCESS_KEY}" GARAGE_ACCESS_KEY
        ask "Garage Secret Key"   "${GARAGE_SECRET_KEY}" GARAGE_SECRET_KEY "true"
        ask "OADP (Velero) dedicated S3 Bucket" "${OADP_S3_BUCKET:-velero}" OADP_S3_BUCKET
        GARAGE_BUCKET="${OADP_S3_BUCKET}"
        GARAGE_FOUND=true

        # Detect ODF if also available
        if [ "${ODF_INSTALLED:-false}" = "true" ]; then
            auto_detect_odf
        else
            ODF_S3_ENDPOINT=""
            ODF_S3_BUCKET="${OADP_S3_BUCKET}"
            ODF_S3_REGION="localstorage"
            ODF_S3_ACCESS_KEY=""
            ODF_S3_SECRET_KEY=""
        fi
    else
        GARAGE_ENDPOINT=""
        GARAGE_ACCESS_KEY=""
        GARAGE_SECRET_KEY=""
        print_info "Garage not detected → Using ODF (NooBaa MCG) as OADP backend."
        print_info "To use Garage, deploy it first then re-run setup.sh (refer to 14-oadp.md)"
        if [ "${ODF_INSTALLED:-false}" = "true" ]; then
            auto_detect_odf
            print_info "ODF backend: bucket name will be automatically created by ObjectBucketClaim (OBC)."
            print_info "  → Will be determined in 'backups-xxxx' format when 14-oadp.sh runs."
            OADP_S3_BUCKET="(obc-auto)"
            ODF_S3_BUCKET="${OADP_S3_BUCKET}"
        else
            print_warn "Garage/ODF not detected — please enter custom S3 information manually."
            ask "OADP S3 Endpoint"   "${OADP_S3_ENDPOINT:-}"         OADP_S3_ENDPOINT
            ask "OADP S3 Access Key" "${OADP_S3_ACCESS_KEY:-}"       OADP_S3_ACCESS_KEY
            ask "OADP S3 Secret Key" "${OADP_S3_SECRET_KEY:-}"       OADP_S3_SECRET_KEY "true"
            ask "OADP S3 Region"     "${OADP_S3_REGION:-us-east-1}"  OADP_S3_REGION
            ask "OADP S3 Bucket"     "${OADP_S3_BUCKET:-velero}"     OADP_S3_BUCKET
            ODF_S3_ENDPOINT="${OADP_S3_ENDPOINT}"
            ODF_S3_BUCKET="${OADP_S3_BUCKET}"
            ODF_S3_REGION="${OADP_S3_REGION}"
            ODF_S3_ACCESS_KEY="${OADP_S3_ACCESS_KEY}"
            ODF_S3_SECRET_KEY="${OADP_S3_SECRET_KEY}"
        fi
        GARAGE_BUCKET="${OADP_S3_BUCKET:-velero}"
    fi
else
    print_info "[12] OADP — OADP Operator not installed, skipping."
    GARAGE_ENDPOINT=""
    GARAGE_BUCKET="velero"
    GARAGE_ACCESS_KEY=""
    GARAGE_SECRET_KEY=""
    ODF_S3_ENDPOINT=""
    ODF_S3_BUCKET="velero"
    ODF_S3_REGION="localstorage"
    ODF_S3_ACCESS_KEY=""
    ODF_S3_SECRET_KEY=""
    OADP_S3_BUCKET="${OADP_S3_BUCKET:-velero}"
fi

# =============================================================================
# [19] Logging — LokiStack S3 Bucket configuration (separate from OADP)
# =============================================================================
if [ "${LOKI_INSTALLED:-false}" = "true" ]; then
    print_step_header "[19]" "Logging — LokiStack dedicated S3 configuration"
    echo ""
    print_info "LokiStack must use a different bucket from OADP (Velero)."
    echo ""

    # Detect shared endpoint (Garage or ODF or custom OADP)
    _shared_ep=""
    if [ -n "${GARAGE_ENDPOINT:-}" ]; then
        _shared_ep="${GARAGE_ENDPOINT}"
    elif [ -n "${ODF_S3_ENDPOINT:-}" ]; then
        _shared_ep="${ODF_S3_ENDPOINT}"
    elif [ -n "${OADP_S3_ENDPOINT:-}" ]; then
        _shared_ep="${OADP_S3_ENDPOINT}"
    fi

    if [ -n "$_shared_ep" ]; then
        print_info "Detected S3 Endpoint: ${_shared_ep}"
        read -r -p "  Use the same S3 for Loki as well? (Y/n): " _reuse
        if [[ ! "${_reuse:-}" =~ ^[Nn]$ ]]; then
            LOGGING_S3_ENDPOINT="${_shared_ep}"
            LOGGING_S3_ACCESS_KEY="${GARAGE_ACCESS_KEY:-${ODF_S3_ACCESS_KEY:-${OADP_S3_ACCESS_KEY:-}}}"
            LOGGING_S3_SECRET_KEY="${GARAGE_SECRET_KEY:-${ODF_S3_SECRET_KEY:-${OADP_S3_SECRET_KEY:-}}}"
            LOGGING_S3_REGION="${LOGGING_S3_REGION:-${ODF_S3_REGION:-us-east-1}}"
            print_ok "Sharing Logging S3 endpoint/credentials"
        else
            ask "Logging S3 Endpoint"   "${LOGGING_S3_ENDPOINT:-}"        LOGGING_S3_ENDPOINT
            ask "Logging S3 Access Key" "${LOGGING_S3_ACCESS_KEY:-}"      LOGGING_S3_ACCESS_KEY
            ask "Logging S3 Secret Key" "${LOGGING_S3_SECRET_KEY:-}"      LOGGING_S3_SECRET_KEY "true"
            ask "Logging S3 Region"     "${LOGGING_S3_REGION:-us-east-1}" LOGGING_S3_REGION
        fi
    else
        print_warn "S3 auto-detection failed — please enter dedicated Logging S3 information."
        ask "Logging S3 Endpoint"   "${LOGGING_S3_ENDPOINT:-}"        LOGGING_S3_ENDPOINT
        ask "Logging S3 Access Key" "${LOGGING_S3_ACCESS_KEY:-}"      LOGGING_S3_ACCESS_KEY
        ask "Logging S3 Secret Key" "${LOGGING_S3_SECRET_KEY:-}"      LOGGING_S3_SECRET_KEY "true"
        ask "Logging S3 Region"     "${LOGGING_S3_REGION:-us-east-1}" LOGGING_S3_REGION
    fi

    ask "Loki dedicated S3 Bucket" "${LOGGING_S3_BUCKET:-loki}" LOGGING_S3_BUCKET
else
    LOGGING_S3_BUCKET="${LOGGING_S3_BUCKET:-loki}"
    LOGGING_S3_ENDPOINT="${LOGGING_S3_ENDPOINT:-}"
    LOGGING_S3_ACCESS_KEY="${LOGGING_S3_ACCESS_KEY:-}"
    LOGGING_S3_SECRET_KEY="${LOGGING_S3_SECRET_KEY:-}"
    LOGGING_S3_REGION="${LOGGING_S3_REGION:-us-east-1}"
fi

# =============================================================================
# [09] Alert — VM Stop notification
# =============================================================================
print_step_header "[09]" "Alert — VM Stop notification (PrometheusRule / OpenShift Console)"
echo ""
print_info "Alerts can be viewed in OpenShift Console → Observe → Alerting."
ask "VM name to monitor" "poc-alert-vm" ALERT_VM_NAME
ask "Namespace of VM to monitor" "poc-alert" ALERT_VM_NS

# =============================================================================
# [13·14·16] Node — Node maintenance / SNR / Add Node
# =============================================================================
print_step_header "[13·14·16]" "Node — Node maintenance / SNR / Add Node"

if check_oc 2>/dev/null; then
    DETECTED_WORKERS=$(oc get nodes -l node-role.kubernetes.io/worker \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$DETECTED_WORKERS" ]; then
        print_info "Detected worker nodes: $DETECTED_WORKERS"
        FIRST_WORKER=$(echo $DETECTED_WORKERS | awk '{print $1}')
    else
        FIRST_WORKER="worker-0"
    fi
else
    DETECTED_WORKERS=""
    FIRST_WORKER="worker-0"
fi

ask "Worker node name list (space-separated)" "${DETECTED_WORKERS:-worker-0 worker-1 worker-2}" WORKER_NODES
ask "Single node name for testing" "${FIRST_WORKER:-worker-0}" TEST_NODE

# =============================================================================
# [15] FAR — IPMI/BMC power restart recovery
# =============================================================================
if [ "${FAR_INSTALLED:-false}" = "true" ]; then
    print_step_header "[15]" "FAR — Fence Agents Remediation (IPMI/BMC)"
    ask "IPMI username" "admin" FENCE_AGENT_USER
    ask "IPMI password" "password" FENCE_AGENT_PASS "true"
    echo ""
    print_info "Enter the IPMI/BMC IP address for each worker node."
    FENCE_AGENT_IPS=""
    _ipmi_idx=1
    for _node in ${WORKER_NODES}; do
        ask "  ${_node} IPMI/BMC IP" "192.168.1.${_ipmi_idx}" _node_ipmi_ip
        FENCE_AGENT_IPS="${FENCE_AGENT_IPS:+${FENCE_AGENT_IPS} }${_node_ipmi_ip}"
        _ipmi_idx=$((_ipmi_idx + 1))
    done
    print_ok "IPMI IP list: ${FENCE_AGENT_IPS}"
else
    print_info "[15] FAR — FAR Operator not installed, skipping."
    FENCE_AGENT_IPS=""
    FENCE_AGENT_USER="admin"
    FENCE_AGENT_PASS="password"
fi

# =============================================================================
# Save env.conf
# =============================================================================
print_header "Saving env.conf..."

cat > "$ENV_FILE" << EOF
# =============================================================================
# virt-poc environment configuration file
# Auto-generated by setup.sh: $(date)
# This file is registered in .gitignore and will not be committed to git.
# =============================================================================

# Cluster basic information
CLUSTER_DOMAIN=${CLUSTER_DOMAIN}
CLUSTER_API=${CLUSTER_API}

# Network configuration
NNCP_NAME=${NNCP_NAME}
BRIDGE_INTERFACE=${BRIDGE_INTERFACE}
BRIDGE_NAME=${BRIDGE_NAME}
SECONDARY_IP_PREFIX=${SECONDARY_IP_PREFIX}

# StorageClass
STORAGE_CLASS=${STORAGE_CLASS}

# Golden Image URL (DataVolume HTTP import)
GOLDEN_IMAGE_URL=${GOLDEN_IMAGE_URL}

# Alert configuration (09-alert)
ALERT_VM_NAME=${ALERT_VM_NAME}
ALERT_VM_NS=${ALERT_VM_NS}

# VDDK image
VDDK_IMAGE=${VDDK_IMAGE}

# Console / API access IP restrictions
CONSOLE_ALLOWED_CIDRS=${CONSOLE_ALLOWED_CIDRS}
API_ALLOWED_CIDRS=${API_ALLOWED_CIDRS}

# Fence Agents Remediation
FENCE_AGENT_IPS="${FENCE_AGENT_IPS}"
FENCE_AGENT_USER=${FENCE_AGENT_USER}
FENCE_AGENT_PASS=${FENCE_AGENT_PASS}

# Node information
WORKER_NODES="${WORKER_NODES}"
TEST_NODE=${TEST_NODE}

# Grafana
GRAFANA_ADMIN_PASS=${GRAFANA_ADMIN_PASS}

# Garage (OADP backend)
GARAGE_INSTALLED=${GARAGE_FOUND:-false}
GARAGE_ENDPOINT=${GARAGE_ENDPOINT}
GARAGE_BUCKET=${GARAGE_BUCKET}
GARAGE_ACCESS_KEY=${GARAGE_ACCESS_KEY}
GARAGE_SECRET_KEY=${GARAGE_SECRET_KEY}

# ODF MCG (OADP backend)
ODF_S3_ENDPOINT=${ODF_S3_ENDPOINT}
ODF_S3_BUCKET=${ODF_S3_BUCKET}
ODF_S3_REGION=${ODF_S3_REGION}
ODF_S3_ACCESS_KEY=${ODF_S3_ACCESS_KEY}
ODF_S3_SECRET_KEY=${ODF_S3_SECRET_KEY}

# OADP dedicated S3 (when using custom S3)
OADP_S3_ENDPOINT=${OADP_S3_ENDPOINT:-}
OADP_S3_ACCESS_KEY=${OADP_S3_ACCESS_KEY:-}
OADP_S3_SECRET_KEY=${OADP_S3_SECRET_KEY:-}
OADP_S3_REGION=${OADP_S3_REGION:-us-east-1}
OADP_S3_BUCKET=${OADP_S3_BUCKET:-velero}

# Logging (Loki) dedicated S3
LOGGING_S3_ENDPOINT=${LOGGING_S3_ENDPOINT:-}
LOGGING_S3_ACCESS_KEY=${LOGGING_S3_ACCESS_KEY:-}
LOGGING_S3_SECRET_KEY=${LOGGING_S3_SECRET_KEY:-}
LOGGING_S3_REGION=${LOGGING_S3_REGION:-us-east-1}
LOGGING_S3_BUCKET=${LOGGING_S3_BUCKET:-loki}

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
echo -e "  ${CYAN}[2] Run make.sh${NC}"
echo -e "      ./make.sh"
echo ""
