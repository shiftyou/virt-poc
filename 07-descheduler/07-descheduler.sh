#!/bin/bash
# =============================================================================
# 07-descheduler.sh
#
# Descheduler practice environment setup
#   1. Create poc-descheduler namespace
#   2. Deploy 3 VMs using poc template
#      - vm-1, vm-2, vm-3 : place on NODE1 via nodeSelector → remove nodeSelector after Running
#      - vm-fixed         : pin to NODE1 + exclude from descheduler eviction
#   3. KubeDescheduler — LifecycleAndUtilization / High / namespace-scoped
#   4. Analyze CPU/Memory status of TEST_NODE → calculate trigger VM resources
#   5. Deploy trigger VM on TEST_NODE → exceed node threshold → trigger Descheduler
#
# Usage: ./07-descheduler.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-load env.conf (when running standalone)
ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-descheduler"
NODE1="${TEST_NODE}"           # Uses TEST_NODE from env.conf
DESCHEDULER_NS="openshift-kube-descheduler-operator"

# Initial VM CPU request (250m each)
VM_CPU_REQUEST="250m"
VM_MEM_REQUEST="512Mi"

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

    if ! oc get node "$NODE1" &>/dev/null; then
        print_error "Node $NODE1 not found. Check TEST_NODE in env.conf."
        exit 1
    fi
    print_ok "Target node: $NODE1"

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator not installed → skipping."
        print_warn "  Installation guide: operators/kubevirt-hyperconverged-operator.md"
        exit 77
    fi
    print_ok "OpenShift Virtualization Operator confirmed"

    if [ "${DESCHEDULER_INSTALLED:-false}" != "true" ]; then
        print_warn "Kube Descheduler Operator not installed → skipping."
        print_warn "  Installation guide: operators/descheduler-operator.md"
        exit 77
    fi
    print_ok "Kube Descheduler Operator confirmed"

    print_info "  NS    : ${NS}"
    print_info "  NODE1 : ${NODE1}"
}

# =============================================================================
# Step 1: Create namespace
# =============================================================================
step_namespace() {
    print_step "1/5  Create namespace (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "Namespace $NS already exists — skipping"
    else
        oc new-project "$NS" > /dev/null
        print_ok "Namespace $NS created"
    fi
}

# =============================================================================
# Step 2: Deploy 4 VMs
# =============================================================================
step_vms() {
    print_step "2/5  Deploy 4 VMs"

    # vm-1, vm-2, vm-3: descheduler targets / vm-fixed: nodeSelector pinned + eviction excluded
    for VM in poc-descheduler-vm-1 poc-descheduler-vm-2 poc-descheduler-vm-3 poc-descheduler-vm-fixed; do
        if oc get vm "$VM" -n "$NS" &>/dev/null; then
            print_ok "VM $VM already exists — skipping"
            continue
        fi

        # Create VM from poc template
        oc process -n openshift poc -p NAME="$VM" | \
        sed 's/runStrategy: Halted/runStrategy: Always/' > "${VM}.yaml"
        echo "Generated file: ${VM}.yaml"
        oc apply -n "$NS" -f "${VM}.yaml"

        ensure_runstrategy "$VM" "$NS"

        if [ "$VM" = "poc-descheduler-vm-fixed" ]; then
            # vm-fixed: pin to NODE1 + exclude from descheduler eviction
            oc patch vm "$VM" -n "$NS" --type=merge -p "{
              \"spec\": {
                \"template\": {
                  \"metadata\": {
                    \"annotations\": {
                      \"descheduler.alpha.kubernetes.io/evict\": \"false\"
                    }
                  },
                  \"spec\": {
                    \"nodeSelector\": {\"kubernetes.io/hostname\": \"${NODE1}\"},
                    \"evictionStrategy\": \"LiveMigrate\"
                  }
                }
              }
            }"
            print_info "  → nodeSelector: ${NODE1} pinned, excluded from descheduler eviction"
            virtctl start "$VM" -n "$NS" 2>/dev/null || true
            print_ok "VM $VM deployed (nodeSelector retained)"
            continue
        fi

        # vm-1, vm-2, vm-3: place on NODE1 via nodeSelector + allow descheduler eviction
        oc patch vm "$VM" -n "$NS" --type=merge -p "{
          \"spec\": {
            \"template\": {
              \"metadata\": {
                \"annotations\": {
                  \"descheduler.alpha.kubernetes.io/evict\": \"true\"
                }
              },
              \"spec\": {
                \"nodeSelector\": {\"kubernetes.io/hostname\": \"${NODE1}\"},
                \"evictionStrategy\": \"LiveMigrate\"
              }
            }
          }
        }"
        print_info "  → nodeSelector: ${NODE1} set, descheduler eviction allowed"

        virtctl start "$VM" -n "$NS" 2>/dev/null || true
        print_ok "VM $VM deployed"

        # Wait for Running then remove nodeSelector (descheduler can freely target)
        print_info "  → Waiting for Running state then removing nodeSelector..."
        local retries=36
        local i=0
        while [ $i -lt $retries ]; do
            local phase
            phase=$(oc get vmi "$VM" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
            if [ "$phase" = "Running" ]; then
                print_ok "  VMI $VM Running"
                break
            fi
            printf "  [%d/%d] Waiting for %s... (%s)\r" "$((i+1))" "$retries" "$VM" "${phase:-Pending}"
            sleep 5
            i=$((i+1))
        done
        echo ""
        ensure_runstrategy "$VM" "$NS"
        oc patch vm "$VM" -n "$NS" --type=merge -p '{
          "spec": {
            "template": {
              "spec": {
                "nodeSelector": null
              }
            }
          }
        }'
        print_ok "  → nodeSelector removed (descheduler can freely target)"
    done
}

# =============================================================================
# Step 3: KubeDescheduler configuration (LifecycleAndUtilization / High / namespace-scoped)
# =============================================================================
step_descheduler() {
    print_step "3/5  KubeDescheduler configuration"

    # If KubeDescheduler already exists, note it was not created by this script
    if oc get kubedescheduler cluster -n openshift-kube-descheduler-operator &>/dev/null; then
        print_warn "KubeDescheduler 'cluster' already exists."
        print_warn "  → Preserving existing configuration and adding poc-descheduler namespace only."
        oc patch kubedescheduler cluster -n openshift-kube-descheduler-operator \
            --type=json \
            -p='[{"op":"add","path":"/spec/profileCustomizations/namespaces/included/-","value":"poc-descheduler"}]' \
            2>/dev/null || true
        touch .kubedescheduler-preexisted
        print_ok "poc-descheduler namespace added to existing KubeDescheduler"
        return
    fi

    cat > kubedescheduler.yaml <<'EOF'
apiVersion: operator.openshift.io/v1
kind: KubeDescheduler
metadata:
  name: cluster
  namespace: openshift-kube-descheduler-operator
spec:
  mode: Automatic
  managementState: Managed
  deschedulingIntervalSeconds: 60
  profiles:
    - LifecycleAndUtilization
  profileCustomizations:
    devLowNodeUtilizationThresholds: High
    namespaces:
      included:
        - poc-descheduler
EOF
    echo "Generated file: kubedescheduler.yaml"
    if ! oc apply -f kubedescheduler.yaml; then
        print_error "KubeDescheduler apply failed"
        exit 1
    fi

    # Verify status after apply — normal if all *Degraded conditions are False
    # (KubeDescheduler only reports *Degraded conditions, no Available condition)
    print_info "Checking KubeDescheduler status..."
    local retries=12
    local i=0
    local healthy=false
    while [ $i -lt $retries ]; do
        local degraded_true
        degraded_true=$(oc get kubedescheduler cluster \
            -n "$DESCHEDULER_NS" \
            -o jsonpath='{range .status.conditions[*]}{.type}{" "}{.status}{"\n"}{end}' \
            2>/dev/null | grep -i "Degraded" | grep "True" || true)
        if [ -z "$degraded_true" ]; then
            healthy=true
            print_ok "KubeDescheduler healthy (no Degraded conditions)"
            break
        fi
        printf "  [%d/%d] Waiting...\r" "$((i+1))" "$retries"
        sleep 5
        i=$((i+1))
    done
    echo ""

    # Print final status (TYPE / STATUS / REASON / MESSAGE)
    echo ""
    printf "  %-30s %-8s %-20s %s\n" "TYPE" "STATUS" "REASON" "MESSAGE"
    printf "  %-30s %-8s %-20s %s\n" "------------------------------" "--------" "--------------------" "-------"
    oc get kubedescheduler cluster \
        -n "$DESCHEDULER_NS" \
        -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}' \
        2>/dev/null | \
        while IFS=$'\t' read -r type status reason message; do
            printf "  %-30s %-8s %-20s %s\n" "$type" "$status" "$reason" "$message"
        done || true
    echo ""

    if [ "$healthy" != "true" ]; then
        print_warn "KubeDescheduler readiness timed out. Check the status above."
    fi

    print_info "  managementState: Managed"
    print_info "  Profile        : LifecycleAndUtilization"
    print_info "  Threshold      : High (underutilized <40%, overutilized >70%)"
    print_info "  Interval       : 60 seconds"
    print_info "  Namespace      : ${NS}"
}

# =============================================================================
# Step 5: Analyze node resources → calculate and deploy trigger VM
# =============================================================================
step_trigger_vm() {
    print_step "4/5  Deploy trigger VM (exceed node threshold)"

    print_info "Analyzing ${NODE1} resource status..."

    # Allocatable CPU → millicores
    ALLOC_CPU_RAW=$(oc get node "$NODE1" -o jsonpath='{.status.allocatable.cpu}')
    if [[ "$ALLOC_CPU_RAW" == *m ]]; then
        ALLOC_CPU="${ALLOC_CPU_RAW%m}"
    else
        ALLOC_CPU=$(awk "BEGIN{printf \"%d\", ${ALLOC_CPU_RAW}*1000}")
    fi

    # Allocatable Memory → MiB
    ALLOC_MEM_RAW=$(oc get node "$NODE1" -o jsonpath='{.status.allocatable.memory}')
    ALLOC_MEM_MIB=$(echo "$ALLOC_MEM_RAW" | awk '
        /Ki$/ { printf "%d", $0/1024; next }
        /Mi$/ { printf "%d", $0; next }
        /Gi$/ { printf "%d", $0*1024; next }
    ')

    # Sum current CPU requests on node (millicores)
    USED_CPU=$(oc get pods --all-namespaces \
        --field-selector="spec.nodeName=${NODE1}" \
        -o jsonpath='{range .items[*].spec.containers[*]}{.resources.requests.cpu}{"\n"}{end}' \
        2>/dev/null | awk '
        /^[0-9]+m$/ { sum += substr($0,1,length($0)-1); next }
        /^[0-9]+(\.[0-9]+)?$/ { sum += $0*1000; next }
        END { print int(sum) }')

    # Sum current Memory requests on node (MiB)
    USED_MEM_MIB=$(oc get pods --all-namespaces \
        --field-selector="spec.nodeName=${NODE1}" \
        -o jsonpath='{range .items[*].spec.containers[*]}{.resources.requests.memory}{"\n"}{end}' \
        2>/dev/null | awk '
        /^[0-9]+Ki$/ { sum += substr($0,1,length($0)-2)/1024; next }
        /^[0-9]+Mi$/ { sum += substr($0,1,length($0)-2); next }
        /^[0-9]+Gi$/ { sum += substr($0,1,length($0)-2)*1024; next }
        /^[0-9]+$/ { sum += $0/1048576; next }
        END { print int(sum) }')

    CPU_PCT=$((USED_CPU * 100 / ALLOC_CPU))
    MEM_PCT=$((USED_MEM_MIB * 100 / ALLOC_MEM_MIB))

    print_info "  Allocatable CPU  : ${ALLOC_CPU}m"
    print_info "  Allocatable Mem  : ${ALLOC_MEM_MIB}Mi"
    print_info "  Used CPU requests: ${USED_CPU}m  (${CPU_PCT}%)"
    print_info "  Used Mem requests: ${USED_MEM_MIB}Mi (${MEM_PCT}%)"
    print_info "  Descheduler threshold: overutilized > 70%"

    # Calculate additional CPU requests needed to exceed 71%
    THRESHOLD_CPU=$((ALLOC_CPU * 71 / 100))
    NEEDED_CPU=$((THRESHOLD_CPU - USED_CPU))

    THRESHOLD_MEM=$((ALLOC_MEM_MIB * 71 / 100))
    NEEDED_MEM=$((THRESHOLD_MEM - USED_MEM_MIB))

    if [ "$NEEDED_CPU" -le 0 ]; then
        print_warn "Already exceeding CPU 71% — deploying small trigger VM"
        TRIGGER_CPU="250m"
    else
        TRIGGER_CPU="${NEEDED_CPU}m"
    fi

    if [ "$NEEDED_MEM" -le 0 ]; then
        TRIGGER_MEM="256Mi"
    else
        TRIGGER_MEM="${NEEDED_MEM}Mi"
    fi

    print_ok "Trigger VM resources calculated"
    print_info "  TRIGGER_CPU : ${TRIGGER_CPU}  (bring node ${NODE1} CPU above 71%)"
    print_info "  TRIGGER_MEM : ${TRIGGER_MEM}"

    local TRIGGER_YAML="${SCRIPT_DIR}/poc-descheduler-vm-trigger.yaml"
    local TRIGGER_BASE="${SCRIPT_DIR}/poc-descheduler-vm-trigger-base.yaml"

    # Generate base yaml (without applying to cluster)
    oc process -n openshift poc -p NAME="poc-descheduler-vm-trigger" | \
        sed 's/runStrategy: Halted/runStrategy: Always/' > "${TRIGGER_BASE}"

    # Merge nodeSelector + evictionStrategy + resources via dry-run → save final yaml
    oc patch -f "${TRIGGER_BASE}" --dry-run=client --type=merge \
        -p "{
          \"spec\": {
            \"template\": {
              \"spec\": {
                \"nodeSelector\": {\"kubernetes.io/hostname\": \"${NODE1}\"},
                \"evictionStrategy\": \"LiveMigrate\",
                \"domain\": {
                  \"resources\": {
                    \"requests\": {
                      \"cpu\": \"${TRIGGER_CPU}\",
                      \"memory\": \"${TRIGGER_MEM}\"
                    }
                  }
                }
              }
            }
          }
        }" -o yaml > "${TRIGGER_YAML}" 2>/dev/null || mv "${TRIGGER_BASE}" "${TRIGGER_YAML}"

    rm -f "${TRIGGER_BASE}"
    echo "Generated file: ${TRIGGER_YAML}"
    print_ok "Trigger VM yaml saved — apply manually when ready:"
    print_info "  oc apply -n ${NS} -f ${TRIGGER_YAML}"
    print_info "  virtctl start poc-descheduler-vm-trigger -n ${NS}"
}

# =============================================================================
# Step 5: Register ConsoleYAMLSample
# =============================================================================
step_consoleyamlsamples() {
    print_step "5/5  Register ConsoleYAMLSample"

    cat > consoleyamlsample-kubedescheduler.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-kubedescheduler
spec:
  title: "POC KubeDescheduler Configuration"
  description: "Automatically relocates VMs from overloaded nodes using the LifecycleAndUtilization profile. High threshold: underutilized<40%, overutilized>70%. Apply after installing the Kube Descheduler Operator."
  targetResource:
    apiVersion: operator.openshift.io/v1
    kind: KubeDescheduler
  yaml: |
    apiVersion: operator.openshift.io/v1
    kind: KubeDescheduler
    metadata:
      name: cluster
      namespace: openshift-kube-descheduler-operator
    spec:
      managementState: Managed
      deschedulingIntervalSeconds: 60
      profiles:
        - LifecycleAndUtilization
      profileCustomizations:
        devLowNodeUtilizationThresholds: High
        namespaces:
          included:
            - ${NS}    # Change to target namespace
EOF
    echo "Generated file: consoleyamlsample-kubedescheduler.yaml"
    oc apply -f consoleyamlsample-kubedescheduler.yaml
    print_ok "ConsoleYAMLSample poc-kubedescheduler registered"
}

# =============================================================================
# Completion summary
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! Descheduler practice environment is ready.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Check VM node placement:"
    echo -e "    ${CYAN}oc get vmi -n ${NS} -o wide${NC}"
    echo ""
    echo -e "  Verify Descheduler operation (after 60 seconds):"
    echo -e "    ${CYAN}oc get vmi -n ${NS} -o wide --watch${NC}"
    echo ""
    echo -e "  Apply trigger VM manually (when ready):"
    echo -e "    ${CYAN}oc apply -n ${NS} -f ${SCRIPT_DIR}/poc-descheduler-vm-trigger.yaml${NC}"
    echo -e "    ${CYAN}virtctl start poc-descheduler-vm-trigger -n ${NS}${NC}"
    echo ""
    echo -e "  Expected results (within 60 seconds after trigger VM applied):"
    echo -e "    poc-descheduler-vm-1       → Migrated to another node"
    echo -e "    poc-descheduler-vm-2       → Migrated to another node"
    echo -e "    poc-descheduler-vm-3       → Migrated to another node"
    echo -e "    poc-descheduler-vm-fixed   → Stays on ${NODE1} (eviction excluded)"
    echo -e "    poc-descheduler-vm-trigger → Stays on ${NODE1} (most recently deployed)"
    echo ""
    echo -e "  For details: refer to 07-descheduler/07-descheduler.md"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Delete 07-descheduler resources"
    oc delete project poc-descheduler --ignore-not-found 2>/dev/null || true

    local _pre="${SCRIPT_DIR}/.kubedescheduler-preexisted"
    if [ -f "$_pre" ]; then
        # Already existed before this script ran — only remove poc-descheduler entry
        print_info "KubeDescheduler was pre-existing — not deleting."
        print_info "  → Removing only the poc-descheduler namespace entry."
        local _idx
        _idx=$(oc get kubedescheduler cluster -n openshift-kube-descheduler-operator \
            -o json 2>/dev/null | \
            python3 -c "import json,sys; d=json.load(sys.stdin); \
                ns=d['spec'].get('profileCustomizations',{}).get('namespaces',{}).get('included',[]); \
                print(ns.index('poc-descheduler') if 'poc-descheduler' in ns else -1)" 2>/dev/null || echo -1)
        if [ "$_idx" != "-1" ] && [ "$_idx" != "" ]; then
            oc patch kubedescheduler cluster -n openshift-kube-descheduler-operator \
                --type=json \
                -p="[{\"op\":\"remove\",\"path\":\"/spec/profileCustomizations/namespaces/included/${_idx}\"}]" \
                2>/dev/null && print_ok "poc-descheduler entry removed" || true
        fi
        rm -f "$_pre"
    else
        oc delete kubedescheduler cluster -n openshift-kube-descheduler-operator --ignore-not-found 2>/dev/null || true
    fi

    oc delete consoleyamlsample poc-kubedescheduler --ignore-not-found 2>/dev/null || true
    print_ok "07-descheduler resources deleted"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Descheduler Practice Environment Setup${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_vms
    step_descheduler
    step_trigger_vm
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
