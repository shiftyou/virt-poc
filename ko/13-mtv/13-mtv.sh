#!/bin/bash
# =============================================================================
# 13-mtv.sh
#
# Migration Toolkit for Virtualization (MTV) 실습 환경 구성
#   1. poc-mtv namespace 생성
#   2. MTV 마이그레이션 전 체크리스트 표시
#
# 사용법: ./13-mtv.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-mtv"

source "${SCRIPT_DIR}/../utils/common.sh"

preflight() {
    print_step "사전 점검"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 연결: $(oc whoami) @ $(oc whoami --show-server)"

    if [ "${MTV_INSTALLED:-false}" != "true" ]; then
        print_warn "Migration Toolkit for Virtualization Operator가 설치되어 있지 않습니다 → 건너뜀."
        print_warn "  설치 가이드: operators/mtv-operator.md"
        exit 77
    fi
    print_ok "MTV Operator 확인됨"
}

step_namespace() {
    print_step "1/2  namespace 생성 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "Namespace $NS 이미 존재합니다 — 건너뜀"
    else
        oc new-project "$NS" > /dev/null
        print_ok "Namespace $NS 성공적으로 생성됨"
    fi
}

step_checklist() {
    print_step "2/2  마이그레이션 전 체크리스트"

    echo ""
    echo -e "${YELLOW}  ┌─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${YELLOW}  │  VMware → OpenShift 마이그레이션 전 필수 확인 사항      │${NC}"
    echo -e "${YELLOW}  └─────────────────────────────────────────────────────────┘${NC}"
    echo ""
    echo -e "  ${CYAN}[1] Hot-plug 비활성화 (VMware)${NC}"
    echo -e "      VM 설정 편집 → CPU/Memory Hot Add 체크 해제"
    echo -e "      vcpu.hotadd = FALSE / mem.hotadd = FALSE"
    echo ""
    echo -e "  ${CYAN}[2] 공유 디스크 활성화 (Warm Migration 사용 시)${NC}"
    echo -e "      VM 디스크 → Advanced → Sharing → Multi-writer"
    echo ""
    echo -e "  ${CYAN}[3] Windows VM — 빠른 시작 비활성화 + 정상 종료${NC}"
    echo -e "      제어판 → 전원 옵션 → 빠른 시작 켜기 체크 해제"
    echo -e "      마이그레이션 전 반드시 완전 종료 수행"
    echo ""
    echo -e "  ${CYAN}[4] Warm Migration — vSphere CBT 활성화${NC}"
    echo -e "      .vmx: ctkEnabled = TRUE / scsiN:M.ctkEnabled = TRUE"
    echo -e "      활성화 후 스냅샷을 한 번 생성/삭제해야 함"
    echo ""
    echo -e "  자세한 내용: ${CYAN}13-mtv/13-mtv.md${NC} 참조"
    echo ""
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! MTV 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Provider 등록 확인:"
    echo -e "    ${CYAN}oc get provider -n openshift-mtv${NC}"
    echo ""
    echo -e "  마이그레이션 진행 상황 확인:"
    echo -e "    ${CYAN}oc get migration -n openshift-mtv${NC}"
    echo ""
    echo -e "  마이그레이션된 VM 확인:"
    echo -e "    ${CYAN}oc get vm -n ${NS}${NC}"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 13-mtv 리소스 삭제"
    oc delete project poc-mtv --ignore-not-found 2>/dev/null || true
    print_ok "13-mtv 리소스 성공적으로 삭제됨"
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  MTV 실습 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_checklist
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
