#!/bin/bash
# =============================================================================
# migrate-10vms.sh — VM 10개 라이브 마이그레이션
# =============================================================================

set -euo pipefail
trap '[[ "$BASH_COMMAND" =~ ^(oc|kubectl|virtctl) ]] && echo "+ $BASH_COMMAND"' DEBUG

RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

VM_NS="${VM_NS:-poc-bulk}"
VM_PREFIX="${VM_PREFIX:-poc-vm}"
VM_COUNT=10
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"

print_info()  { echo -e "${BLUE}[정보]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[경고]${NC} $1"; }
print_error() { echo -e "${RED}[오류]${NC} $1"; }

# ── 사전 점검 ──
if ! oc whoami &>/dev/null; then
    print_error "OpenShift에 로그인되어 있지 않습니다."
    exit 1
fi
print_ok "클러스터 연결: $(oc whoami) @ $(oc whoami --show-server)"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  라이브 마이그레이션 시작 (${VM_PREFIX}-01 ~ ${VM_PREFIX}-10)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ── 마이그레이션 전 노드 배치 확인 ──
print_info "마이그레이션 전 노드 배치:"
echo ""
printf "  %-20s %-8s %s\n" "VM 이름" "상태" "노드"
echo "  ──────────────────────────────────────────────────────"
for i in $(seq -w 1 ${VM_COUNT}); do
    VM_NAME="${VM_PREFIX}-${i}"
    status=$(oc get vmi "$VM_NAME" -n "$VM_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    node=$(oc get vmi "$VM_NAME" -n "$VM_NS" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "-")
    printf "  %-20s %-8s %s\n" "$VM_NAME" "$status" "$node"
done
echo ""

# ── 마이그레이션 요청 ──
migrated=0
skipped=0
for i in $(seq -w 1 ${VM_COUNT}); do
    VM_NAME="${VM_PREFIX}-${i}"

    # Running 상태 확인
    status=$(oc get vmi "$VM_NAME" -n "$VM_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$status" != "Running" ]; then
        print_warn "[${i}/${VM_COUNT}] ${VM_NAME} — Running 상태가 아닙니다 (${status:-NotFound}), 건너뜀"
        skipped=$((skipped + 1))
        continue
    fi

    virtctl migrate "$VM_NAME" -n "$VM_NS" 2>/dev/null
    print_ok "[${i}/${VM_COUNT}] ${VM_NAME} — 마이그레이션 요청됨"
    migrated=$((migrated + 1))
done

if [ "$migrated" -eq 0 ]; then
    print_warn "마이그레이션할 VM이 없습니다."
    exit 0
fi

# ── 마이그레이션 완료 대기 ──
echo ""
print_info "마이그레이션 완료 대기 중... (최대 ${WAIT_TIMEOUT}초)"

elapsed=0
while [ $elapsed -lt $WAIT_TIMEOUT ]; do
    pending=0
    for i in $(seq -w 1 ${VM_COUNT}); do
        VM_NAME="${VM_PREFIX}-${i}"
        migrating=$(oc get vmim -n "$VM_NS" -l "kubevirt.io/vmi-name=${VM_NAME}" \
            -o jsonpath='{.items[?(@.status.phase!="Succeeded")].metadata.name}' 2>/dev/null || true)
        [ -n "$migrating" ] && pending=$((pending + 1))
    done

    if [ "$pending" -eq 0 ]; then
        break
    fi

    echo -ne "\r  대기 중... ${pending}개 마이그레이션 진행 중 (${elapsed}s/${WAIT_TIMEOUT}s)"
    sleep 5
    elapsed=$((elapsed + 5))
done
echo ""

# ── 마이그레이션 후 노드 배치 확인 ──
echo ""
print_info "마이그레이션 후 노드 배치:"
echo ""
printf "  %-20s %-8s %s\n" "VM 이름" "상태" "노드"
echo "  ──────────────────────────────────────────────────────"
for i in $(seq -w 1 ${VM_COUNT}); do
    VM_NAME="${VM_PREFIX}-${i}"
    status=$(oc get vmi "$VM_NAME" -n "$VM_NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")
    node=$(oc get vmi "$VM_NAME" -n "$VM_NS" -o jsonpath='{.status.nodeName}' 2>/dev/null || echo "-")
    printf "  %-20s %-8s %s\n" "$VM_NAME" "$status" "$node"
done

# ── 완료 ──
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  완료! 마이그레이션 ${migrated}개 요청, ${skipped}개 건너뜀${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  마이그레이션 상태: ${CYAN}oc get vmim -n ${VM_NS}${NC}"
echo -e "  VMI 노드 분포   : ${CYAN}oc get vmi -n ${VM_NS} -o wide${NC}"
echo ""
