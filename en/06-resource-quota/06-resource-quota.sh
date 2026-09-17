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
trap '[[ "$BASH_COMMAND" =~ ^(oc|kubectl|virtctl) ]] && echo "+ $BASH_COMMAND"' DEBUG
trap 'echo -e "\n\033[0;31m[ERROR]\033[0m Command failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-load env.conf (when running standalone)
ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-resource-quota"

# VM/Quota resources
VM_CPU_REQUEST_M=750
VM_MEM_REQUEST_MI=1024
VM_CPU_REQUEST="750m"
VM_CPU_LIMIT="1500m"
VM_MEM_REQUEST="1Gi"
VM_MEM_LIMIT="2Gi"
QUOTA_CPU_REQUEST="2000m"
QUOTA_CPU_LIMIT="5"
QUOTA_MEM_REQUEST="4Gi"
QUOTA_MEM_LIMIT="8Gi"

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
    auto_detect_operators

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
        print_info "Namespace $NS creating..."
        oc new-project "$NS" > /dev/null
        if oc get namespace "$NS" &>/dev/null; then
            print_ok "Namespace $NS created"
        else
            print_error "Namespace $NS creation failed"
            return 1
        fi
    fi
}

# =============================================================================
# Step 2: Apply ResourceQuota (values from detect_node_resources)
# =============================================================================
step_quota() {
    print_step "2/4  Apply ResourceQuota (${NS})"

    cat > resourcequota-poc.yaml <<EOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: poc-quota
  namespace: ${NS}
spec:
  hard:
    pods: "10"
    requests.cpu: "${QUOTA_CPU_REQUEST}"
    limits.cpu: "${QUOTA_CPU_LIMIT}"
    requests.memory: ${QUOTA_MEM_REQUEST}
    limits.memory: ${QUOTA_MEM_LIMIT}
    persistentvolumeclaims: "10"
    requests.storage: 100Gi
    services: "10"
    services.loadbalancers: "2"
    services.nodeports: "0"
    configmaps: "20"
    secrets: "20"
EOF
    echo "Generated file: resourcequota-poc.yaml"
    print_info "ResourceQuota poc-quota applying..."
    oc apply -f resourcequota-poc.yaml

    print_ok "ResourceQuota poc-quota applied"
    print_info "  requests.cpu: ${QUOTA_CPU_REQUEST} (2 VMs × ${VM_CPU_REQUEST} = $(( VM_CPU_REQUEST_M * 2 ))m pass, 3 VMs = $(( VM_CPU_REQUEST_M * 3 ))m exceed)"
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
        requests.cpu: "2000m"
        limits.cpu: "5"
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
    print_info "ConsoleYAMLSample poc-resource-quota registering..."
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

        print_info "VM $VM creating..."
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
    echo -e "  Quota vs VM Resource Usage:"
    echo ""
    printf "    %-18s %10s %10s %10s %10s   %s\n" "Item" "Quota" "VM x1" "VM x2" "VM x3" "Result"
    echo "    ──────────────────────────────────────────────────────────────────────────"
    printf "    %-18s %10s %10s %10s %10s   ${RED}%s${NC}\n" "requests.cpu" "${QUOTA_CPU_REQUEST}" "${VM_CPU_REQUEST}" "$(( VM_CPU_REQUEST_M * 2 ))m" "$(( VM_CPU_REQUEST_M * 3 ))m" "3rd EXCEEDED"
    printf "    %-18s %10s %10s %10s %10s   ${GREEN}%s${NC}\n" "limits.cpu" "${QUOTA_CPU_LIMIT}" "${VM_CPU_LIMIT}" "$(( ${VM_CPU_LIMIT%m} * 2 ))m" "$(( ${VM_CPU_LIMIT%m} * 3 ))m" "OK"
    printf "    %-18s %10s %10s %10s %10s   ${GREEN}%s${NC}\n" "requests.memory" "${QUOTA_MEM_REQUEST}" "${VM_MEM_REQUEST}" "2Gi" "3Gi" "OK"
    printf "    %-18s %10s %10s %10s %10s   ${GREEN}%s${NC}\n" "limits.memory" "${QUOTA_MEM_LIMIT}" "${VM_MEM_LIMIT}" "4Gi" "6Gi" "OK"
    echo ""
    echo -e "  Expected results:"
    echo -e "    poc-quota-vm-1  → ${GREEN}Running${NC}  (requests.cpu ${VM_CPU_REQUEST})"
    echo -e "    poc-quota-vm-2  → ${GREEN}Running${NC}  (requests.cpu total $(( VM_CPU_REQUEST_M * 2 ))m < ${QUOTA_CPU_REQUEST})"
    echo -e "    poc-quota-vm-3  → ${RED}Pending${NC}  (requests.cpu total $(( VM_CPU_REQUEST_M * 3 ))m > ${QUOTA_CPU_REQUEST})"
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
    echo -e "${DIM}  virt-poc ${POC_VERSION}${NC}"

    preflight
    step_namespace
    step_quota
    step_consoleyamlsamples
    step_vms
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
