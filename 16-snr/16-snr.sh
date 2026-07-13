#!/bin/bash
# =============================================================================
# 15-snr.sh
#
# Self Node Remediation (SNR) lab environment setup
#   1. Create poc-snr namespace
#   2. Create SelfNodeRemediationTemplate
#   3. Create NodeHealthCheck CR (SNR integration)
#   4. Deploy 2 VMs using poc template → place on TEST_NODE
#
# Usage: ./15-snr.sh
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

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

print_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERR ]${NC} $1"; }
print_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

confirm_and_apply() {
    local file="$1"
    echo ""
    print_info "YAML to apply:"
    echo "────────────────────────────────────────"
    cat "$file"
    echo "────────────────────────────────────────"
    oc apply -f "$file"
}

# spec.running(deprecated) -> spec.runStrategy migration
# Call before oc patch vm to remove admission webhook warnings
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
# Pre-flight check
# =============================================================================
preflight() {
    print_step "Pre-flight check"

    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to OpenShift."
        exit 1
    fi
    print_ok "Cluster connection: $(oc whoami) @ $(oc whoami --show-server)"

    if [ "${SNR_INSTALLED:-false}" != "true" ]; then
        print_warn "Self Node Remediation Operator not installed → skipping."
        print_warn "  Installation guide: operators/snr-operator.md"
        exit 77
    fi
    print_ok "Self Node Remediation Operator confirmed"

    if [ "${NHC_INSTALLED:-false}" != "true" ]; then
        print_warn "Node Health Check Operator not installed → skipping."
        print_warn "  Installation guide: operators/nhc-operator.md"
        exit 77
    fi
    print_ok "Node Health Check Operator confirmed"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_error "poc Template not found. Please run 01-template first."
        exit 1
    fi
    print_ok "poc Template confirmed"

    if ! oc get node "$NODE1" &>/dev/null; then
        print_error "Node $NODE1 not found. Please check TEST_NODE in env.conf."
        exit 1
    fi
    print_ok "Target node: $NODE1"
}

# =============================================================================
# Step 1: Create namespace
# =============================================================================
step_namespace() {
    print_step "1/4  Create namespace (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "Namespace $NS already exists — skipping"
    else
        oc new-project "$NS" > /dev/null
        print_ok "Namespace $NS created successfully"
    fi
}

# =============================================================================
# Step 2: Create SelfNodeRemediationTemplate
# =============================================================================
step_snr_template() {
    print_step "2/4  Create SelfNodeRemediationTemplate"

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
    print_ok "SelfNodeRemediationTemplate poc-snr-template created successfully"
}

# =============================================================================
# Step 3: Create NodeHealthCheck
# =============================================================================
step_nhc() {
    print_step "3/5  Create NodeHealthCheck (SNR integration)"

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
    print_ok "NodeHealthCheck poc-snr-nhc created successfully"
    print_info "  Condition: Ready=False or Unknown for 300s or more → SNR triggered"
}

# =============================================================================
# Step 4: Deploy VMs
# =============================================================================
step_consoleyamlsamples() {
    print_step "5/5  Register ConsoleYAMLSample"

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
    print_ok "ConsoleYAMLSample poc-nodehealthcheck-snr registered successfully"
}

step_vms() {
    print_step "4/5  Deploy VMs → ${NODE1}"

    for VM in poc-snr-vm-1 poc-snr-vm-2; do
        if oc get vm "$VM" -n "$NS" &>/dev/null; then
            print_ok "VM $VM already exists — skipping"
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
        print_ok "VM $VM deployed successfully (node: ${NODE1})"
    done
}

# =============================================================================
# Completion summary
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! SNR lab environment is ready.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Check VM placement:"
    echo -e "    ${CYAN}oc get vmi -n ${NS} -o wide${NC}"
    echo ""
    echo -e "  Check NHC status:"
    echo -e "    ${CYAN}oc get nodehealthcheck poc-snr-nhc${NC}"
    echo ""
    echo -e "  Failure simulation:"
    echo -e "    ${CYAN}oc debug node/${NODE1} -- chroot /host systemctl stop kubelet${NC}"
    echo ""
    echo -e "  Verify SNR triggered (after 300 seconds):"
    echo -e "    ${CYAN}oc get selfnoderemediation -A${NC}"
    echo -e "    ${CYAN}oc get nodes -w${NC}"
    echo ""
    echo -e "  For details: 15-snr.md"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Delete 15-snr resources"
    local _rem_ns="openshift-workload-availability"
    oc delete project poc-snr --ignore-not-found 2>/dev/null || true
    oc delete nodehealthcheck poc-snr-nhc --ignore-not-found 2>/dev/null || true
    oc delete selfnoderemediationtemplate poc-snr-template -n "$_rem_ns" --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-nodehealthcheck-snr --ignore-not-found 2>/dev/null || true
    print_ok "15-snr resources deleted successfully"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  SNR lab environment setup${NC}"
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
