#!/bin/bash
# =============================================================================
# 15-node-maintenance.sh
#
# Node Maintenance lab environment setup
#   1. Create poc-maintenance namespace
#   2. Deploy 2 VMs using poc template → consolidate on TEST_NODE via Live Migration
#   3. Create NodeMaintenance → cordon + drain → verify VM auto-Migration
#
# Usage: ./15-node-maintenance.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-load env.conf (when running standalone)
ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-maintenance"

source "${SCRIPT_DIR}/../utils/common.sh"

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

    if ! oc get template poc -n openshift &>/dev/null; then
        print_error "poc Template not found. Please run 01-template first."
        exit 1
    fi
    print_ok "poc Template confirmed"

    detect_worker_nodes
    NODE1="${TEST_NODE}"
    print_ok "Target node: $NODE1"

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator not installed → skipping."
        print_warn "  Installation guide: operators/kubevirt-hyperconverged-operator.md"
        exit 77
    fi
    print_ok "OpenShift Virtualization Operator confirmed"

    # Check Node Maintenance Operator installation (env.conf: NMO_INSTALLED)
    if [ "${NMO_INSTALLED:-false}" != "true" ]; then
        if ! oc get csv -A 2>/dev/null | grep -qi "node-maintenance"; then
            print_warn "Node Maintenance Operator not installed → skipping."
            print_warn "  Installation guide: operators/node-maintenance-operator.md"
            exit 77
        fi
    fi
    print_ok "Node Maintenance Operator confirmed"

    # Verify at least 2 worker nodes
    local worker_count
    worker_count=$(oc get node -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$worker_count" -lt 2 ]; then
        print_error "At least 2 worker nodes are required. (Current: ${worker_count})"
        exit 1
    fi
    print_ok "Worker nodes: ${worker_count} confirmed"

    print_info "  NS    : ${NS}"
    print_info "  NODE1 : ${NODE1}"
}

# =============================================================================
# Step 1: Create namespace
# =============================================================================
step_namespace() {
    print_step "1/3  Create namespace (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "Namespace $NS already exists — skipping"
    else
        oc new-project "$NS" > /dev/null
        print_ok "Namespace $NS created successfully"
    fi
}

# =============================================================================
# Step 2: Deploy 2 VMs → Live Migration to TEST_NODE
# =============================================================================
step_vms() {
    print_step "2/4  Deploy 2 VMs → Live Migration to ${NODE1}"

    for VM in poc-maintenance-vm-1 poc-maintenance-vm-2; do
        if oc get vm "$VM" -n "$NS" &>/dev/null; then
            print_ok "VM $VM already exists — skipping"
            continue
        fi

        oc process -n openshift poc -p NAME="$VM" | \
        sed 's/runStrategy: Always/runStrategy: Halted/' | sed 's/  running: false/  runStrategy: Halted/' > "${VM}.yaml"
        echo "Generated file: ${VM}.yaml"
        oc apply -n "$NS" -f "${VM}.yaml"

        # Set evictionStrategy: LiveMigrate
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
        print_ok "VM $VM deployed successfully"
    done

    # Wait for Running state
    print_info "Waiting for VM Running state..."
    for VM in poc-maintenance-vm-1 poc-maintenance-vm-2; do
        local retries=36
        local i=0
        while [ $i -lt $retries ]; do
            local phase
            phase=$(oc get vmi "$VM" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
            if [ "$phase" = "Running" ]; then
                print_ok "VMI $VM Running"
                break
            fi
            printf "  [%d/%d] Waiting for %s... (%s)\r" "$((i+1))" "$retries" "$VM" "${phase:-Pending}"
            sleep 5
            i=$((i+1))
        done
        echo ""
    done

    # Live Migration to TEST_NODE
    for VM in poc-maintenance-vm-1 poc-maintenance-vm-2; do
        local current_node
        current_node=$(oc get vmi "$VM" -n "$NS" -o jsonpath='{.status.nodeName}' 2>/dev/null || true)

        if [ "$current_node" = "$NODE1" ]; then
            print_ok "VM $VM is already on ${NODE1} — skipping Migration"
            continue
        fi

        print_info "Starting VM $VM Migration: ${current_node} → ${NODE1}"

        # Temporarily set nodeSelector
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
        echo "Generated file: vmim-${VM}.yaml"
        print_info "  Apply directly with the following command:"
        echo -e "    ${CYAN}oc apply -f vmim-${VM}.yaml${NC}"
    done

    echo ""
    print_info "Current VM placement:"
    oc get vmi -n "$NS" \
      -o custom-columns=NAME:.metadata.name,NODE:.status.nodeName,PHASE:.status.phase \
      2>/dev/null || true
}

# =============================================================================
# Step 3: Create NodeMaintenance → Verify Migration
# =============================================================================
step_consoleyamlsamples() {
    print_step "4/4  Register ConsoleYAMLSample"

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
    print_ok "ConsoleYAMLSample poc-nodemaintenance registered successfully"
}

step_maintenance() {
    print_step "3/4  Create NodeMaintenance (${NODE1})"

    if oc get nodemaintenance "maintenance-${NODE1}" &>/dev/null; then
        print_ok "NodeMaintenance maintenance-${NODE1} already exists — skipping"
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
    echo "Generated file: nodemaintenance-${NODE1}.yaml"
    print_ok "NodeMaintenance YAML generated successfully (not applied)"
    print_info "Apply directly with the following command:"
    echo -e "    ${CYAN}oc apply -f nodemaintenance-${NODE1}.yaml${NC}"
}

# =============================================================================
# Completion summary
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! Node Maintenance lab environment is ready.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Verify VM migration:"
    echo -e "    ${CYAN}oc get vmi -n ${NS} -o wide${NC}"
    echo ""
    echo -e "  NodeMaintenance status:"
    echo -e "    ${CYAN}oc get nodemaintenance${NC}"
    echo ""
    echo -e "  End maintenance (recover node):"
    echo -e "    ${CYAN}oc delete nodemaintenance maintenance-${NODE1}${NC}"
    echo ""
    echo -e "  For details: 15-node-maintenance/15-node-maintenance.md"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Delete 15-node-maintenance resources"
    oc delete project poc-maintenance --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-nodemaintenance --ignore-not-found 2>/dev/null || true
    print_ok "15-node-maintenance resources deleted successfully"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Node Maintenance lab environment setup${NC}"
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
