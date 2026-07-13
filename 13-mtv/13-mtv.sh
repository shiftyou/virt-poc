#!/bin/bash
# =============================================================================
# 13-mtv.sh
#
# Migration Toolkit for Virtualization (MTV) lab environment setup
#   1. Create poc-mtv namespace
#   2. Display MTV pre-migration checklist
#
# Usage: ./13-mtv.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-mtv"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

print_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERR ]${NC} $1"; }
print_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

preflight() {
    print_step "Pre-flight check"

    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to OpenShift."
        exit 1
    fi
    print_ok "Cluster connection: $(oc whoami) @ $(oc whoami --show-server)"

    if [ "${MTV_INSTALLED:-false}" != "true" ]; then
        print_warn "Migration Toolkit for Virtualization Operator not installed → skipping."
        print_warn "  Installation guide: operators/mtv-operator.md"
        exit 77
    fi
    print_ok "MTV Operator confirmed"
}

step_namespace() {
    print_step "1/2  Create namespace (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "Namespace $NS already exists — skipping"
    else
        oc new-project "$NS" > /dev/null
        print_ok "Namespace $NS created successfully"
    fi
}

step_checklist() {
    print_step "2/2  Pre-migration checklist"

    echo ""
    echo -e "${YELLOW}  ┌─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}  │  Required checks before VMware → OpenShift migration    │${NC}"
    echo -e "${YELLOW}  └─────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${CYAN}[1] Disable Hot-plug (VMware)${NC}"
    echo -e "      VM Edit Settings → Uncheck CPU/Memory Hot Add"
    echo -e "      vcpu.hotadd = FALSE / mem.hotadd = FALSE"
    echo ""
    echo -e "  ${CYAN}[2] Enable Shared Disk (when using Warm Migration)${NC}"
    echo -e "      VM disk → Advanced → Sharing → Multi-writer"
    echo ""
    echo -e "  ${CYAN}[3] Windows VM — Disable Fast Startup + Normal Shutdown${NC}"
    echo -e "      Control Panel → Power Options → Uncheck Turn on fast startup"
    echo -e "      Must perform full Shutdown before migration"
    echo ""
    echo -e "  ${CYAN}[4] Warm Migration — Enable vSphere CBT${NC}"
    echo -e "      .vmx: ctkEnabled = TRUE / scsiN:M.ctkEnabled = TRUE"
    echo -e "      Must create/delete snapshot once after enabling"
    echo ""
    echo -e "  For details: ${CYAN}13-mtv/13-mtv.md${NC}"
    echo ""
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! MTV lab environment is ready.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Provider registration:"
    echo -e "    ${CYAN}oc get provider -n openshift-mtv${NC}"
    echo ""
    echo -e "  Check migration progress:"
    echo -e "    ${CYAN}oc get migration -n openshift-mtv${NC}"
    echo ""
    echo -e "  Check migrated VMs:"
    echo -e "    ${CYAN}oc get vm -n ${NS}${NC}"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Delete 13-mtv resources"
    oc delete project poc-mtv --ignore-not-found 2>/dev/null || true
    print_ok "13-mtv resources deleted successfully"
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  MTV lab environment setup${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_checklist
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
