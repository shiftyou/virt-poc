#!/bin/bash
# =============================================================================
# 18-add-node.sh
#
# Worker Node Removal and Rejoin Lab
#   1. Identify target node (last worker node)
#   2. Cordon + Drain (including VMs)
#   3. Stop kubelet → Node NotReady → Delete node object
#   4. Restart kubelet → Approve CSR → Verify node rejoin
#   5. Uncordon + Final state verification
#
# Usage: ./18-add-node.sh
# =============================================================================

set -euo pipefail

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

TARGET_NODE=""

# =============================================================================
preflight() {
    print_step "Pre-flight Check"

    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to OpenShift."
        exit 1
    fi
    print_ok "Cluster access: $(oc whoami) @ $(oc whoami --show-server)"

    local worker_count
    worker_count=$(oc get nodes -l node-role.kubernetes.io/worker \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [ "$worker_count" -lt 2 ]; then
        print_error "At least 2 worker nodes are required. (Current: ${worker_count})"
        print_info "There must be a node available to accommodate remaining workloads when removing a node."
        exit 1
    fi
    print_ok "${worker_count} worker nodes confirmed"
}

# =============================================================================
step_identify() {
    print_step "1/5  Node Status Check"

    echo ""
    oc get nodes -o wide
    echo ""

    print_warn "A worker node will be removed from the cluster and rejoined by restarting kubelet."
    echo ""
    read -r -p "  Do you want to continue? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Cancelled."
        exit 0
    fi

    # Display worker node list and prompt for selection
    local workers
    workers=()
    while IFS= read -r line; do
        workers+=("$line")
    done < <(oc get nodes -l node-role.kubernetes.io/worker \
        --no-headers -o custom-columns=NAME:.metadata.name | sort)

    echo ""
    print_info "Worker node list:"
    echo ""
    local idx=1
    for node in "${workers[@]}"; do
        local node_status
        node_status=$(oc get node "$node" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        [ "$node_status" = "True" ] && node_status="${GREEN}Ready${NC}" || node_status="${YELLOW}NotReady${NC}"
        printf "    ${CYAN}[%d]${NC}  %-40s  " "$idx" "$node"
        echo -e "$node_status"
        idx=$((idx+1))
    done
    echo ""

    local choice
    read -r -p "  Select the node number to remove [1-${#workers[@]}]: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#workers[@]}" ]; then
        print_error "Invalid selection: ${choice}"
        exit 1
    fi

    TARGET_NODE="${workers[$((choice-1))]}"
    print_ok "Selected target node: ${TARGET_NODE}"

    local node_ip
    node_ip=$(oc get node "$TARGET_NODE" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

    print_info "Target node : ${TARGET_NODE}"
    print_info "Node IP     : ${node_ip}"
    print_info "SSH access  : ssh core@${node_ip}"
}

# =============================================================================
step_drain() {
    print_step "2/5  Cordon + Drain (${TARGET_NODE})"

    print_info "Changing node to Unschedulable state..."
    oc adm cordon "$TARGET_NODE"
    print_ok "Cordon complete"

    print_info "Moving Pods/VMs on the node to other nodes..."
    oc adm drain "$TARGET_NODE" \
        --delete-emptydir-data \
        --ignore-daemonsets \
        --force \
        --timeout=300s
    print_ok "Drain complete"

    echo ""
    oc get nodes
}

# =============================================================================
step_stop_kubelet() {
    print_step "3/5  Stop kubelet → Delete node object"

    local node_ip
    node_ip=$(oc get node "$TARGET_NODE" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

    echo ""
    print_info "Run the following commands on the node to stop kubelet:"
    echo ""
    echo -e "  ${CYAN}ssh core@${node_ip}${NC}"
    echo -e "  ${CYAN}sudo systemctl stop kubelet${NC}"
    echo ""
    print_warn "Stopping kubelet will transition the node to NotReady state."
    echo ""
    read -r -p "  Press Enter once kubelet has been stopped..."

    # Wait for NotReady
    print_info "Waiting for node to transition to NotReady state..."
    local retries=30
    local i=0
    while [ "$i" -lt "$retries" ]; do
        local status
        status=$(oc get node "$TARGET_NODE" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "$status" = "False" ] || [ "$status" = "Unknown" ]; then
            echo ""
            print_ok "Node ${TARGET_NODE} → NotReady"
            break
        fi
        printf "  Waiting... (%d/%d)\r" "$((i+1))" "$retries"
        sleep 5
        i=$((i+1))
    done
    echo ""

    oc get nodes
    echo ""

    # Delete node object
    print_info "Deleting node object from the cluster..."
    oc delete node "$TARGET_NODE"
    print_ok "Node object deletion complete — removed from cluster"
    echo ""
    oc get nodes
}

# =============================================================================
step_start_kubelet() {
    print_step "4/5  Restart kubelet → Node rejoin"

    local node_ip
    # Node object has been deleted, reuse previously saved IP
    node_ip=$(oc get node "$TARGET_NODE" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null \
        || echo "<node-ip>")

    echo ""
    print_info "Run the following commands on the node to restart kubelet:"
    echo ""
    echo -e "  ${CYAN}ssh core@${node_ip:-<node-ip>}${NC}"
    echo -e "  ${CYAN}sudo systemctl start kubelet${NC}"
    echo ""
    print_info "Once kubelet starts, it will re-register with the API server using the existing certificate."
    print_info "When CSR (Certificate Signing Request) is generated, you must approve it manually."
    echo ""
    read -r -p "  Press Enter once kubelet has been started..."

    # Manual CSR approval guidance (wait up to 3 minutes)
    print_info "Waiting for CSR generation and node rejoin (up to 3 minutes)..."
    local retries=36
    local i=0
    local last_pending=""
    while [ "$i" -lt "$retries" ]; do
        local pending_csrs
        pending_csrs=$(oc get csr --no-headers 2>/dev/null \
            | awk '$4 ~ /Pending/ || $NF ~ /Pending/ {print $1}' \
            | tr '\n' ' ' | xargs || true)

        # Only display guidance when new Pending CSRs appear
        if [ -n "$pending_csrs" ] && [ "$pending_csrs" != "$last_pending" ]; then
            echo ""
            print_warn "There are CSRs pending approval:"
            echo ""
            oc get csr
            echo ""
            print_info "Approve the CSR with the following command:"
            echo ""
            echo -e "  ${CYAN}oc adm certificate approve ${pending_csrs}${NC}"
            echo ""
            echo -e "  Or approve all Pending at once:"
            echo -e "  ${CYAN}oc get csr -o name | xargs oc adm certificate approve${NC}"
            echo ""
            read -r -p "  Press Enter after approving the CSR..."
            last_pending="$pending_csrs"
        fi

        # Check if node is in Ready state
        if oc get node "$TARGET_NODE" &>/dev/null; then
            local status
            status=$(oc get node "$TARGET_NODE" \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
            if [ "$status" = "True" ]; then
                echo ""
                print_ok "Node ${TARGET_NODE} → Ready"
                break
            fi
        fi

        printf "  Waiting for node rejoin... (%d/%d)\r" "$((i+1))" "$retries"
        sleep 5
        i=$((i+1))
    done
    echo ""

    oc get nodes
}

# =============================================================================
step_verify() {
    print_step "5/5  Uncordon + Final Verification"

    if oc get node "$TARGET_NODE" &>/dev/null; then
        oc adm uncordon "$TARGET_NODE"
        print_ok "Uncordon complete — restored to schedulable state"
    else
        print_warn "Node is not yet registered. Manual uncordon may be required:"
        print_cmd "oc adm uncordon ${TARGET_NODE}"
    fi

    echo ""
    oc get nodes -o wide
}

# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! Node rejoin lab is complete.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Final node status:"
    echo -e "    ${CYAN}oc get nodes${NC}"
    echo ""
    echo -e "  Check CSR status:"
    echo -e "    ${CYAN}oc get csr${NC}"
    echo ""
    echo -e "  For more details, refer to: 18-add-node/18-add-node.md"
    echo ""
}

# =============================================================================
main() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  18-add-node: Worker Node Removal and Rejoin Lab${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_identify
    step_drain
    step_stop_kubelet
    step_start_kubelet
    step_verify
    print_summary
}

main "$@"
