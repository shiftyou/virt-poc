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
trap 'echo -e "\n\033[0;31m[ERROR]\033[0m Command failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-load env.conf (when running standalone)
ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-maintenance"

if [ -f "${SCRIPT_DIR}/../utils/common.sh" ]; then
    source "${SCRIPT_DIR}/../utils/common.sh"
else
    # ── standalone mode: inline common helpers ──
    RED='\033[0;31m'; GREEN='\033[0;32m'; DIM='\033[2m'
    YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
    print_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
    print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
    print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
    print_error() { echo -e "${RED}[ERR ]${NC} $1"; }
    print_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }
    print_header() {
        echo -e "\n${CYAN}================================================================${NC}"
        echo -e "${CYAN}  $1${NC}"
        echo -e "${CYAN}================================================================${NC}\n"
    }
    print_step_header() {
        echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}  $1  $2${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    }
    ask() {
        local prompt="$1" default="$2" var_name="$3" is_secret="${4:-false}"
        if [ "$is_secret" = "true" ]; then
            echo -n -e "${YELLOW}  $prompt${NC} [default: ****]: "; read -s input_val; echo
        else
            echo -n -e "${YELLOW}  $prompt${NC} [default: ${default}]: "; read input_val
        fi
        [ -z "$input_val" ] && input_val="$default"
        eval "$var_name='$input_val'"
    }
    save_to_env() {
        local key="$1" value="$2" env_file="${3:-${ENV_FILE:-}}"
        [ -z "$env_file" ] || [ ! -f "$env_file" ] && return 0
        if grep -q "^${key}=" "$env_file" 2>/dev/null; then
            if [[ "$OSTYPE" == darwin* ]]; then sed -i '' "s|^${key}=.*|${key}=${value}|" "$env_file"
            else sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"; fi
        else echo "${key}=${value}" >> "$env_file"; fi
    }
    load_or_ask() {
        local var_name="$1" prompt="$2" default="$3" is_secret="${4:-false}" current_val
        eval "current_val=\${${var_name}:-}"; [ -n "$current_val" ] && return 0
        ask "$prompt" "$default" "$var_name" "$is_secret"
        eval "local _val=\$$var_name"; save_to_env "$var_name" "$_val"
    }
    confirm_and_apply() {
        local file="$1" auto="${2:-true}"
        if [ "$auto" != "true" ]; then
            print_info "YAML to apply:"; cat "$file"
            read -r -p "Apply this YAML to the cluster? [y/N]: " confirm
            [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { print_warn "Cancelled."; return 1; }
        fi
        oc apply -f "$file"
    }
    detect_worker_nodes() {
        WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        TEST_NODE=$(echo "$WORKER_NODES" | awk '{print $1}')
        [ -z "$WORKER_NODES" ] && { print_error "No worker nodes found."; exit 1; }
        print_info "Worker nodes: ${WORKER_NODES}"
    }
    auto_detect_garage() {
        GARAGE_ENDPOINT=""; GARAGE_BUCKET="velero"; GARAGE_ACCESS_KEY="garage"
        GARAGE_SECRET_KEY="garage123"; GARAGE_FOUND=false
        local ns; ns=$(oc get svc -A -l app=garage -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
        if [ -n "$ns" ]; then
            local svc port
            svc=$(oc get svc -n "$ns" -l app=garage -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
                oc get svc -n "$ns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
            port=$(oc get svc -n "$ns" "$svc" -o jsonpath='{.spec.ports[?(@.name=="s3-api")].port}' 2>/dev/null || echo "3900")
            GARAGE_ENDPOINT="http://${svc}.${ns}.svc.cluster.local:${port}"
            local sn; sn=$(oc get secret -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
                tr ' ' '\n' | grep -iE "garage|credentials|s3" | head -1 || true)
            if [ -n "$sn" ]; then
                local ak sk
                ak=$(oc get secret -n "$ns" "$sn" -o jsonpath='{.data.accessKey}' 2>/dev/null | base64 -d 2>/dev/null || \
                    oc get secret -n "$ns" "$sn" -o jsonpath='{.data.access_key_id}' 2>/dev/null | base64 -d 2>/dev/null || true)
                sk=$(oc get secret -n "$ns" "$sn" -o jsonpath='{.data.secretKey}' 2>/dev/null | base64 -d 2>/dev/null || \
                    oc get secret -n "$ns" "$sn" -o jsonpath='{.data.secret_access_key}' 2>/dev/null | base64 -d 2>/dev/null || true)
                [ -n "$ak" ] && GARAGE_ACCESS_KEY="$ak"; [ -n "$sk" ] && GARAGE_SECRET_KEY="$sk"
            fi
            GARAGE_FOUND=true
            print_info "Garage endpoint : ${GARAGE_ENDPOINT}  (ns: ${ns})"
            print_info "Garage bucket   : ${GARAGE_BUCKET}"
            print_info "Garage accessKey: ${GARAGE_ACCESS_KEY}"
        else print_warn "Garage Service (app=garage) not detected — skipping Garage config."; fi
    }
    auto_detect_operators() { :; }
    auto_detect_odf() {
        ODF_S3_ENDPOINT=""; ODF_S3_BUCKET="velero"; ODF_S3_REGION="localstorage"
        ODF_S3_ACCESS_KEY=""; ODF_S3_SECRET_KEY=""
        local ns="openshift-storage"
        ODF_S3_ENDPOINT=$(oc get noobaa -n "$ns" -o jsonpath='{.status.services.serviceS3.internalDNS[0]}' 2>/dev/null || true)
        if [ -z "$ODF_S3_ENDPOINT" ]; then
            local p; p=$(oc get svc s3 -n "$ns" -o jsonpath='{.spec.ports[?(@.name=="s3")].port}' 2>/dev/null || echo "80")
            ODF_S3_ENDPOINT="http://s3.${ns}.svc.cluster.local:${p}"
        fi
        ODF_S3_ACCESS_KEY=$(oc get secret noobaa-admin -n "$ns" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d 2>/dev/null || true)
        ODF_S3_SECRET_KEY=$(oc get secret noobaa-admin -n "$ns" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)
        if [ -n "$ODF_S3_ACCESS_KEY" ]; then
            print_info "ODF MCG S3 endpoint : ${ODF_S3_ENDPOINT}"
            print_info "ODF MCG region      : ${ODF_S3_REGION}"
            print_info "ODF MCG bucket      : ${ODF_S3_BUCKET}"
            print_info "ODF MCG credentials : from noobaa-admin secret"
        else print_warn "ODF MCG credentials not detected (no noobaa-admin secret)"; fi
    }
fi

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
    auto_detect_operators

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
