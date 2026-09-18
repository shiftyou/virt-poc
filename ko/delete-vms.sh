#!/bin/bash
# =============================================================================
# delete-vms.sh
#
# 네임스페이스의 VM을 일괄 삭제합니다.
#
# 사용법: ./delete-vms.sh [네임스페이스]
#   예시) ./delete-vms.sh            ← 대화형 입력
#   예시) ./delete-vms.sh poc-bulk     ← poc-bulk 네임스페이스의 VM 삭제
# =============================================================================

set -euo pipefail
trap '[[ "$BASH_COMMAND" =~ ^(oc|kubectl|virtctl) ]] && echo "+ $BASH_COMMAND"' DEBUG
trap 'echo -e "\n\033[0;31m[오류]\033[0m ${LINENO}번째 줄에서 명령 실패: ${BASH_COMMAND}" >&2' ERR

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
    print_info()  { echo -e "${BLUE}[정보]${NC} $1"; }
    print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
    print_warn()  { echo -e "${YELLOW}[경고]${NC} $1"; }
    print_error() { echo -e "${RED}[오류]${NC} $1"; }
    print_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }
    auto_detect_operators() { :; }
fi

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  POC VM 일괄 삭제${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}  virt-poc ${POC_VERSION}${NC}"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 연결: $(oc whoami) @ $(oc whoami --show-server)"

    # 네임스페이스 입력
    local ns="${1:-}"
    if [ -z "$ns" ]; then
        echo -n -e "${YELLOW}  VM을 삭제할 네임스페이스${NC} [기본값: poc-bulk]: "
        read -r ns
        [ -z "$ns" ] && ns="poc-bulk"
    fi

    if ! oc get namespace "$ns" &>/dev/null; then
        print_error "네임스페이스 '${ns}'를 찾을 수 없습니다."
        exit 1
    fi

    # VM 목록 조회
    print_step "VM 목록 조회 (${ns})"

    local vm_list
    vm_list=$(oc get vm -n "$ns" \
        -o custom-columns=NAME:.metadata.name,STATUS:.status.printableStatus \
        --no-headers 2>/dev/null || true)

    if [ -z "$vm_list" ]; then
        print_info "네임스페이스 '${ns}'에 VM이 없습니다."
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
    print_info "총 ${vm_count}개의 VM이 있습니다."

    # 삭제 범위 선택
    echo ""
    echo -e "  ${GREEN}1)${NC} 전체 삭제"
    echo -e "  ${GREEN}2)${NC} 선택 삭제 (이름 패턴)"
    echo -e "  ${GREEN}3)${NC} 취소"
    echo ""
    echo -n -e "${YELLOW}  선택${NC} [기본값: 1]: "
    read -r choice
    [ -z "$choice" ] && choice=1

    local vms_to_delete=""
    case "$choice" in
        1)
            vms_to_delete=$(oc get vm -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
            ;;
        2)
            echo -n -e "${YELLOW}  삭제할 VM 이름 패턴 (예: poc-bulk-)${NC}: "
            read -r pattern
            if [ -z "$pattern" ]; then
                print_warn "패턴이 입력되지 않았습니다."
                exit 0
            fi
            vms_to_delete=$(oc get vm -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
                tr ' ' '\n' | grep "$pattern" | tr '\n' ' ' || true)
            if [ -z "$vms_to_delete" ]; then
                print_info "패턴 '${pattern}'에 일치하는 VM이 없습니다."
                exit 0
            fi
            local match_count
            match_count=$(echo "$vms_to_delete" | wc -w | tr -d ' ')
            print_info "패턴 '${pattern}'에 ${match_count}개의 VM이 일치합니다."
            ;;
        *)
            print_warn "취소됨."
            exit 0
            ;;
    esac

    # 네임스페이스 삭제 여부
    local delete_ns="n"
    echo -n -e "${YELLOW}  네임스페이스 '${ns}'도 함께 삭제하시겠습니까? (y/N)${NC}: "
    read -r delete_ns
    delete_ns="${delete_ns:-n}"

    # 최종 확인
    echo ""
    echo -n -e "${RED}  정말 삭제하시겠습니까? 이 작업은 되돌릴 수 없습니다. (y/N)${NC}: "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warn "취소됨."
        exit 0
    fi

    # VM 삭제 실행
    print_step "VM 삭제 중"

    local deleted=0
    local failed=0

    for vm in $vms_to_delete; do
        print_info "VM ${vm} 삭제 중..."
        virtctl stop "$vm" -n "$ns" 2>/dev/null || true
        if oc delete vm "$vm" -n "$ns" --wait=false 2>/dev/null; then
            print_ok "VM ${vm} 삭제됨"
            deleted=$((deleted + 1))
        else
            print_error "VM ${vm} 삭제 실패"
            failed=$((failed + 1))
        fi
    done

    # 네임스페이스 삭제
    if [[ "$delete_ns" =~ ^[Yy]$ ]]; then
        print_info "네임스페이스 '${ns}' 삭제 중..."
        oc delete namespace "$ns" --wait=false 2>/dev/null || true
        print_ok "네임스페이스 '${ns}' 삭제 요청됨"
    fi

    # 결과 요약
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  삭제 완료${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  삭제됨 : ${GREEN}${deleted}${NC}개"
    [ "$failed" -gt 0 ] && echo -e "  실패   : ${RED}${failed}${NC}개"
    echo ""
}

main "${1:-}"
