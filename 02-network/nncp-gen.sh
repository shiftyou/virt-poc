#!/bin/bash
# =============================================================================
# nncp-gen.sh
#
# NNCP (NodeNetworkConfigurationPolicy) generation script
# Creates NNCP for 2 network methods and applies it to the cluster.
#
#   1. Linux Bridge          — NMState NNCP (linux-bridge)
#   2. Linux Bridge + VLAN   — NMState NNCP (linux-bridge trunk port)
#
# Usage: ./nncp-gen.sh <NET_TYPE>
#   NET_TYPE: 1=Linux Bridge, 2=Linux Bridge+VLAN
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

BRIDGE_INTERFACE="${BRIDGE_INTERFACE:-ens4}"
BRIDGE_NAME="${BRIDGE_NAME:-br1}"
VLAN_ID="${VLAN_ID:-}"
MTU="${MTU:-}"
NNCP_NAME="${NNCP_NAME:-poc-bridge-nncp}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

print_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

# =============================================================================
# Wait for NNCP application to complete
# =============================================================================
_wait_nncp() {
    local name="$1"
    print_info "NNCP applied — waiting for node configuration propagation..."
    local retries=24 i=0
    while [ "$i" -lt "$retries" ]; do
        local status reason
        status=$(oc get nncp "$name" \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
        if [ "$status" = "True" ]; then
            print_ok "NNCP ${name} Available"
            break
        fi
        reason=$(oc get nncp "$name" \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].reason}' 2>/dev/null || echo "")
        printf "  [%d/%d] Waiting for status... (%s)\r" "$((i+1))" "$retries" "${reason:-Pending}"
        sleep 5
        i=$((i+1))
    done
    echo ""
    if [ "$i" -eq "$retries" ]; then
        print_warn "NNCP application timed out. Check status manually: oc get nncp / oc get nnce"
        exit 1
    fi
    print_info "Per-node application status (NNCE):"
    oc get nnce 2>/dev/null | grep "$name" | \
        awk '{printf "    %-40s %s\n", $1, $2}' || true
}

# =============================================================================
# Generate NNCP per method
# =============================================================================
gen_nncp_linux_bridge() {
    print_step "NNCP — Linux Bridge (${BRIDGE_NAME} ← ${BRIDGE_INTERFACE})${MTU:+, MTU ${MTU}}"

    {
        cat <<EOF
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ${NNCP_NAME}
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ''
  desiredState:
    interfaces:
      - name: ${BRIDGE_NAME}
        description: Linux bridge with ${BRIDGE_INTERFACE} as a port
        type: linux-bridge
        state: up
EOF
        [ -n "${MTU}" ] && echo "        mtu: ${MTU}"
        cat <<EOF
        ipv4:
          enabled: false
        ipv6:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ${BRIDGE_INTERFACE}
EOF
    } > nncp-${NNCP_NAME}.yaml

    echo ""
    print_info "NNCP YAML to apply:"
    echo "────────────────────────────────────────"
    cat nncp-${NNCP_NAME}.yaml
    echo "────────────────────────────────────────"
    read -r -p "Apply this YAML to the cluster? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { print_warn "Cancelled."; exit 0; }
    oc apply -f nncp-${NNCP_NAME}.yaml
    _wait_nncp "$NNCP_NAME"
}

gen_nncp_linux_bridge_vlan() {
    print_step "NNCP — Linux Bridge + VLAN trunk (${BRIDGE_NAME} ← ${BRIDGE_INTERFACE}, VLAN ${VLAN_ID})${MTU:+, MTU ${MTU}}"

    {
        cat <<EOF
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ${NNCP_NAME}
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ''
  desiredState:
    interfaces:
      - name: ${BRIDGE_NAME}
        description: Linux bridge (VLAN trunk) with ${BRIDGE_INTERFACE} as a port
        type: linux-bridge
        state: up
EOF
        [ -n "${MTU}" ] && echo "        mtu: ${MTU}"
        cat <<EOF
        ipv4:
          enabled: false
        ipv6:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ${BRIDGE_INTERFACE}
              vlan:
                mode: trunk
                trunk-tags:
                  - id-range:
                      min: 1
                      max: 4094
EOF
    } > nncp-${NNCP_NAME}.yaml

    echo ""
    print_info "NNCP YAML to apply:"
    echo "────────────────────────────────────────"
    cat nncp-${NNCP_NAME}.yaml
    echo "────────────────────────────────────────"
    read -r -p "Apply this YAML to the cluster? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { print_warn "Cancelled."; exit 0; }
    oc apply -f nncp-${NNCP_NAME}.yaml
    _wait_nncp "$NNCP_NAME"
}

# =============================================================================
# Main
# =============================================================================
NET_TYPE="${1:-}"

if [ -z "$NET_TYPE" ]; then
    echo -e "${RED}[ERR ]${NC} NET_TYPE argument is required."
    echo "Usage: $0 <NET_TYPE>"
    echo "  1 = Linux Bridge"
    echo "  2 = Linux Bridge + VLAN"
    exit 1
fi

case "$NET_TYPE" in
    1|2) ;;
    *)
        echo -e "${RED}[ERR ]${NC} Invalid NET_TYPE: ${NET_TYPE} (must be 1 or 2)"
        exit 1
        ;;
esac

# Check VLAN ID (NET_TYPE=2 only)
if [ "$NET_TYPE" = "2" ]; then
    if [ -z "${VLAN_ID}" ]; then
        echo ""
        read -r -p "Enter VLAN ID: " VLAN_ID
        if [ -z "$VLAN_ID" ]; then
            echo -e "${RED}[ERR ]${NC} VLAN ID is required."
            exit 1
        fi
    else
        echo ""
        read -r -p "VLAN ID [current: ${VLAN_ID}]: " _vlan_input
        [ -n "$_vlan_input" ] && VLAN_ID="$_vlan_input"
    fi
fi

# MTU configuration
echo ""
read -r -p "Set MTU? (leave blank to use default)${MTU:+ [current: ${MTU}]}: " _mtu_input
[ -n "$_mtu_input" ] && MTU="$_mtu_input"

case "$NET_TYPE" in
    1) gen_nncp_linux_bridge ;;
    2) gen_nncp_linux_bridge_vlan ;;
esac
