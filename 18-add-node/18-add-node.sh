#!/bin/bash
# =============================================================================
# 17-add-node.sh
#
# Worker Node Removal and Rejoin Lab
#   1. Identify target node (last worker node)
#   2. Cordon + Drain (including VMs)
#   3. Stop kubelet → Node NotReady → Delete node object
#   4. Restart kubelet → Approve CSR → Verify node rejoin
#   5. Uncordon + Final state verification
#
# Usage: ./17-add-node.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

print_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }
print_ok()    { echo -e "  ${GREEN}✔ $1${NC}"; }
print_warn()  { echo -e "  ${YELLOW}⚠ $1${NC}"; }
print_info()  { echo -e "  ${BLUE}ℹ $1${NC}"; }
print_error() { echo -e "  ${RED}✘ $1${NC}"; }
print_cmd()   { echo -e "  ${CYAN}$ $1${NC}"; }

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
}

# =============================================================================
step_identify() {
    print_step "1/5  Node Status Check"

    echo ""
    oc get nodes -o wide
    echo ""

    local node_ip
    node_ip=$(oc get node "$TARGET_NODE" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

    print_info "Target node : ${TARGET_NODE}"
    print_info "Node IP     : ${node_ip}"
    print_info "SSH access  : ssh core@${node_ip}"
    echo ""
    print_warn "This node will be removed from the cluster and rejoined by restarting kubelet."
    echo ""
    read -r -p "  Do you want to continue? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Cancelled."
        exit 0
    fi
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
    echo -e "  For more details, refer to: 16-add-node.md"
    echo ""
}

# =============================================================================
main() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  16-add-node: Worker Node Removal and Rejoin Lab${NC}"
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
