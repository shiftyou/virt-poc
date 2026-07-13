#!/bin/bash
# =============================================================================
# 15-node-maintenance.sh
#
# 노드 유지보수 랩 환경 구성
#   1. poc-maintenance namespace 생성
#   2. poc 템플릿으로 VM 2대 배포 → Live Migration으로 TEST_NODE에 통합
#   3. NodeMaintenance 생성 → cordon + drain → VM 자동 Migration 검증
#
# 사용법: ./15-node-maintenance.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# env.conf 자동 로드 (단독 실행 시)
ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-maintenance"
NODE1="${TEST_NODE}"

source "${SCRIPT_DIR}/../utils/common.sh"

# spec.running(deprecated) -> spec.runStrategy 마이그레이션
# oc patch vm 전에 호출하여 admission webhook 경고 제거
ensure_runstrategy() {
    local vm="$1" ns="$2"
    local running
    running=$(oc get vm "$vm" -n "$ns" \
        -o jsonpath='{.spec.running}' 2>/dev/null || true)
    [ -z "$running" ] && return 0
    local rs="Halted"
    [ "$running" = "true" ] && rs="Always"
    oc patch vm "$vm" -n "$ns" --type=json -p "[
      {\"op\":\"remove\",\"path\":\"/spec/running\"},
      {\"op\":\"add\",\"path\":\"/spec/runStrategy\",\"value\":\"${rs}\"}
    ]" &>/dev/null || true
}

# =============================================================================
# 사전 점검
# =============================================================================
preflight() {
    print_step "사전 점검"

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

    if ! oc get node "$NODE1" &>/dev/null; then
        print_error "Node $NODE1을 찾을 수 없습니다. env.conf의 TEST_NODE를 확인하세요."
        exit 1
    fi
    print_ok "대상 노드: $NODE1"

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator가 설치되어 있지 않습니다 → 건너뜀."
        print_warn "  설치 가이드: operators/kubevirt-hyperconverged-operator.md"
        exit 77
    fi
    print_ok "OpenShift Virtualization Operator 확인됨"

    # Node Maintenance Operator 설치 확인 (env.conf: NMO_INSTALLED)
    if [ "${NMO_INSTALLED:-false}" != "true" ]; then
        if ! oc get csv -A 2>/dev/null | grep -qi "node-maintenance"; then
            print_warn "Node Maintenance Operator가 설치되어 있지 않습니다 → 건너뜀."
            print_warn "  설치 가이드: operators/node-maintenance-operator.md"
            exit 77
        fi
    fi
    print_ok "Node Maintenance Operator 확인됨"

    # 워커 노드 최소 2개 확인
    local worker_count
    worker_count=$(oc get node -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$worker_count" -lt 2 ]; then
        print_error "워커 노드가 최소 2개 필요합니다. (현재: ${worker_count})"
        exit 1
    fi
    print_ok "워커 노드: ${worker_count}개 확인됨"

    print_info "  NS    : ${NS}"
    print_info "  NODE1 : ${NODE1}"
}

# =============================================================================
# Step 1: namespace 생성
# =============================================================================
step_namespace() {
    print_step "1/3  namespace 생성 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "Namespace $NS이(가) 이미 존재합니다 — 건너뜀"
    else
        oc new-project "$NS" > /dev/null
        print_ok "Namespace $NS 생성 완료"
    fi
}

# =============================================================================
# Step 2: VM 2대 배포 → TEST_NODE로 Live Migration
# =============================================================================
step_vms() {
    print_step "2/4  VM 2대 배포 → ${NODE1}(으)로 Live Migration"

    for VM in poc-maintenance-vm-1 poc-maintenance-vm-2; do
        if oc get vm "$VM" -n "$NS" &>/dev/null; then
            print_ok "VM $VM이(가) 이미 존재합니다 — 건너뜀"
            continue
        fi

        oc process -n openshift poc -p NAME="$VM" | \
        sed 's/runStrategy: Always/runStrategy: Halted/' | sed 's/  running: false/  runStrategy: Halted/' > "${VM}.yaml"
        echo "생성된 파일: ${VM}.yaml"
        oc apply -n "$NS" -f "${VM}.yaml"

        # evictionStrategy: LiveMigrate 설정
        ensure_runstrategy "$VM" "$NS"
        oc patch vm "$VM" -n "$NS" --type=merge -p '{
          "spec": {
            "template": {
              "spec": {
                "evictionStrategy": "LiveMigrate"
              }
            }
          }
        }'

        virtctl start "$VM" -n "$NS" 2>/dev/null || true
        print_ok "VM $VM 배포 완료"
    done

    # Running 상태 대기
    print_info "VM Running 상태 대기 중..."
    for VM in poc-maintenance-vm-1 poc-maintenance-vm-2; do
        local retries=36
        local i=0
        while [ $i -lt $retries ]; do
            local phase
            phase=$(oc get vmi "$VM" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
            if [ "$phase" = "Running" ]; then
                print_ok "VMI $VM Running 상태"
                break
            fi
            printf "  [%d/%d] %s 대기 중... (%s)\r" "$((i+1))" "$retries" "$VM" "${phase:-Pending}"
            sleep 5
            i=$((i+1))
        done
        echo ""
    done

    # TEST_NODE로 Live Migration
    for VM in poc-maintenance-vm-1 poc-maintenance-vm-2; do
        local current_node
        current_node=$(oc get vmi "$VM" -n "$NS" -o jsonpath='{.status.nodeName}' 2>/dev/null || true)

        if [ "$current_node" = "$NODE1" ]; then
            print_ok "VM $VM이(가) 이미 ${NODE1}에 있습니다 — Migration 건너뜀"
            continue
        fi

        print_info "VM $VM Migration 시작: ${current_node} → ${NODE1}"

        # 임시 nodeSelector 설정
        ensure_runstrategy "$VM" "$NS"
        oc patch vm "$VM" -n "$NS" --type=merge -p "{
          \"spec\": {
            \"template\": {
              \"spec\": {
                \"nodeSelector\": {\"kubernetes.io/hostname\": \"${NODE1}\"}
              }
            }
          }
        }"

        local VMIM_NAME="migrate-${VM}-to-node1"
        cat > "vmim-${VM}.yaml" <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: ${VMIM_NAME}
  namespace: ${NS}
spec:
  vmiName: ${VM}
EOF
        echo "생성된 파일: vmim-${VM}.yaml"
        print_info "  다음 명령어로 직접 적용하세요:"
        echo -e "    ${CYAN}oc apply -f vmim-${VM}.yaml${NC}"
    done

    echo ""
    print_info "현재 VM 배치 현황:"
    oc get vmi -n "$NS" \
      -o custom-columns=NAME:.metadata.name,NODE:.status.nodeName,PHASE:.status.phase \
      2>/dev/null || true
}

# =============================================================================
# Step 3: NodeMaintenance 생성 → Migration 검증
# =============================================================================
step_consoleyamlsamples() {
    print_step "4/4  ConsoleYAMLSample 등록"

    cat > consoleyamlsample-nodemaintenance.yaml <<'EOF'
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-nodemaintenance
spec:
  title: "POC NodeMaintenance"
  description: "Example NodeMaintenance CR for putting a node into maintenance mode. When created, the node is cordoned and VMs are automatically Live Migrated."
  targetResource:
    apiVersion: nodemaintenance.medik8s.io/v1beta1
    kind: NodeMaintenance
  yaml: |
    apiVersion: nodemaintenance.medik8s.io/v1beta1
    kind: NodeMaintenance
    metadata:
      name: maintenance-worker-0
    spec:
      nodeName: worker-0
      reason: "POC maintenance lab"
EOF
    oc apply -f consoleyamlsample-nodemaintenance.yaml
    print_ok "ConsoleYAMLSample poc-nodemaintenance 등록 완료"
}

step_maintenance() {
    print_step "3/4  NodeMaintenance 생성 (${NODE1})"

    if oc get nodemaintenance "maintenance-${NODE1}" &>/dev/null; then
        print_ok "NodeMaintenance maintenance-${NODE1}이(가) 이미 존재합니다 — 건너뜀"
        return
    fi

    cat > "nodemaintenance-${NODE1}.yaml" <<EOF
apiVersion: nodemaintenance.medik8s.io/v1beta1
kind: NodeMaintenance
metadata:
  name: maintenance-${NODE1}
spec:
  nodeName: ${NODE1}
  reason: "POC maintenance lab"
EOF
    echo "생성된 파일: nodemaintenance-${NODE1}.yaml"
    print_ok "NodeMaintenance YAML 생성 완료 (미적용)"
    print_info "다음 명령어로 직접 적용하세요:"
    echo -e "    ${CYAN}oc apply -f nodemaintenance-${NODE1}.yaml${NC}"
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! 노드 유지보수 랩 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  VM Migration 확인:"
    echo -e "    ${CYAN}oc get vmi -n ${NS} -o wide${NC}"
    echo ""
    echo -e "  NodeMaintenance 상태:"
    echo -e "    ${CYAN}oc get nodemaintenance${NC}"
    echo ""
    echo -e "  유지보수 종료 (노드 복구):"
    echo -e "    ${CYAN}oc delete nodemaintenance maintenance-${NODE1}${NC}"
    echo ""
    echo -e "  상세 내용: 15-node-maintenance/15-node-maintenance.md"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 15-node-maintenance 리소스 삭제"
    oc delete project poc-maintenance --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-nodemaintenance --ignore-not-found 2>/dev/null || true
    print_ok "15-node-maintenance 리소스 삭제 완료"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  노드 유지보수 랩 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_vms
    step_maintenance
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
