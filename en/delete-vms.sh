#!/bin/bash
# =============================================================================
# delete-vms.sh
#
# Bulk-delete VMs from a namespace.
#
# Usage: ./delete-vms.sh [NAMESPACE]
#   e.g.) ./delete-vms.sh            <- interactive input
#   e.g.) ./delete-vms.sh poc-bulk     <- delete VMs in poc-bulk namespace
# =============================================================================

set -euo pipefail
trap '[[ "$BASH_COMMAND" =~ ^(oc|kubectl|virtctl) ]] && echo "+ $BASH_COMMAND"' DEBUG
trap 'echo -e "\n\033[0;31m[ERROR]\033[0m Command failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

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
    auto_detect_operators() { :; }
fi

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  POC VM Bulk Delete${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}  virt-poc ${POC_VERSION}${NC}"

    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to OpenShift."
        exit 1
    fi
    print_ok "Cluster connection: $(oc whoami) @ $(oc whoami --show-server)"

    # Namespace input
    local ns="${1:-}"
    if [ -z "$ns" ]; then
        echo -n -e "${YELLOW}  Namespace to delete VMs from${NC} [default: poc-bulk]: "
        read -r ns
        [ -z "$ns" ] && ns="poc-bulk"
    fi

    if ! oc get namespace "$ns" &>/dev/null; then
        print_error "Namespace '${ns}' not found."
        exit 1
    fi

    # List VMs
    print_step "VM list (${ns})"

    local vm_list
    vm_list=$(oc get vm -n "$ns" \
        -o custom-columns=NAME:.metadata.name,STATUS:.status.printableStatus \
        --no-headers 2>/dev/null || true)

    if [ -z "$vm_list" ]; then
        print_info "No VMs found in namespace '${ns}'."
        exit 0
    fi

    echo ""
    echo -e "  ${CYAN}NAME                              STATUS${NC}"
    echo "  ────────────────────────────────────────────"
    echo "$vm_list" | while IFS= read -r line; do
        echo "  $line"
    done

    local vm_count
    vm_count=$(echo "$vm_list" | wc -l | tr -d ' ')
    echo ""
    print_info "Total ${vm_count} VM(s) found."

    # Delete scope
    echo ""
    echo -e "  ${GREEN}1)${NC} Delete all"
    echo -e "  ${GREEN}2)${NC} Delete by name pattern"
    echo -e "  ${GREEN}3)${NC} Cancel"
    echo ""
    echo -n -e "${YELLOW}  Choice${NC} [default: 1]: "
    read -r choice
    [ -z "$choice" ] && choice=1

    local vms_to_delete=""
    case "$choice" in
        1)
            vms_to_delete=$(oc get vm -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
            ;;
        2)
            echo -n -e "${YELLOW}  VM name pattern (e.g. poc-bulk-)${NC}: "
            read -r pattern
            if [ -z "$pattern" ]; then
                print_warn "No pattern entered."
                exit 0
            fi
            vms_to_delete=$(oc get vm -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
                tr ' ' '\n' | grep "$pattern" | tr '\n' ' ' || true)
            if [ -z "$vms_to_delete" ]; then
                print_info "No VMs match pattern '${pattern}'."
                exit 0
            fi
            local match_count
            match_count=$(echo "$vms_to_delete" | wc -w | tr -d ' ')
            print_info "${match_count} VM(s) match pattern '${pattern}'."
            ;;
        *)
            print_warn "Cancelled."
            exit 0
            ;;
    esac

    # Delete namespace too?
    local delete_ns="n"
    echo -n -e "${YELLOW}  Also delete namespace '${ns}'? (y/N)${NC}: "
    read -r delete_ns
    delete_ns="${delete_ns:-n}"

    # Final confirmation
    echo ""
    echo -n -e "${RED}  Are you sure? This cannot be undone. (y/N)${NC}: "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warn "Cancelled."
        exit 0
    fi

    # Delete VMs
    print_step "Deleting VMs"

    local deleted=0
    local failed=0

    for vm in $vms_to_delete; do
        print_info "Deleting VM ${vm}..."
        virtctl stop "$vm" -n "$ns" 2>/dev/null || true
        if oc delete vm "$vm" -n "$ns" --wait=false 2>/dev/null; then
            print_ok "VM ${vm} deleted"
            deleted=$((deleted + 1))
        else
            print_error "Failed to delete VM ${vm}"
            failed=$((failed + 1))
        fi
    done

    # Delete namespace
    if [[ "$delete_ns" =~ ^[Yy]$ ]]; then
        print_info "Deleting namespace '${ns}'..."
        oc delete namespace "$ns" --wait=false 2>/dev/null || true
        print_ok "Namespace '${ns}' deletion requested"
    fi

    # Summary
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Deletion complete${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Deleted : ${GREEN}${deleted}${NC}"
    [ "$failed" -gt 0 ] && echo -e "  Failed  : ${RED}${failed}${NC}"
    echo ""
}

main "${1:-}"
