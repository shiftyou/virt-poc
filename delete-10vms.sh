#!/bin/bash
# =============================================================================
# delete-10vms.sh — VM 10개 및 Namespace 삭제
# =============================================================================

set -xeuo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

VM_NS="${VM_NS:-poc-bulk}"
VM_PREFIX="${VM_PREFIX:-poc-vm}"
VM_COUNT=10

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

if ! oc get namespace "${VM_NS}" &>/dev/null; then
    print_warn "Namespace ${VM_NS}가 존재하지 않습니다. 삭제할 항목이 없습니다."
    exit 0
fi

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  VM ${VM_COUNT}개 삭제 시작 (${VM_PREFIX}-01 ~ ${VM_PREFIX}-10)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# ── VM 개별 삭제 ──
deleted=0
for i in $(seq -w 1 ${VM_COUNT}); do
    VM_NAME="${VM_PREFIX}-${i}"

    if ! oc get vm "$VM_NAME" -n "$VM_NS" &>/dev/null; then
        print_warn "[${i}/${VM_COUNT}] ${VM_NAME} — 존재하지 않음, 건너뜀"
        continue
    fi

    # VM 중지 후 삭제
    virtctl stop "$VM_NAME" -n "$VM_NS" 2>/dev/null || true
    oc delete vm "$VM_NAME" -n "$VM_NS" --wait=false 2>/dev/null || true
    print_ok "[${i}/${VM_COUNT}] ${VM_NAME} 삭제 요청됨"
    deleted=$((deleted + 1))
done

# ── VM 삭제 완료 대기 ──
if [ "$deleted" -gt 0 ]; then
    print_info "VM 삭제 완료 대기 중..."
    for i in $(seq -w 1 ${VM_COUNT}); do
        VM_NAME="${VM_PREFIX}-${i}"
        oc wait --for=delete vm/"$VM_NAME" -n "$VM_NS" --timeout=120s 2>/dev/null || true
    done
fi

# ── Namespace 삭제 ──
echo ""
print_info "Namespace ${VM_NS} 삭제 중..."
oc delete project "${VM_NS}" --wait=false 2>/dev/null || true
print_ok "Namespace ${VM_NS} 삭제 요청됨"

# ── 완료 ──
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  완료! VM ${deleted}개 삭제, Namespace ${VM_NS} 삭제 요청됨${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  삭제 확인: ${CYAN}oc get vm -n ${VM_NS}${NC}"
echo -e "  NS  확인: ${CYAN}oc get project ${VM_NS}${NC}"
echo ""
