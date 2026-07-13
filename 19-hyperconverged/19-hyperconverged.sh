#!/bin/bash
# =============================================================================
# 18-hyperconverged.sh
#
# HyperConverged Configuration Lab
#   1. Display current HyperConverged configuration
#   2. Check CPU Overcommit ratio and provide guidance
#
# Usage: ./18-hyperconverged.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

HCO_NS="openshift-cnv"
HCO_NAME="kubevirt-hyperconverged"

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
    print_step "Pre-flight Check"

    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to OpenShift."
        exit 1
    fi
    print_ok "Cluster access: $(oc whoami) @ $(oc whoami --show-server)"

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator not installed → skipping."
        exit 77
    fi

    if ! oc get hyperconverged "$HCO_NAME" -n "$HCO_NS" &>/dev/null; then
        print_error "HyperConverged CR '$HCO_NAME' not found."
        exit 1
    fi
    print_ok "HyperConverged CR confirmed"
}

step_show_current() {
    print_step "1/2  Current HyperConverged Configuration"

    echo ""
    echo -e "  ${CYAN}── CPU Overcommit ──${NC}"
    local cpu_ratio
    cpu_ratio=$(oc get hyperconverged "$HCO_NAME" -n "$HCO_NS" \
        -o jsonpath='{.spec.resourceRequirements.vmiCPUAllocationRatio}' 2>/dev/null || echo "10(default)")
    echo -e "  vmiCPUAllocationRatio: ${YELLOW}${cpu_ratio}${NC}  (vCPU:pCPU = ${cpu_ratio}:1)"

    echo ""
    echo -e "  ${CYAN}── Live Migration ──${NC}"
    oc get hyperconverged "$HCO_NAME" -n "$HCO_NS" \
        -o jsonpath='{range .spec.liveMigrationConfig}{@}{"\n"}{end}' 2>/dev/null || \
        echo "  (using defaults)"

    echo ""
    echo -e "  ${CYAN}── HyperConverged Status ──${NC}"
    oc get hyperconverged "$HCO_NAME" -n "$HCO_NS" \
        --no-headers \
        -o custom-columns="NAME:.metadata.name,AGE:.metadata.creationTimestamp,PHASE:.status.phase"
    echo ""
}

step_guide() {
    print_step "2/2  Configuration Change Guide"

    echo ""
    echo -e "  ${CYAN}CPU Overcommit change example:${NC}"
    echo -e "    # Change to 4:1"
    echo -e "    ${YELLOW}oc patch hyperconverged ${HCO_NAME} -n ${HCO_NS} \\${NC}"
    echo -e "    ${YELLOW}  --type=merge \\${NC}"
    echo -e "    ${YELLOW}  -p '{\"spec\":{\"resourceRequirements\":{\"vmiCPUAllocationRatio\":4}}}'${NC}"
    echo ""
    echo -e "  ${CYAN}Change Live Migration concurrent count:${NC}"
    echo -e "    ${YELLOW}oc patch hyperconverged ${HCO_NAME} -n ${HCO_NS} \\${NC}"
    echo -e "    ${YELLOW}  --type=merge \\${NC}"
    echo -e "    ${YELLOW}  -p '{\"spec\":{\"liveMigrationConfig\":{\"parallelMigrationsPerCluster\":5}}}'${NC}"
    echo ""
    echo -e "  For more details, refer to: ${CYAN}15-hyperconverged.md${NC}"
    echo ""
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  HyperConverged Configuration Lab${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_show_current
    step_guide
}

main
