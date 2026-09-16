#!/bin/bash
# =============================================================================
# 17-far.sh
#
# Fence Agents Remediation (FAR) lab environment setup
#   1. Create poc-far namespace
#   2. Create IPMI credentials Secret (openshift-workload-availability)
#   3. Create FenceAgentsRemediationTemplate (IPMI settings)
#   4. Create NodeHealthCheck CR (FAR integration)
#
# Usage: ./17-far.sh
# =============================================================================

set -euo pipefail
trap 'echo -e "\n\033[0;31m[ERROR]\033[0m Command failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

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

NS="poc-far"
REMEDIATION_NS="openshift-workload-availability"

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

    if [ "${FAR_INSTALLED:-false}" != "true" ]; then
        print_warn "Fence Agents Remediation Operator not installed → skipping."
        print_warn "  Installation guide: operators/far-operator.md"
        exit 77
    fi
    print_ok "Fence Agents Remediation Operator confirmed"

    if [ "${NHC_INSTALLED:-false}" != "true" ]; then
        print_warn "Node Health Check Operator not installed → skipping."
        print_warn "  Installation guide: operators/nhc-operator.md"
        exit 77
    fi
    print_ok "Node Health Check Operator confirmed"

    # Collect IPMI credentials if not already in env.conf
    load_or_ask FENCE_AGENT_USER "IPMI username" "admin"
    load_or_ask FENCE_AGENT_PASS "IPMI password" "password" "true"

    detect_worker_nodes
    NODE1="${TEST_NODE}"
    print_ok "Target node: $NODE1"

    if [ -z "${FENCE_AGENT_IPS:-}" ]; then
        echo ""
        print_info "Enter the IPMI/BMC IP address for each worker node."
        FENCE_AGENT_IPS=""
        local _ipmi_idx=1
        for _node in ${WORKER_NODES}; do
            ask "  ${_node} IPMI/BMC IP" "192.168.1.${_ipmi_idx}" _node_ipmi_ip
            FENCE_AGENT_IPS="${FENCE_AGENT_IPS:+${FENCE_AGENT_IPS} }${_node_ipmi_ip}"
            _ipmi_idx=$((_ipmi_idx + 1))
        done
        print_ok "IPMI IP list: ${FENCE_AGENT_IPS}"
        save_to_env "FENCE_AGENT_IPS" "\"${FENCE_AGENT_IPS}\""
        save_to_env "FENCE_AGENT_USER" "${FENCE_AGENT_USER}"
        save_to_env "FENCE_AGENT_PASS" "${FENCE_AGENT_PASS}"
    fi

    FENCE_AGENT_IP="${FENCE_AGENT_IPS%% *}"

    if [ -z "${FENCE_AGENT_IP:-}" ] || [ "${FENCE_AGENT_IP}" = "192.168.1.100" ]; then
        print_warn "FENCE_AGENT_IP is the default value. Please update FENCE_AGENT_IPS in env.conf with the actual BMC IP."
    else
        print_ok "FENCE_AGENT_IP: ${FENCE_AGENT_IP}"
    fi

    print_info "  NS    : ${NS}"
    print_info "  NODE1 : ${NODE1}"
    print_info "  BMC IP: ${FENCE_AGENT_IP:-not set}"
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
# Step 2: Create IPMI credentials Secret
# =============================================================================
step_secret() {
    print_step "2/4  Create IPMI Credentials Secret (ns: ${REMEDIATION_NS})"

    if oc get secret poc-far-credentials -n "${REMEDIATION_NS}" &>/dev/null; then
        print_ok "Secret poc-far-credentials already exists — skipping"
        return
    fi

    cat > far-credentials-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: poc-far-credentials
  namespace: ${REMEDIATION_NS}
stringData:
  --password: "${FENCE_AGENT_PASS:-password}"
EOF
    confirm_and_apply far-credentials-secret.yaml
    print_ok "Secret poc-far-credentials created successfully → ns: ${REMEDIATION_NS}"
}

# =============================================================================
# Step 3: Create FenceAgentsRemediationTemplate
# =============================================================================
step_far_template() {
    print_step "3/4  Create FenceAgentsRemediationTemplate"

    # Collect worker node FQDN list from cluster
    local worker_nodes
    worker_nodes=$(oc get nodes -l node-role.kubernetes.io/worker \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || \
        echo "${WORKER_NODES:-worker-0}" | tr ' ' '\n')

    if [ -z "$worker_nodes" ]; then
        worker_nodes="${WORKER_NODES:-worker-0}"
        worker_nodes=$(echo "$worker_nodes" | tr ' ' '\n')
    fi

    # Write YAML header
    cat > far-template.yaml <<EOF
apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
kind: FenceAgentsRemediationTemplate
metadata:
  annotations:
    remediation.medik8s.io/multiple-templates-support: "true"
  name: poc-far-template
  namespace: ${REMEDIATION_NS}
spec:
  template:
    spec:
      agent: fence_ipmilan
      nodeparameters:
        --ip:
EOF

    # Add per-node BMC IP entries (using env.conf FENCE_AGENT_IP as the common BMC IP)
    while IFS= read -r node; do
        [ -z "$node" ] && continue
        echo "          ${node}: ${FENCE_AGENT_IP:-192.168.1.100}" >> far-template.yaml
        print_info "  Node → BMC IP: ${node} → ${FENCE_AGENT_IP:-192.168.1.100}"
    done <<< "$worker_nodes"

    # Write remaining YAML
    cat >> far-template.yaml <<EOF
      remediationStrategy: ResourceDeletion
      retrycount: 5
      retryinterval: 5s
      sharedSecretName: poc-far-credentials
      sharedparameters:
        --action: reboot
        --lanplus: ""
        --username: ${FENCE_AGENT_USER:-admin}
      timeout: 1m0s
EOF

    confirm_and_apply far-template.yaml
    print_ok "FenceAgentsRemediationTemplate poc-far-template created successfully"
    print_info "  agent           : fence_ipmilan"
    print_info "  sharedSecretName: poc-far-credentials (contains --password)"
    print_info "  BMC IP          : ${FENCE_AGENT_IP:-192.168.1.100}"
}

# =============================================================================
# Step 3: Create NodeHealthCheck
# =============================================================================
step_nhc() {
    print_step "4/5  Create NodeHealthCheck (FAR integration)"

    cat > nhc-far.yaml <<EOF
apiVersion: remediation.medik8s.io/v1alpha1
kind: NodeHealthCheck
metadata:
  name: poc-far-nhc
spec:
  minHealthy: "51%"
  remediationTemplate:
    apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
    kind: FenceAgentsRemediationTemplate
    name: poc-far-template
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
      status: Unknown
      duration: 300s
EOF
    confirm_and_apply nhc-far.yaml
    print_ok "NodeHealthCheck poc-far-nhc created successfully"
    print_info "  Condition: Ready=False or Unknown for 300s or more → FAR triggered (IPMI reboot)"
}

# =============================================================================
# Completion summary
# =============================================================================
step_consoleyamlsamples() {
    print_step "5/5  Register ConsoleYAMLSample"

    cat > consoleyamlsample-nhc-far.yaml <<'EOF'
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-nodehealthcheck-far
spec:
  title: "POC NodeHealthCheck (FAR integration)"
  description: "Example NodeHealthCheck CR for auto-rebooting unhealthy worker nodes via IPMI using Fence Agents Remediation. FAR is triggered when Ready=False or Unknown state persists for 300 seconds."
  targetResource:
    apiVersion: remediation.medik8s.io/v1alpha1
    kind: NodeHealthCheck
  yaml: |
    apiVersion: remediation.medik8s.io/v1alpha1
    kind: NodeHealthCheck
    metadata:
      name: poc-far-nhc
    spec:
      minHealthy: "51%"
      remediationTemplate:
        apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
        kind: FenceAgentsRemediationTemplate
        name: poc-far-template
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
          status: Unknown
          duration: 300s
EOF
    oc apply -f consoleyamlsample-nhc-far.yaml
    print_ok "ConsoleYAMLSample poc-nodehealthcheck-far registered successfully"

    cat > consoleyamlsample-far-template.yaml <<'EOF'
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-fenceagentsremediationtemplate
spec:
  title: "POC FenceAgentsRemediationTemplate (IPMI)"
  description: "Example FenceAgentsRemediationTemplate for rebooting nodes via IPMI using fence_ipmilan. Configure per-node BMC IPs and shared credentials Secret."
  targetResource:
    apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
    kind: FenceAgentsRemediationTemplate
  yaml: |
    apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
    kind: FenceAgentsRemediationTemplate
    metadata:
      annotations:
        remediation.medik8s.io/multiple-templates-support: "true"
      name: poc-far-template
      namespace: openshift-workload-availability
    spec:
      template:
        spec:
          agent: fence_ipmilan
          nodeparameters:
            --ip:
              worker-0: 192.168.1.100
              worker-1: 192.168.1.101
          remediationStrategy: ResourceDeletion
          retrycount: 5
          retryinterval: 5s
          sharedSecretName: poc-far-credentials
          sharedparameters:
            --action: reboot
            --lanplus: ""
            --username: admin
          timeout: 1m0s
EOF
    oc apply -f consoleyamlsample-far-template.yaml
    print_ok "ConsoleYAMLSample poc-fenceagentsremediationtemplate registered successfully"
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! FAR lab environment is ready.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Check NHC status:"
    echo -e "    ${CYAN}oc get nodehealthcheck poc-far-nhc${NC}"
    echo ""
    echo -e "  Test IPMI connection:"
    echo -e "    ${CYAN}ipmitool -I lanplus -H ${FENCE_AGENT_IP:-<BMC_IP>} -U ${FENCE_AGENT_USER:-admin} -P <PASS> chassis power status${NC}"
    echo ""
    echo -e "  Failure simulation:"
    echo -e "    ${CYAN}oc debug node/${NODE1} -- chroot /host systemctl stop kubelet${NC}"
    echo ""
    echo -e "  Verify FAR triggered (after 300 seconds):"
    echo -e "    ${CYAN}oc get fenceagentsremediation -A${NC}"
    echo -e "    ${CYAN}oc get nodes -w${NC}"
    echo ""
    echo -e "  For details: 17-far/17-far.md"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Delete 17-far resources"
    local _rem_ns="openshift-workload-availability"
    oc delete project poc-far --ignore-not-found 2>/dev/null || true
    oc delete nodehealthcheck poc-far-nhc --ignore-not-found 2>/dev/null || true
    oc delete fenceagentsremediationtemplate poc-far-template -n "$_rem_ns" --ignore-not-found 2>/dev/null || true
    oc delete secret poc-far-credentials -n "$_rem_ns" --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-nodehealthcheck-far poc-fenceagentsremediationtemplate --ignore-not-found 2>/dev/null || true
    print_ok "17-far resources deleted successfully"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  FAR lab environment setup${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}  virt-poc ${POC_VERSION}${NC}"

    preflight
    step_namespace
    step_secret
    step_far_template
    step_nhc
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
