#!/bin/bash
# =============================================================================
# nncp-gen.sh
#
# NNCP (NodeNetworkConfigurationPolicy) generation script
# Creates NNCP for 5 network methods and applies it to the cluster.
#
#   1. Linux Bridge          — NMState NNCP (linux-bridge)
#   2. Linux Bridge + VLAN   — NMState NNCP (linux-bridge trunk port)
#   3. OVS Bridge            — NMState NNCP (ovs-bridge + OVN localnet)
#   4. Bond + Linux Bridge   — NMState NNCP (bond + linux-bridge)
#   5. VLAN + Linux Bridge   — NMState NNCP (vlan + linux-bridge)
#
# Usage: ./nncp-gen.sh <NET_TYPE>
#   NET_TYPE: 1=Linux Bridge, 2=Linux Bridge+VLAN, 3=OVS, 4=Bond, 5=VLAN
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
LOCALNET_NAME="${LOCALNET_NAME:-poc-localnet}"
BOND_NAME="${BOND_NAME:-bond0}"
BOND_MODE="${BOND_MODE:-active-backup}"
BOND_INTERFACE_2="${BOND_INTERFACE_2:-ens5}"

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

gen_nncp_ovs_bridge() {
    print_step "NNCP — OVS Bridge (${BRIDGE_NAME} ← ${BRIDGE_INTERFACE}, localnet ${LOCALNET_NAME})${MTU:+, MTU ${MTU}}"

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
        description: OVS bridge with ${BRIDGE_INTERFACE} as a port
        type: ovs-bridge
        state: up
EOF
        [ -n "${MTU}" ] && echo "        mtu: ${MTU}"
        cat <<EOF
        bridge:
          options:
            stp: false
          port:
            - name: ${BRIDGE_INTERFACE}
    ovn:
      bridge-mappings:
        - localnet: ${LOCALNET_NAME}
          bridge: ${BRIDGE_NAME}
          state: present
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

gen_nncp_bond_linux_bridge() {
    print_step "NNCP — Bond + Linux Bridge (${BOND_NAME}: ${BRIDGE_INTERFACE}+${BOND_INTERFACE_2} → ${BRIDGE_NAME})${MTU:+, MTU ${MTU}}"

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
      - name: ${BOND_NAME}
        description: Bond (${BOND_MODE}) of ${BRIDGE_INTERFACE} + ${BOND_INTERFACE_2}
        type: bond
        state: up
        ipv4:
          enabled: false
        ipv6:
          enabled: false
        link-aggregation:
          mode: ${BOND_MODE}
          port:
            - ${BRIDGE_INTERFACE}
            - ${BOND_INTERFACE_2}
      - name: ${BRIDGE_NAME}
        description: Linux bridge with ${BOND_NAME} as a port
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
            - name: ${BOND_NAME}
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

gen_nncp_vlan_linux_bridge() {
    local vlan_iface="${BRIDGE_INTERFACE}.${VLAN_ID}"
    print_step "NNCP — VLAN + Linux Bridge (${vlan_iface} → ${BRIDGE_NAME})${MTU:+, MTU ${MTU}}"

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
      - name: ${vlan_iface}
        description: VLAN ${VLAN_ID} on ${BRIDGE_INTERFACE}
        type: vlan
        state: up
        vlan:
          base-iface: ${BRIDGE_INTERFACE}
          id: ${VLAN_ID}
        ipv4:
          enabled: false
        ipv6:
          enabled: false
      - name: ${BRIDGE_NAME}
        description: Linux bridge with ${vlan_iface} as a port
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
            - name: ${vlan_iface}
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
    echo "  3 = OVS Bridge (OVN Localnet)"
    echo "  4 = Bond + Linux Bridge"
    echo "  5 = VLAN + Linux Bridge"
    exit 1
fi

case "$NET_TYPE" in
    1|2|3|4|5) ;;
    *)
        echo -e "${RED}[ERR ]${NC} Invalid NET_TYPE: ${NET_TYPE} (must be 1–5)"
        exit 1
        ;;
esac

# VLAN ID (NET_TYPE=2 or 5)
if [ "$NET_TYPE" = "2" ] || [ "$NET_TYPE" = "5" ]; then
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

if [ "$NET_TYPE" = "3" ]; then
    echo ""
    read -r -p "OVN localnet name [current: ${LOCALNET_NAME}]: " _ln
    [ -n "$_ln" ] && LOCALNET_NAME="$_ln"
fi

if [ "$NET_TYPE" = "4" ]; then
    echo ""
    read -r -p "Second Bond NIC [current: ${BOND_INTERFACE_2}]: " _nic2
    [ -n "$_nic2" ] && BOND_INTERFACE_2="$_nic2"
    read -r -p "Bond mode (active-backup / 802.3ad) [current: ${BOND_MODE}]: " _mode
    [ -n "$_mode" ] && BOND_MODE="$_mode"
fi

# MTU configuration
echo ""
read -r -p "Set MTU? (leave blank to use default)${MTU:+ [current: ${MTU}]}: " _mtu_input
[ -n "$_mtu_input" ] && MTU="$_mtu_input"

case "$NET_TYPE" in
    1) gen_nncp_linux_bridge ;;
    2) gen_nncp_linux_bridge_vlan ;;
    3) gen_nncp_ovs_bridge ;;
    4) gen_nncp_bond_linux_bridge ;;
    5) gen_nncp_vlan_linux_bridge ;;
esac
