#!/bin/bash
# =============================================================================
# migrate-vms.sh
#
# 네임스페이스의 VM을 라이브 마이그레이션합니다.
#
# 사용법: ./migrate-vms.sh [네임스페이스]
#   예시) ./migrate-vms.sh            ← 대화형 입력
#   예시) ./migrate-vms.sh poc-bulk     ← poc-bulk 네임스페이스의 VM 마이그레이션
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
    echo -e "${CYAN}  POC VM 라이브 마이그레이션${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}  virt-poc ${POC_VERSION}${NC}"

    auto_detect_operators

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator가 설치되지 않았습니다."
        exit 77
    fi

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 연결: $(oc whoami) @ $(oc whoami --show-server)"

    if ! command -v virtctl &>/dev/null; then
        print_error "virtctl을 찾을 수 없습니다."
        exit 1
    fi

    # 네임스페이스 입력
    local ns="${1:-}"
    if [ -z "$ns" ]; then
        echo -n -e "${YELLOW}  VM이 있는 네임스페이스${NC} [기본값: poc-bulk]: "
        read -r ns
        [ -z "$ns" ] && ns="poc-bulk"
    fi

    if ! oc get namespace "$ns" &>/dev/null; then
        print_error "네임스페이스 '${ns}'를 찾을 수 없습니다."
        exit 1
    fi

    # 실행 중인 VMI 목록 조회
    print_step "실행 중인 VM 목록 (${ns})"

    local vmi_list
    vmi_list=$(oc get vmi -n "$ns" \
        -o custom-columns=NAME:.metadata.name,NODE:.status.nodeName,PHASE:.status.phase \
        --no-headers 2>/dev/null || true)

    if [ -z "$vmi_list" ]; then
        print_info "네임스페이스 '${ns}'에 실행 중인 VM이 없습니다."
        print_info "VM을 먼저 시작하세요: virtctl start <vm-name> -n ${ns}"
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
    print_info "총 ${vmi_count}개의 실행 중인 VM이 있습니다."

    # 마이그레이션 범위 선택
    echo ""
    echo -e "  ${GREEN}1)${NC} 전체 마이그레이션"
    echo -e "  ${GREEN}2)${NC} 선택 마이그레이션 (이름 패턴)"
    echo -e "  ${GREEN}3)${NC} 단일 VM 마이그레이션"
    echo -e "  ${GREEN}4)${NC} 취소"
    echo ""
    echo -n -e "${YELLOW}  선택${NC} [기본값: 1]: "
    read -r choice
    [ -z "$choice" ] && choice=1

    local vmis_to_migrate=""
    case "$choice" in
        1)
            vmis_to_migrate=$(oc get vmi -n "$ns" -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null || true)
            ;;
        2)
            echo -n -e "${YELLOW}  마이그레이션할 VM 이름 패턴 (예: poc-bulk-)${NC}: "
            read -r pattern
            if [ -z "$pattern" ]; then
                print_warn "패턴이 입력되지 않았습니다."
                exit 0
            fi
            vmis_to_migrate=$(oc get vmi -n "$ns" -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}' 2>/dev/null | \
                tr ' ' '\n' | grep "$pattern" | tr '\n' ' ' || true)
            if [ -z "$vmis_to_migrate" ]; then
                print_info "패턴 '${pattern}'에 일치하는 실행 중인 VM이 없습니다."
                exit 0
            fi
            ;;
        3)
            echo -n -e "${YELLOW}  마이그레이션할 VM 이름${NC}: "
            read -r single_vm
            if [ -z "$single_vm" ]; then
                print_warn "VM 이름이 입력되지 않았습니다."
                exit 0
            fi
            if ! oc get vmi "$single_vm" -n "$ns" &>/dev/null; then
                print_error "VMI '${single_vm}'을(를) 찾을 수 없습니다."
                exit 1
            fi
            vmis_to_migrate="$single_vm"
            ;;
        *)
            print_warn "취소됨."
            exit 0
            ;;
    esac

    if [ -z "$vmis_to_migrate" ]; then
        print_info "마이그레이션할 실행 중인 VM이 없습니다."
        exit 0
    fi

    local migrate_count
    migrate_count=$(echo "$vmis_to_migrate" | wc -w | tr -d ' ')

    echo ""
    echo -n -e "${YELLOW}  ${migrate_count}개의 VM을 마이그레이션합니다. 계속하시겠습니까? (Y/n)${NC}: "
    read -r confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        print_warn "취소됨."
        exit 0
    fi

    # 마이그레이션 실행
    print_step "라이브 마이그레이션 실행"

    local migrated=0
    local failed=0
    local idx=0

    for vmi in $vmis_to_migrate; do
        idx=$((idx + 1))
        local current_node
        current_node=$(oc get vmi "$vmi" -n "$ns" \
            -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "unknown")
        print_info "[${idx}/${migrate_count}] VM ${vmi} 마이그레이션 중... (현재 노드: ${current_node})"

        if virtctl migrate "$vmi" -n "$ns" 2>/dev/null; then
            print_ok "VM ${vmi} 마이그레이션 요청됨"
            migrated=$((migrated + 1))
        else
            print_error "VM ${vmi} 마이그레이션 요청 실패"
            failed=$((failed + 1))
        fi
    done

    # 마이그레이션 상태 대기
    print_step "마이그레이션 상태 확인"

    print_info "마이그레이션 완료 대기 중... (최대 5분)"
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

        print_info "진행 중인 마이그레이션: ${pending}개 (${elapsed}초 경과)"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    # 최종 결과
    echo ""
    echo -e "${CYAN}━━━ 마이그레이션 결과 ━━━${NC}"
    echo ""
    oc get vmim -n "$ns" \
        -o custom-columns=NAME:.metadata.name,VMI:.spec.vmiName,PHASE:.status.phase \
        --no-headers 2>/dev/null | while IFS= read -r line; do
        echo "  $line"
    done

    echo ""
    echo -e "${CYAN}━━━ VM 배치 현황 ━━━${NC}"
    echo ""
    oc get vmi -n "$ns" \
        -o custom-columns=NAME:.metadata.name,NODE:.status.nodeName,PHASE:.status.phase \
        --no-headers 2>/dev/null | while IFS= read -r line; do
        echo "  $line"
    done

    # 결과 요약
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  마이그레이션 완료${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  요청됨 : ${GREEN}${migrated}${NC}개"
    [ "$failed" -gt 0 ] && echo -e "  실패   : ${RED}${failed}${NC}개"
    echo ""
    echo -e "  마이그레이션 기록 확인:"
    echo -e "  ${CYAN}oc get vmim -n ${ns}${NC}"
    echo ""
    echo -e "  VM 배치 확인:"
    echo -e "  ${CYAN}oc get vmi -n ${ns} -o wide${NC}"
    echo ""
}

main "${1:-}"
