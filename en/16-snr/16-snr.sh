#!/bin/bash
# =============================================================================
# 16-snr.sh
#
# Self Node Remediation (SNR) lab environment setup
#   1. Create poc-snr namespace
#   2. Create SelfNodeRemediationTemplate
#   3. Create NodeHealthCheck CR (SNR integration)
#   4. Deploy 2 VMs using poc template → place on TEST_NODE
#
# Usage: ./16-snr.sh
# =============================================================================

set -euo pipefail
trap '[[ "$BASH_COMMAND" =~ ^(oc|kubectl|virtctl) ]] && echo "+ $BASH_COMMAND"' DEBUG
trap 'echo -e "\n\033[0;31m[ERROR]\033[0m Command failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-snr"
REMEDIATION_NS="openshift-workload-availability"

if [ -f "${SCRIPT_DIR}/../utils/common.sh" ]; then
    source "${SCRIPT_DIR}/../utils/common.sh"
else
    # ── standalone mode: inline common helpers ──
    RED='\033[0;31m'; GREEN='\033[0;32m'; DIM='\033[2m'
    POC_VERSION=$(cat "${SCRIPT_DIR}/../../VERSION" 2>/dev/null || echo "dev")
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

    detect_worker_nodes
    NODE1="${TEST_NODE}"
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
        print_info "Creating Namespace $NS..."
        oc new-project "$NS" > /dev/null
        if oc get namespace "$NS" &>/dev/null; then
            print_ok "Namespace $NS created"
        else
            print_error "Failed to create Namespace $NS"
            return 1
        fi
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
    print_info "Creating SelfNodeRemediationTemplate poc-snr-template..."
    confirm_and_apply snr-template.yaml
    if oc get selfnoderemediationtemplate poc-snr-template -n "$REMEDIATION_NS" &>/dev/null; then
        print_ok "SelfNodeRemediationTemplate poc-snr-template created"
    else
        print_error "Failed to create SelfNodeRemediationTemplate poc-snr-template"
        return 1
    fi
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
    print_info "Creating NodeHealthCheck poc-snr-nhc..."
    confirm_and_apply nhc-snr.yaml
    if oc get nodehealthcheck poc-snr-nhc &>/dev/null; then
        print_ok "NodeHealthCheck poc-snr-nhc created"
    else
        print_error "Failed to create NodeHealthCheck poc-snr-nhc"
        return 1
    fi
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
    print_info "Registering ConsoleYAMLSample poc-nodehealthcheck-snr..."
    oc apply -f consoleyamlsample-nhc-snr.yaml
    if oc get consoleyamlsample poc-nodehealthcheck-snr &>/dev/null; then
        print_ok "ConsoleYAMLSample poc-nodehealthcheck-snr registered"
    else
        print_error "Failed to register ConsoleYAMLSample poc-nodehealthcheck-snr"
        return 1
    fi
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

        print_info "Deploying VM $VM..."
        virtctl start "$VM" -n "$NS" 2>/dev/null || true
        print_ok "VM $VM deployed (node: ${NODE1})"
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
    echo -e "  For details: 16-snr/16-snr.md"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Delete 16-snr resources"
    local _rem_ns="openshift-workload-availability"

    print_info "Deleting Project poc-snr..."
    oc delete project poc-snr --ignore-not-found 2>/dev/null || true
    if ! oc get namespace poc-snr &>/dev/null; then
        print_ok "Project poc-snr deleted"
    else
        print_warn "Project poc-snr still deleting (background)"
    fi

    print_info "Deleting NodeHealthCheck poc-snr-nhc..."
    oc delete nodehealthcheck poc-snr-nhc --ignore-not-found 2>/dev/null || true
    if ! oc get nodehealthcheck poc-snr-nhc &>/dev/null; then
        print_ok "NodeHealthCheck poc-snr-nhc deleted"
    else
        print_warn "Failed to delete NodeHealthCheck poc-snr-nhc"
    fi

    print_info "Deleting SelfNodeRemediationTemplate poc-snr-template..."
    oc delete selfnoderemediationtemplate poc-snr-template -n "$_rem_ns" --ignore-not-found 2>/dev/null || true
    if ! oc get selfnoderemediationtemplate poc-snr-template -n "$_rem_ns" &>/dev/null; then
        print_ok "SelfNodeRemediationTemplate poc-snr-template deleted"
    else
        print_warn "Failed to delete SelfNodeRemediationTemplate poc-snr-template"
    fi

    print_info "Deleting ConsoleYAMLSample poc-nodehealthcheck-snr..."
    oc delete consoleyamlsample poc-nodehealthcheck-snr --ignore-not-found 2>/dev/null || true
    if ! oc get consoleyamlsample poc-nodehealthcheck-snr &>/dev/null; then
        print_ok "ConsoleYAMLSample poc-nodehealthcheck-snr deleted"
    else
        print_warn "Failed to delete ConsoleYAMLSample poc-nodehealthcheck-snr"
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  SNR lab environment setup${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}  virt-poc ${POC_VERSION}${NC}"

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
