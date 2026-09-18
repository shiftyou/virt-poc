#!/bin/bash
# =============================================================================
# migrate-vms.sh
#
# Live-migrate VMs in a namespace.
#
# Usage: ./migrate-vms.sh [NAMESPACE]
#   e.g.) ./migrate-vms.sh            <- interactive input
#   e.g.) ./migrate-vms.sh poc-bulk     <- migrate VMs in poc-bulk namespace
# =============================================================================

set -euo pipefail
trap '[[ "$BASH_COMMAND" =~ ^(oc|kubectl|virtctl) ]] && echo "+ $BASH_COMMAND"' DEBUG
trap 'echo -e "\n\033[0;31m[오류]\033[0m Command failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

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
    echo -e "${CYAN}  POC VM Live Migration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}  virt-poc ${POC_VERSION}${NC}"

    auto_detect_operators

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator is not installed."
        exit 77
    fi

    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to OpenShift."
        exit 1
    fi
    print_ok "Cluster connection: $(oc whoami) @ $(oc whoami --show-server)"

    if ! command -v virtctl &>/dev/null; then
        print_error "virtctl not found."
        exit 1
    fi

    # Namespace input
    local ns="${1:-}"
    if [ -z "$ns" ]; then
        echo -n -e "${YELLOW}  Namespace with VMs${NC} [default: poc-bulk]: "
        read -r ns
        [ -z "$ns" ] && ns="poc-bulk"
    fi

    if ! oc get namespace "$ns" &>/dev/null; then
        print_error "Namespace '${ns}' not found."
        exit 1
    fi

    # List running VMIs
    print_step "Running VMs (${ns})"

    local vmi_list
    vmi_list=$(oc get vmi -n "$ns" \
        -o custom-columns=NAME:.metadata.name,NODE:.status.nodeName,PHASE:.status.phase \
        --no-headers 2>/dev/null || true)

    if [ -z "$vmi_list" ]; then
        print_info "No running VMs in namespace '${ns}'."
        print_info "Start a VM first: virtctl start <vm-name> -n ${ns}"
        exit 0
    fi

    echo ""
    echo -e "  ${CYAN}NAME                              NODE                              PHASE${NC}"
    echo "  ────────────────────────────────────────────────────────────────────────────"
    echo "$vmi_list" | while IFS= read -r line; do
        echo "  $line"
    done
    echo ""

    local vmi_count
    vmi_count=$(echo "$vmi_list" | wc -l | tr -d ' ')
    print_info "Total ${vmi_count} running VM(s)."

    # Migration scope
    echo ""
    echo -e "  ${GREEN}1)${NC} Migrate all"
    echo -e "  ${GREEN}2)${NC} Migrate by name pattern"
    echo -e "  ${GREEN}3)${NC} Migrate single VM"
    echo -e "  ${GREEN}4)${NC} Cancel"
    echo ""
    echo -n -e "${YELLOW}  Choice${NC} [default: 1]: "
    read -r choice
    [ -z "$choice" ] && choice=1

    local vmis_to_migrate=""
    case "$choice" in
        1)
            vmis_to_migrate=$(oc get vmi -n "$ns" -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null || true)
            ;;
        2)
            echo -n -e "${YELLOW}  VM name pattern (e.g. poc-bulk-)${NC}: "
            read -r pattern
            if [ -z "$pattern" ]; then
                print_warn "No pattern entered."
                exit 0
            fi
            vmis_to_migrate=$(oc get vmi -n "$ns" -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | \
                tr ' ' '\n' | grep "$pattern" | tr '\n' ' ' || true)
            if [ -z "$vmis_to_migrate" ]; then
                print_info "No running VMs match pattern '${pattern}'."
                exit 0
            fi
            ;;
        3)
            echo -n -e "${YELLOW}  VM name to migrate${NC}: "
            read -r single_vm
            if [ -z "$single_vm" ]; then
                print_warn "No VM name entered."
                exit 0
            fi
            if ! oc get vmi "$single_vm" -n "$ns" &>/dev/null; then
                print_error "VMI '${single_vm}' not found."
                exit 1
            fi
            vmis_to_migrate="$single_vm"
            ;;
        *)
            print_warn "Cancelled."
            exit 0
            ;;
    esac

    if [ -z "$vmis_to_migrate" ]; then
        print_info "No running VMs to migrate."
        exit 0
    fi

    local migrate_count
    migrate_count=$(echo "$vmis_to_migrate" | wc -w | tr -d ' ')

    echo ""
    echo -n -e "${YELLOW}  Migrate ${migrate_count} VM(s)? (Y/n)${NC}: "
    read -r confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        print_warn "Cancelled."
        exit 0
    fi

    # Execute migrations
    print_step "Live migration"

    local migrated=0
    local failed=0
    local idx=0

    for vmi in $vmis_to_migrate; do
        idx=$((idx + 1))
        local current_node
        current_node=$(oc get vmi "$vmi" -n "$ns" \
            -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "unknown")
        print_info "[${idx}/${migrate_count}] Migrating VM ${vmi}... (current node: ${current_node})"

        if virtctl migrate "$vmi" -n "$ns" 2>/dev/null; then
            print_ok "VM ${vmi} migration requested"
            migrated=$((migrated + 1))
        else
            print_error "VM ${vmi} migration request failed"
            failed=$((failed + 1))
        fi
    done

    # Wait for completion
    print_step "Migration status"

    print_info "Waiting for migrations to complete... (max 5 minutes)"
    local timeout=300
    local elapsed=0
    local interval=10

    while [ "$elapsed" -lt "$timeout" ]; do
        local pending
        pending=$(oc get vmim -n "$ns" \
            -o jsonpath='{.items[?(@.status.phase!="Succeeded")].metadata.name}' 2>/dev/null | \
            wc -w | tr -d ' ' || echo "0")

        if [ "$pending" -eq 0 ] 2>/dev/null; then
            break
        fi

        print_info "Migrations in progress: ${pending} (${elapsed}s elapsed)"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    # Final results
    echo ""
    echo -e "${CYAN}━━━ Migration results ━━━${NC}"
    echo ""
    oc get vmim -n "$ns" \
        -o custom-columns=NAME:.metadata.name,VMI:.spec.vmiName,PHASE:.status.phase \
        --no-headers 2>/dev/null | while IFS= read -r line; do
        echo "  $line"
    done

    echo ""
    echo -e "${CYAN}━━━ VM placement ━━━${NC}"
    echo ""
    oc get vmi -n "$ns" \
        -o custom-columns=NAME:.metadata.name,NODE:.status.nodeName,PHASE:.status.phase \
        --no-headers 2>/dev/null | while IFS= read -r line; do
        echo "  $line"
    done

    # Summary
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Migration complete${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Requested : ${GREEN}${migrated}${NC}"
    [ "$failed" -gt 0 ] && echo -e "  Failed    : ${RED}${failed}${NC}"
    echo ""
    echo -e "  Check migration history:"
    echo -e "  ${CYAN}oc get vmim -n ${ns}${NC}"
    echo ""
    echo -e "  Check VM placement:"
    echo -e "  ${CYAN}oc get vmi -n ${ns} -o wide${NC}"
    echo ""
}

main "${1:-}"
