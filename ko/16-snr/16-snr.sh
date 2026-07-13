#!/bin/bash
# =============================================================================
# 16-snr.sh
#
# Self Node Remediation (SNR) 랩 환경 구성
#   1. poc-snr namespace 생성
#   2. SelfNodeRemediationTemplate 생성
#   3. NodeHealthCheck CR 생성 (SNR 연동)
#   4. poc 템플릿으로 VM 2대 배포 → TEST_NODE에 배치
#
# 사용법: ./16-snr.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-snr"
REMEDIATION_NS="openshift-workload-availability"
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

    if [ "${SNR_INSTALLED:-false}" != "true" ]; then
        print_warn "Self Node Remediation Operator가 설치되어 있지 않습니다 → 건너뜀."
        print_warn "  설치 가이드: operators/snr-operator.md"
        exit 77
    fi
    print_ok "Self Node Remediation Operator 확인됨"

    if [ "${NHC_INSTALLED:-false}" != "true" ]; then
        print_warn "Node Health Check Operator가 설치되어 있지 않습니다 → 건너뜀."
        print_warn "  설치 가이드: operators/nhc-operator.md"
        exit 77
    fi
    print_ok "Node Health Check Operator 확인됨"

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
}

# =============================================================================
# Step 1: namespace 생성
# =============================================================================
step_namespace() {
    print_step "1/4  namespace 생성 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "Namespace ${NS}이(가) 이미 존재합니다 — 건너뜀"
    else
        oc new-project "$NS" > /dev/null
        print_ok "Namespace $NS 생성 완료"
    fi
}

# =============================================================================
# Step 2: SelfNodeRemediationTemplate 생성
# =============================================================================
step_snr_template() {
    print_step "2/4  SelfNodeRemediationTemplate 생성"

    cat > snr-template.yaml <<EOF
apiVersion: self-node-remediation.medik8s.io/v1alpha1
kind: SelfNodeRemediationTemplate
metadata:
  name: poc-snr-template
  namespace: ${REMEDIATION_NS}
spec:
  template:
    spec:
      remediationStrategy: ResourceDeletion
EOF
    confirm_and_apply snr-template.yaml
    print_ok "SelfNodeRemediationTemplate poc-snr-template 생성 완료"
}

# =============================================================================
# Step 3: NodeHealthCheck 생성
# =============================================================================
step_nhc() {
    print_step "3/5  NodeHealthCheck 생성 (SNR 연동)"

    cat > nhc-snr.yaml <<EOF
apiVersion: remediation.medik8s.io/v1alpha1
kind: NodeHealthCheck
metadata:
  name: poc-snr-nhc
spec:
  minHealthy: "51%"
  remediationTemplate:
    apiVersion: self-node-remediation.medik8s.io/v1alpha1
    kind: SelfNodeRemediationTemplate
    name: poc-snr-template
    namespace: ${REMEDIATION_NS}
  selector:
    matchExpressions:
      - key: node-role.kubernetes.io/worker
        operator: Exists
  unhealthyConditions:
    - type: Ready
      status: "False"
      duration: 300s
    - type: Ready
      status: "Unknown"
      duration: 300s
EOF
    confirm_and_apply nhc-snr.yaml
    print_ok "NodeHealthCheck poc-snr-nhc 생성 완료"
    print_info "  조건: Ready=False 또는 Unknown이 300초 이상 지속 → SNR 트리거"
}

# =============================================================================
# Step 4: VM 배포
# =============================================================================
step_consoleyamlsamples() {
    print_step "5/5  ConsoleYAMLSample 등록"

    cat > consoleyamlsample-nhc-snr.yaml <<'EOF'
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-nodehealthcheck-snr
spec:
  title: "POC NodeHealthCheck (SNR integration)"
  description: "Example NodeHealthCheck CR for auto-recovering unhealthy worker nodes using Self Node Remediation. SNR is triggered when Ready=False or Unknown state persists for 300 seconds."
  targetResource:
    apiVersion: remediation.medik8s.io/v1alpha1
    kind: NodeHealthCheck
  yaml: |
    apiVersion: remediation.medik8s.io/v1alpha1
    kind: NodeHealthCheck
    metadata:
      name: poc-snr-nhc
    spec:
      minHealthy: "51%"
      remediationTemplate:
        apiVersion: self-node-remediation.medik8s.io/v1alpha1
        kind: SelfNodeRemediationTemplate
        name: poc-snr-template
        namespace: openshift-workload-availability
      selector:
        matchExpressions:
          - key: node-role.kubernetes.io/worker
            operator: Exists
      unhealthyConditions:
        - type: Ready
          status: "False"
          duration: 300s
        - type: Ready
          status: "Unknown"
          duration: 300s
EOF
    oc apply -f consoleyamlsample-nhc-snr.yaml
    print_ok "ConsoleYAMLSample poc-nodehealthcheck-snr 등록 완료"
}

step_vms() {
    print_step "4/5  VM 배포 → ${NODE1}"

    for VM in poc-snr-vm-1 poc-snr-vm-2; do
        if oc get vm "$VM" -n "$NS" &>/dev/null; then
            print_ok "VM ${VM}이(가) 이미 존재합니다 — 건너뜀"
            continue
        fi

        oc process -n openshift poc -p NAME="$VM" | \
        sed 's/runStrategy: Always/runStrategy: Halted/' | sed 's/  running: false/  runStrategy: Halted/' > "${VM}.yaml"
        oc apply -n "$NS" -f "${VM}.yaml"

        ensure_runstrategy "$VM" "$NS"
        oc patch vm "$VM" -n "$NS" --type=merge -p "{
          \"spec\": {
            \"template\": {
              \"spec\": {
                \"nodeSelector\": {\"kubernetes.io/hostname\": \"${NODE1}\"},
                \"evictionStrategy\": \"LiveMigrate\"
              }
            }
          }
        }"

        virtctl start "$VM" -n "$NS" 2>/dev/null || true
        print_ok "VM $VM 배포 완료 (노드: ${NODE1})"
    done
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! SNR 랩 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  VM 배치 확인:"
    echo -e "    ${CYAN}oc get vmi -n ${NS} -o wide${NC}"
    echo ""
    echo -e "  NHC 상태 확인:"
    echo -e "    ${CYAN}oc get nodehealthcheck poc-snr-nhc${NC}"
    echo ""
    echo -e "  장애 시뮬레이션:"
    echo -e "    ${CYAN}oc debug node/${NODE1} -- chroot /host systemctl stop kubelet${NC}"
    echo ""
    echo -e "  SNR 트리거 확인 (300초 후):"
    echo -e "    ${CYAN}oc get selfnoderemediation -A${NC}"
    echo -e "    ${CYAN}oc get nodes -w${NC}"
    echo ""
    echo -e "  상세 내용: 16-snr/16-snr.md"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 16-snr 리소스 삭제"
    local _rem_ns="openshift-workload-availability"
    oc delete project poc-snr --ignore-not-found 2>/dev/null || true
    oc delete nodehealthcheck poc-snr-nhc --ignore-not-found 2>/dev/null || true
    oc delete selfnoderemediationtemplate poc-snr-template -n "$_rem_ns" --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-nodehealthcheck-snr --ignore-not-found 2>/dev/null || true
    print_ok "16-snr 리소스 삭제 완료"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  SNR 랩 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_snr_template
    step_nhc
    step_vms
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
