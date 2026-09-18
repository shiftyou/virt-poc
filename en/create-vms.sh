#!/bin/bash
# =============================================================================
# create-vms.sh
#
# Bulk-create VMs from the poc template with a user-specified count.
#
# Usage: ./create-vms.sh [VM_COUNT] [NAMESPACE]
#   e.g.) ./create-vms.sh            <- interactive input
#   e.g.) ./create-vms.sh 5          <- create 5 VMs in poc-vm namespace
#   e.g.) ./create-vms.sh 3 my-ns    <- create 3 VMs in my-ns namespace
# =============================================================================

set -euo pipefail
trap '[[ "$BASH_COMMAND" =~ ^(oc|kubectl|virtctl) ]] && echo "+ $BASH_COMMAND"' DEBUG
trap 'echo -e "\n\033[0;31m[ERROR]\033[0m Command failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-load env.conf (when running standalone)
ENV_FILE="${SCRIPT_DIR}/env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

TEMPLATE_NAME="poc"
TEMPLATE_NS="openshift"
VM_PREFIX="poc-vm"

if [ -f "${SCRIPT_DIR}/utils/common.sh" ]; then
    source "${SCRIPT_DIR}/utils/common.sh"
else
    RED='\033[0;31m'; GREEN='\033[0;32m'; DIM='\033[2m'
    POC_VERSION=$(cat "${SCRIPT_DIR}/../VERSION" 2>/dev/null || echo "dev")
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
    auto_detect_operators() { :; }
fi

# =============================================================================
# Preflight checks
# =============================================================================
preflight() {
    print_step "Preflight checks"
    auto_detect_operators

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator is not installed."
        print_warn "  Install guide: operators/kubevirt-hyperconverged-operator.md"
        exit 77
    fi

    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to OpenShift."
        exit 1
    fi
    print_ok "Cluster connection: $(oc whoami) @ $(oc whoami --show-server)"

    if ! oc get template "$TEMPLATE_NAME" -n "$TEMPLATE_NS" &>/dev/null; then
        print_error "poc Template not found. Run 01-template first."
        exit 1
    fi
    print_ok "Template '${TEMPLATE_NAME}' found (namespace: ${TEMPLATE_NS})"
}

# =============================================================================
# Get user input
# =============================================================================
get_input() {
    local vm_count_arg="${1:-}"
    local vm_ns_arg="${2:-}"

    # VM count
    if [ -n "$vm_count_arg" ]; then
        VM_COUNT="$vm_count_arg"
    else
        echo -n -e "${YELLOW}  Enter number of VMs to create${NC} [default: 3]: "
        read -r VM_COUNT
        [ -z "$VM_COUNT" ] && VM_COUNT=3
    fi

    if ! [[ "$VM_COUNT" =~ ^[0-9]+$ ]] || [ "$VM_COUNT" -lt 1 ] || [ "$VM_COUNT" -gt 100 ]; then
        print_error "VM count must be a number between 1 and 100: ${VM_COUNT}"
        exit 1
    fi

    # Namespace
    if [ -n "$vm_ns_arg" ]; then
        VM_NS="$vm_ns_arg"
    else
        echo -n -e "${YELLOW}  Namespace for VMs${NC} [default: poc-vm]: "
        read -r VM_NS
        [ -z "$VM_NS" ] && VM_NS="poc-vm"
    fi

    # VM name prefix
    echo -n -e "${YELLOW}  VM name prefix${NC} [default: ${VM_PREFIX}]: "
    read -r input_prefix
    [ -n "$input_prefix" ] && VM_PREFIX="$input_prefix"

    # Start VMs after creation
    echo -n -e "${YELLOW}  Start VMs after creation? (y/N)${NC}: "
    read -r START_VMS
    START_VMS="${START_VMS:-n}"

    echo ""
    print_info "Configuration summary:"
    print_info "  VM count     : ${VM_COUNT}"
    print_info "  Namespace    : ${VM_NS}"
    print_info "  Name prefix  : ${VM_PREFIX}"
    print_info "  Start VMs    : ${START_VMS}"
    echo ""
    echo -n -e "${YELLOW}  Proceed with the above settings? (Y/n)${NC}: "
    read -r confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        print_warn "Cancelled."
        exit 0
    fi
}

# =============================================================================
# Ensure namespace
# =============================================================================
ensure_namespace() {
    print_step "1/2  Ensure namespace (${VM_NS})"

    if oc get namespace "${VM_NS}" &>/dev/null; then
        print_ok "Namespace ${VM_NS} already exists"
    else
        print_info "Creating namespace ${VM_NS}..."
        oc new-project "${VM_NS}" > /dev/null
        print_ok "Namespace ${VM_NS} created"
    fi
}

# =============================================================================
# Bulk create VMs
# =============================================================================
create_vms() {
    print_step "2/2  Creating ${VM_COUNT} VMs (${VM_PREFIX}-1 ~ ${VM_PREFIX}-${VM_COUNT})"

    local created=0
    local skipped=0
    local failed=0

    for i in $(seq 1 "$VM_COUNT"); do
        local vm_name="${VM_PREFIX}-${i}"

        if oc get vm "$vm_name" -n "$VM_NS" &>/dev/null; then
            print_warn "VM ${vm_name} already exists — skipping"
            skipped=$((skipped + 1))
            continue
        fi

        print_info "[${i}/${VM_COUNT}] Creating VM ${vm_name}..."

        if oc process -n "$TEMPLATE_NS" "$TEMPLATE_NAME" -p NAME="$vm_name" | \
            oc apply -n "$VM_NS" -f - &>/dev/null; then

            # spec.running → spec.runStrategy migration
            local running
            running=$(oc get vm "$vm_name" -n "$VM_NS" \
                -o jsonpath='{.spec.running}' 2>/dev/null || true)
            if [ -n "$running" ]; then
                oc patch vm "$vm_name" -n "$VM_NS" --type=json -p "[
                  {\"op\":\"remove\",\"path\":\"/spec/running\"},
                  {\"op\":\"add\",\"path\":\"/spec/runStrategy\",\"value\":\"Halted\"}
                ]" &>/dev/null || true
            fi

            if [[ "$START_VMS" =~ ^[Yy]$ ]]; then
                virtctl start "$vm_name" -n "$VM_NS" 2>/dev/null || true
                print_ok "VM ${vm_name} created and started"
            else
                print_ok "VM ${vm_name} created (Halted)"
            fi
            created=$((created + 1))
        else
            print_error "Failed to create VM ${vm_name}"
            failed=$((failed + 1))
        fi
    done

    # Summary
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  VM creation complete${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Created : ${GREEN}${created}${NC}"
    [ "$skipped" -gt 0 ] && echo -e "  Skipped : ${YELLOW}${skipped}${NC} (already exist)"
    [ "$failed" -gt 0 ]  && echo -e "  Failed  : ${RED}${failed}${NC}"
    echo ""
    echo -e "  List VMs:"
    echo -e "  ${CYAN}oc get vm -n ${VM_NS}${NC}"
    echo ""
    if [[ "$START_VMS" =~ ^[Yy]$ ]]; then
        echo -e "  Check VMI status:"
        echo -e "  ${CYAN}oc get vmi -n ${VM_NS}${NC}"
        echo ""
    fi
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Bulk delete VMs"

    local ns="${2:-poc-vm}"
    echo -n -e "${YELLOW}  Delete all VMs in namespace '${ns}'? (y/N)${NC}: "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warn "Cancelled."
        exit 0
    fi

    local vms
    vms=$(oc get vm -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -z "$vms" ]; then
        print_info "No VMs found in namespace '${ns}'."
        exit 0
    fi

    for vm in $vms; do
        virtctl stop "$vm" -n "$ns" 2>/dev/null || true
        oc delete vm "$vm" -n "$ns" --ignore-not-found 2>/dev/null || true
        print_ok "VM ${vm} deleted"
    done

    print_ok "Cleanup complete"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  POC VM Bulk Creator${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}  virt-poc ${POC_VERSION}${NC}"

    preflight
    get_input "${1:-}" "${2:-}"
    ensure_namespace
    create_vms
}

if [ "${1:-}" = "--cleanup" ]; then
    cleanup "$@"
    exit 0
fi
main "${1:-}" "${2:-}"
