#!/bin/bash
# =============================================================================
# 19-hyperconverged.sh
#
# HyperConverged 설정 랩
#   1. 현재 HyperConverged 설정 표시
#   2. CPU Overcommit 비율 확인 및 가이드 제공
#
# 사용법: ./19-hyperconverged.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

HCO_NS="openshift-cnv"
HCO_NAME="kubevirt-hyperconverged"

source "${SCRIPT_DIR}/../utils/common.sh"

preflight() {
    print_step "사전 점검"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 접근: $(oc whoami) @ $(oc whoami --show-server)"

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator가 설치되어 있지 않습니다 → 건너뜀."
        exit 77
    fi

    if ! oc get hyperconverged "$HCO_NAME" -n "$HCO_NS" &>/dev/null; then
        print_error "HyperConverged CR '$HCO_NAME'을(를) 찾을 수 없습니다."
        exit 1
    fi
    print_ok "HyperConverged CR 확인됨"
}

step_show_current() {
    print_step "1/2  현재 HyperConverged 설정"

    echo ""
    echo -e "  ${CYAN}── CPU Overcommit ──${NC}"
    local cpu_ratio
    cpu_ratio=$(oc get hyperconverged "$HCO_NAME" -n "$HCO_NS" \
        -o jsonpath='{.spec.resourceRequirements.vmiCPUAllocationRatio}' 2>/dev/null || echo "10(기본값)")
    echo -e "  vmiCPUAllocationRatio: ${YELLOW}${cpu_ratio}${NC}  (vCPU:pCPU = ${cpu_ratio}:1)"

    echo ""
    echo -e "  ${CYAN}── Live Migration ──${NC}"
    oc get hyperconverged "$HCO_NAME" -n "$HCO_NS" \
        -o jsonpath='{range .spec.liveMigrationConfig}{@}{"\n"}{end}' 2>/dev/null || \
        echo "  (기본값 사용 중)"

    echo ""
    echo -e "  ${CYAN}── HyperConverged 상태 ──${NC}"
    oc get hyperconverged "$HCO_NAME" -n "$HCO_NS" \
        --no-headers \
        -o custom-columns="NAME:.metadata.name,AGE:.metadata.creationTimestamp,PHASE:.status.phase"
    echo ""
}

step_guide() {
    print_step "2/2  설정 변경 가이드"

    echo ""
    echo -e "  ${CYAN}CPU Overcommit 변경 예시:${NC}"
    echo -e "    # 4:1로 변경"
    echo -e "    ${YELLOW}oc patch hyperconverged ${HCO_NAME} -n ${HCO_NS} \\${NC}"
    echo -e "    ${YELLOW}  --type=merge \\${NC}"
    echo -e "    ${YELLOW}  -p '{\"spec\":{\"resourceRequirements\":{\"vmiCPUAllocationRatio\":4}}}'${NC}"
    echo ""
    echo -e "  ${CYAN}Live Migration 동시 실행 수 변경:${NC}"
    echo -e "    ${YELLOW}oc patch hyperconverged ${HCO_NAME} -n ${HCO_NS} \\${NC}"
    echo -e "    ${YELLOW}  --type=merge \\${NC}"
    echo -e "    ${YELLOW}  -p '{\"spec\":{\"liveMigrationConfig\":{\"parallelMigrationsPerCluster\":5}}}'${NC}"
    echo ""
    echo -e "  상세 내용: ${CYAN}19-hyperconverged/19-hyperconverged.md${NC}"
    echo ""
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  HyperConverged 설정 랩${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_show_current
    step_guide
}

main
