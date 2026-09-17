#!/bin/bash
# =============================================================================
# create-10vms.sh — poc template 기반 VM 10개 생성
# =============================================================================

set -euo pipefail
trap '[[ "$BASH_COMMAND" =~ ^(oc|kubectl|virtctl) ]] && echo "+ $BASH_COMMAND"' DEBUG

RED='\033[0;31m'; GREEN='\033[0;32m'
YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

VM_NS="${VM_NS:-poc-bulk}"
VM_PREFIX="${VM_PREFIX:-poc-vm}"
VM_COUNT=10
STORAGE_CLASS="${STORAGE_CLASS:-}"

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

if ! oc get template poc -n openshift &>/dev/null; then
    print_error "poc Template을 찾을 수 없습니다. 먼저 01-template을 실행하세요."
    exit 1
fi
print_ok "poc Template 확인됨"

# ── Namespace 생성 ──
if oc get namespace "${VM_NS}" &>/dev/null; then
    print_ok "Namespace ${VM_NS} 이미 존재합니다"
else
    oc new-project "${VM_NS}" > /dev/null
    print_ok "Namespace ${VM_NS} 생성됨"
fi

# ── VM 10개 생성 ──
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  VM ${VM_COUNT}개 생성 시작 (${VM_PREFIX}-01 ~ ${VM_PREFIX}-10)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

for i in $(seq -w 1 ${VM_COUNT}); do
    VM_NAME="${VM_PREFIX}-${i}"

    if oc get vm "$VM_NAME" -n "$VM_NS" &>/dev/null; then
        print_warn "VM ${VM_NAME} 이미 존재합니다 — 건너뜀"
        continue
    fi

    oc process -n openshift poc -p NAME="${VM_NAME}" | \
        oc apply -n "${VM_NS}" -f - &>/dev/null

    # spec.running → runStrategy 변환
    local_running=$(oc get vm "$VM_NAME" -n "$VM_NS" \
        -o jsonpath='{.spec.running}' 2>/dev/null || true)
    if [ -n "$local_running" ]; then
        oc patch vm "$VM_NAME" -n "$VM_NS" --type=json -p '[
          {"op":"remove","path":"/spec/running"},
          {"op":"add","path":"/spec/runStrategy","value":"Always"}
        ]' &>/dev/null || true
    else
        oc patch vm "$VM_NAME" -n "$VM_NS" --type=merge \
            -p '{"spec":{"runStrategy":"Always"}}' &>/dev/null || true
    fi

    virtctl start "$VM_NAME" -n "$VM_NS" 2>/dev/null || true

    print_ok "[${i}/${VM_COUNT}] VM ${VM_NAME} 생성 및 시작"
done

# ── 완료 ──
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  완료! VM ${VM_COUNT}개가 생성되었습니다.${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  VM 목록 확인  : ${CYAN}oc get vm -n ${VM_NS}${NC}"
echo -e "  VMI 상태 확인 : ${CYAN}oc get vmi -n ${VM_NS}${NC}"
echo -e "  노드 분포 확인: ${CYAN}oc get vmi -n ${VM_NS} -o wide${NC}"
echo ""
