#!/bin/bash
# =============================================================================
# 06-resource-quota.sh
#
# ResourceQuota practice environment setup
#   1. Create poc-resource-quota namespace
#   2. Apply ResourceQuota for CPU / Memory / Pod / PVC etc.
#   3. Deploy 2 VMs (pass within Quota) → attempt 3rd VM creation → rejected for exceeding Quota
#
# Usage: ./06-resource-quota.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-load env.conf (when running standalone)
ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-resource-quota"

# VM resources: 750m / 1500m each → 2 VMs=1500m (pass), 3 VMs=2250m (exceed)
VM_CPU_REQUEST="750m"
VM_CPU_LIMIT="1500m"
VM_MEM_REQUEST="1Gi"
VM_MEM_LIMIT="2Gi"

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

# Migrate spec.running (deprecated) -> spec.runStrategy
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
# Pre-flight checks
# =============================================================================
preflight() {
    print_step "Pre-flight checks"

    # Check OpenShift Virtualization Operator
    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator not installed → skipping."
        print_warn "  Installation guide: operators/kubevirt-hyperconverged-operator.md"
        exit 77
    fi

    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift."
        exit 1
    fi
    print_ok "Cluster connection: $(oc whoami) @ $(oc whoami --show-server)"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_error "poc Template not found. Run 01-template first."
        exit 1
    fi
    print_ok "poc Template confirmed"

    print_info "  NS : ${NS}"
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
        print_ok "Namespace $NS created"
    fi
}

# =============================================================================
# Step 2: Apply ResourceQuota
#   requests.cpu: "2" → 2 VMs (each 750m=1500m) pass, 3rd (2250m) exceeds
# =============================================================================
step_quota() {
    print_step "2/4  Apply ResourceQuota (${NS})"

    cat > resourcequota-poc.yaml <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: poc-quota
  namespace: poc-resource-quota
spec:
  hard:
    # Pod count
    pods: "10"
    # CPU — requests.cpu: "2" → 2 VMs at 750m each (1500m) pass, 3 VMs (2250m) exceed
    requests.cpu: "2"
    limits.cpu: "4"
    # Memory
    requests.memory: 4Gi
    limits.memory: 8Gi
    # PersistentVolumeClaim count and capacity
    persistentvolumeclaims: "10"
    requests.storage: 100Gi
    # Service
    services: "10"
    services.loadbalancers: "2"
    services.nodeports: "0"
    # ConfigMap / Secret
    configmaps: "20"
    secrets: "20"
EOF
    echo "Generated file: resourcequota-poc.yaml"
    oc apply -f resourcequota-poc.yaml

    print_ok "ResourceQuota poc-quota applied"
    print_info "  requests.cpu limit: 2 core (2 VMs×750m=1500m pass, 3 VMs=2250m exceed)"
}

# =============================================================================
# Step 3: Register ConsoleYAMLSample
# =============================================================================
step_consoleyamlsamples() {
    print_step "3/4  Register ConsoleYAMLSample"

    cat > consoleyamlsample-resourcequota.yaml <<'EOF'
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-resource-quota
spec:
  title: "POC ResourceQuota Configuration"
  description: "Limits resource usage such as CPU, Memory, Pod, and PVC in a namespace. Apply after creating the namespace. New resource creation is rejected when limits are exceeded."
  targetResource:
    apiVersion: v1
    kind: ResourceQuota
  yaml: |
    apiVersion: v1
    kind: ResourceQuota
    metadata:
      name: poc-quota
      namespace: poc-resource-quota    # Change to target namespace
    spec:
      hard:
        pods: "10"
        requests.cpu: "2"
        limits.cpu: "4"
        requests.memory: 4Gi
        limits.memory: 8Gi
        persistentvolumeclaims: "10"
        requests.storage: 100Gi
        services: "10"
        services.loadbalancers: "2"
        services.nodeports: "0"
        configmaps: "20"
        secrets: "20"
EOF
    echo "Generated file: consoleyamlsample-resourcequota.yaml"
    oc apply -f consoleyamlsample-resourcequota.yaml
    print_ok "ConsoleYAMLSample poc-resource-quota registered"
}

# =============================================================================
# Step 4: Deploy VMs and demonstrate Quota exceeded
#   - poc-quota-vm-1, poc-quota-vm-2: created successfully (requests.cpu total 1500m < 2000m)
#   - poc-quota-vm-3: creation attempt → rejected for exceeding Quota (2250m > 2000m)
# =============================================================================
step_vms() {
    print_step "4/4  Deploy VMs and demonstrate ResourceQuota exceeded"

    # VM 1, 2: create successfully
    for VM in poc-quota-vm-1 poc-quota-vm-2; do
        if oc get vm "$VM" -n "$NS" &>/dev/null; then
            print_ok "VM $VM already exists — skipping"
            continue
        fi

        oc process -n openshift poc -p NAME="$VM" | \
        sed 's/runStrategy: Always/runStrategy: Halted/' | sed 's/  running: false/  runStrategy: Halted/' > "${VM}.yaml"
        echo "Generated file: ${VM}.yaml"
        oc apply -n "$NS" -f "${VM}.yaml"

        ensure_runstrategy "$VM" "$NS"
        oc patch vm "$VM" -n "$NS" --type=merge -p "{
          \"spec\": {
            \"template\": {
              \"spec\": {
                \"evictionStrategy\": \"LiveMigrate\",
                \"domain\": {
                  \"resources\": {
                    \"requests\": {
                      \"cpu\": \"${VM_CPU_REQUEST}\",
                      \"memory\": \"${VM_MEM_REQUEST}\"
                    },
                    \"limits\": {
                      \"cpu\": \"${VM_CPU_LIMIT}\",
                      \"memory\": \"${VM_MEM_LIMIT}\"
                    }
                  }
                }
              }
            }
          }
        }"

        virtctl start "$VM" -n "$NS" 2>/dev/null || true
        print_ok "VM $VM created (cpu request: ${VM_CPU_REQUEST})"
    done

    # VM 3: demonstrate Quota exceeded
    VM3="poc-quota-vm-3"
    if oc get vm "$VM3" -n "$NS" &>/dev/null; then
        print_warn "VM $VM3 already exists — skipping Quota exceeded demonstration"
        return
    fi

    print_info ""
    print_info "━━━ Quota exceeded demonstration ━━━"
    print_info "Current requests.cpu usage: $(oc get resourcequota poc-quota -n "$NS" \
        -o jsonpath='{.status.used.requests\.cpu}' 2>/dev/null || echo '?') / 2"
    print_info "Attempting to create VM $VM3 (adding requests.cpu ${VM_CPU_REQUEST} → expected to exceed)"

    oc process -n openshift poc -p NAME="$VM3" | \
        sed 's/runStrategy: Always/runStrategy: Halted/' | sed 's/  running: false/  runStrategy: Halted/' > "${VM3}.yaml"
    echo "Generated file: ${VM3}.yaml"

    # Quota exceeded when virt-launcher pod is created → VM object is created but pod cannot start
    oc apply -n "$NS" -f "${VM3}.yaml"

    ensure_runstrategy "$VM3" "$NS"
    oc patch vm "$VM3" -n "$NS" --type=merge -p "{
      \"spec\": {
        \"template\": {
          \"spec\": {
            \"evictionStrategy\": \"LiveMigrate\",
            \"domain\": {
              \"resources\": {
                \"requests\": {
                  \"cpu\": \"${VM_CPU_REQUEST}\",
                  \"memory\": \"${VM_MEM_REQUEST}\"
                },
                \"limits\": {
                  \"cpu\": \"${VM_CPU_LIMIT}\",
                  \"memory\": \"${VM_MEM_LIMIT}\"
                }
              }
            }
          }
        }
      }
    }"

    virtctl start "$VM3" -n "$NS" 2>/dev/null || true

    print_warn "VM $VM3 object created — virt-launcher Pod will be rejected due to Quota exceeded on startup."
    print_info "  Check: oc get events -n ${NS} --field-selector reason=FailedCreate"
}

# =============================================================================
# Completion summary
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! ResourceQuota practice environment is ready.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ResourceQuota status:"
    echo -e "    ${CYAN}oc describe resourcequota poc-quota -n ${NS}${NC}"
    echo ""
    echo -e "  VM status:"
    echo -e "    ${CYAN}oc get vm -n ${NS}${NC}"
    echo ""
    echo -e "  Check Quota exceeded events:"
    echo -e "    ${CYAN}oc get events -n ${NS} --field-selector reason=FailedCreate${NC}"
    echo ""
    echo -e "  Expected results:"
    echo -e "    poc-quota-vm-1  → Running  (cpu request: ${VM_CPU_REQUEST})"
    echo -e "    poc-quota-vm-2  → Running  (cpu request: ${VM_CPU_REQUEST})"
    echo -e "    poc-quota-vm-3  → Pending  (virt-launcher Pod rejected due to Quota exceeded)"
    echo ""
    echo -e "  For details: refer to 06-resource-quota/06-resource-quota.md"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Delete 06-resource-quota resources"
    oc delete project poc-resource-quota --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-resource-quota --ignore-not-found 2>/dev/null || true
    print_ok "06-resource-quota resources deleted"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  ResourceQuota Practice Environment Setup${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_quota
    step_consoleyamlsamples
    step_vms
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
