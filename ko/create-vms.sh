#!/bin/bash
# =============================================================================
# create-vms.sh
#
# poc 템플릿을 사용하여 지정한 개수만큼 VM을 일괄 생성합니다.
#
# 사용법: ./create-vms.sh [VM개수] [네임스페이스]
#   예시) ./create-vms.sh            ← 대화형 입력
#   예시) ./create-vms.sh 5          ← poc-vm 네임스페이스에 VM 5개 생성
#   예시) ./create-vms.sh 3 my-ns    ← my-ns 네임스페이스에 VM 3개 생성
# =============================================================================

set -euo pipefail
trap '[[ "$BASH_COMMAND" =~ ^(oc|kubectl|virtctl) ]] && echo "+ $BASH_COMMAND"' DEBUG
trap 'echo -e "\n\033[0;31m[오류]\033[0m ${LINENO}번째 줄에서 명령 실패: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# env.conf 자동 로드 (단독 실행 시)
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
    print_info()  { echo -e "${BLUE}[정보]${NC} $1"; }
    print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
    print_warn()  { echo -e "${YELLOW}[경고]${NC} $1"; }
    print_error() { echo -e "${RED}[오류]${NC} $1"; }
    print_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }
    print_header() {
        echo -e "\n${CYAN}================================================================${NC}"
        echo -e "${CYAN}  $1${NC}"
        echo -e "${CYAN}================================================================${NC}\n"
    }
    auto_detect_operators() { :; }
fi

# =============================================================================
# 사전 점검
# =============================================================================
preflight() {
    print_step "사전 점검"
    auto_detect_operators

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator가 설치되지 않았습니다."
        print_warn "  설치 가이드: operators/kubevirt-hyperconverged-operator.md"
        exit 77
    fi

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 연결: $(oc whoami) @ $(oc whoami --show-server)"

    if ! oc get template "$TEMPLATE_NAME" -n "$TEMPLATE_NS" &>/dev/null; then
        print_error "poc Template을 찾을 수 없습니다. 먼저 01-template을 실행하세요."
        exit 1
    fi
    print_ok "Template '${TEMPLATE_NAME}' 확인됨 (namespace: ${TEMPLATE_NS})"
}

# =============================================================================
# 입력 받기
# =============================================================================
get_input() {
    local vm_count_arg="${1:-}"
    local vm_ns_arg="${2:-}"

    # VM 개수
    if [ -n "$vm_count_arg" ]; then
        VM_COUNT="$vm_count_arg"
    else
        echo -n -e "${YELLOW}  생성할 VM 개수를 입력하세요${NC} [기본값: 3]: "
        read -r VM_COUNT
        [ -z "$VM_COUNT" ] && VM_COUNT=3
    fi

    if ! [[ "$VM_COUNT" =~ ^[0-9]+$ ]] || [ "$VM_COUNT" -lt 1 ] || [ "$VM_COUNT" -gt 100 ]; then
        print_error "VM 개수는 1~100 사이의 숫자여야 합니다: ${VM_COUNT}"
        exit 1
    fi

    # 네임스페이스
    if [ -n "$vm_ns_arg" ]; then
        VM_NS="$vm_ns_arg"
    else
        echo -n -e "${YELLOW}  VM을 생성할 네임스페이스${NC} [기본값: poc-vm]: "
        read -r VM_NS
        [ -z "$VM_NS" ] && VM_NS="poc-vm"
    fi

    # VM 이름 접두사
    echo -n -e "${YELLOW}  VM 이름 접두사${NC} [기본값: ${VM_PREFIX}]: "
    read -r input_prefix
    [ -n "$input_prefix" ] && VM_PREFIX="$input_prefix"

    # VM 시작 여부
    echo -n -e "${YELLOW}  생성 후 VM을 시작하시겠습니까? (y/N)${NC}: "
    read -r START_VMS
    START_VMS="${START_VMS:-n}"

    echo ""
    print_info "설정 요약:"
    print_info "  VM 개수      : ${VM_COUNT}"
    print_info "  네임스페이스  : ${VM_NS}"
    print_info "  이름 접두사   : ${VM_PREFIX}"
    print_info "  VM 시작      : ${START_VMS}"
    echo ""
    echo -n -e "${YELLOW}  위 설정으로 진행하시겠습니까? (Y/n)${NC}: "
    read -r confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        print_warn "취소됨."
        exit 0
    fi
}

# =============================================================================
# 네임스페이스 생성
# =============================================================================
ensure_namespace() {
    print_step "1/2  네임스페이스 확인 (${VM_NS})"

    if oc get namespace "${VM_NS}" &>/dev/null; then
        print_ok "Namespace ${VM_NS} 이미 존재합니다"
    else
        print_info "Namespace ${VM_NS} 생성 중..."
        oc new-project "${VM_NS}" > /dev/null
        print_ok "Namespace ${VM_NS} 생성됨"
    fi
}

# =============================================================================
# VM 일괄 생성
# =============================================================================
create_vms() {
    print_step "2/2  VM ${VM_COUNT}개 생성 (${VM_PREFIX}-1 ~ ${VM_PREFIX}-${VM_COUNT})"

    local created=0
    local skipped=0
    local failed=0

    for i in $(seq 1 "$VM_COUNT"); do
        local vm_name="${VM_PREFIX}-${i}"

        if oc get vm "$vm_name" -n "$VM_NS" &>/dev/null; then
            print_warn "VM ${vm_name} 이미 존재합니다 — 건너뜀"
            skipped=$((skipped + 1))
            continue
        fi

        print_info "[${i}/${VM_COUNT}] VM ${vm_name} 생성 중..."

        if oc process -n "$TEMPLATE_NS" "$TEMPLATE_NAME" -p NAME="$vm_name" | \
            oc apply -n "$VM_NS" -f - &>/dev/null; then

            # spec.running → spec.runStrategy 마이그레이션
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
                print_ok "VM ${vm_name} 생성 및 시작됨"
            else
                print_ok "VM ${vm_name} 생성됨 (Halted)"
            fi
            created=$((created + 1))
        else
            print_error "VM ${vm_name} 생성 실패"
            failed=$((failed + 1))
        fi
    done

    # 결과 요약
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  VM 생성 완료${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  생성됨 : ${GREEN}${created}${NC}개"
    [ "$skipped" -gt 0 ] && echo -e "  건너뜀 : ${YELLOW}${skipped}${NC}개 (이미 존재)"
    [ "$failed" -gt 0 ]  && echo -e "  실패   : ${RED}${failed}${NC}개"
    echo ""
    echo -e "  VM 목록 확인:"
    echo -e "  ${CYAN}oc get vm -n ${VM_NS}${NC}"
    echo ""
    if [[ "$START_VMS" =~ ^[Yy]$ ]]; then
        echo -e "  VMI 상태 확인:"
        echo -e "  ${CYAN}oc get vmi -n ${VM_NS}${NC}"
        echo ""
    fi
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: VM 일괄 삭제"

    local ns="${2:-poc-vm}"
    echo -n -e "${YELLOW}  네임스페이스 '${ns}'의 VM을 삭제합니다. 계속하시겠습니까? (y/N)${NC}: "
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_warn "취소됨."
        exit 0
    fi

    local vms
    vms=$(oc get vm -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -z "$vms" ]; then
        print_info "네임스페이스 '${ns}'에 VM이 없습니다."
        exit 0
    fi

    for vm in $vms; do
        virtctl stop "$vm" -n "$ns" 2>/dev/null || true
        oc delete vm "$vm" -n "$ns" --ignore-not-found 2>/dev/null || true
        print_ok "VM ${vm} 삭제됨"
    done

    print_ok "정리 완료"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  POC VM 일괄 생성${NC}"
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
