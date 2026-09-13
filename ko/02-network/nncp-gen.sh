#!/bin/bash
# =============================================================================
# nncp-gen.sh
#
# NNCP (NodeNetworkConfigurationPolicy) 생성 스크립트
# 5가지 네트워크 방식에 대한 NNCP를 생성하고 클러스터에 적용합니다.
#
#   1. Linux Bridge          — NMState NNCP (linux-bridge)
#   2. Linux Bridge + VLAN   — NMState NNCP (linux-bridge trunk port)
#   3. OVS Bridge            — NMState NNCP (ovs-bridge + OVN localnet)
#   4. Bond + Linux Bridge   — NMState NNCP (bond + linux-bridge)
#   5. VLAN + Linux Bridge   — NMState NNCP (vlan + linux-bridge)
#
# 사용법: ./nncp-gen.sh <NET_TYPE>
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
# NNCP 적용 완료 대기
# =============================================================================
_wait_nncp() {
    local name="$1"
    print_info "NNCP 적용됨 — 노드 설정 전파를 대기 중..."
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
        printf "  [%d/%d] 상태 대기 중... (%s)\r" "$((i+1))" "$retries" "${reason:-Pending}"
        sleep 5
        i=$((i+1))
    done
    echo ""
    if [ "$i" -eq "$retries" ]; then
        print_warn "NNCP 적용 시간 초과. 상태를 수동으로 확인하세요: oc get nncp / oc get nnce"
        exit 1
    fi
    print_info "노드별 적용 상태 (NNCE):"
    oc get nnce 2>/dev/null | grep "$name" | \
        awk '{printf "    %-40s %s\n", $1, $2}' || true
}

# =============================================================================
# 방식별 NNCP 생성
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
    print_info "적용할 NNCP YAML:"
    echo "────────────────────────────────────────"
    cat nncp-${NNCP_NAME}.yaml
    echo "────────────────────────────────────────"
    read -r -p "이 YAML을 클러스터에 적용하시겠습니까? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { print_warn "취소되었습니다."; exit 0; }
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
    print_info "적용할 NNCP YAML:"
    echo "────────────────────────────────────────"
    cat nncp-${NNCP_NAME}.yaml
    echo "────────────────────────────────────────"
    read -r -p "이 YAML을 클러스터에 적용하시겠습니까? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { print_warn "취소되었습니다."; exit 0; }
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
    print_info "적용할 NNCP YAML:"
    echo "────────────────────────────────────────"
    cat nncp-${NNCP_NAME}.yaml
    echo "────────────────────────────────────────"
    read -r -p "이 YAML을 클러스터에 적용하시겠습니까? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { print_warn "취소되었습니다."; exit 0; }
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
    print_info "적용할 NNCP YAML:"
    echo "────────────────────────────────────────"
    cat nncp-${NNCP_NAME}.yaml
    echo "────────────────────────────────────────"
    read -r -p "이 YAML을 클러스터에 적용하시겠습니까? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { print_warn "취소되었습니다."; exit 0; }
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
    print_info "적용할 NNCP YAML:"
    echo "────────────────────────────────────────"
    cat nncp-${NNCP_NAME}.yaml
    echo "────────────────────────────────────────"
    read -r -p "이 YAML을 클러스터에 적용하시겠습니까? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { print_warn "취소되었습니다."; exit 0; }
    oc apply -f nncp-${NNCP_NAME}.yaml
    _wait_nncp "$NNCP_NAME"
}

# =============================================================================
# Main
# =============================================================================
NET_TYPE="${1:-}"

if [ -z "$NET_TYPE" ]; then
    echo -e "${RED}[ERR ]${NC} NET_TYPE 인수가 필요합니다."
    echo "사용법: $0 <NET_TYPE>"
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
        echo -e "${RED}[ERR ]${NC} 잘못된 NET_TYPE: ${NET_TYPE} (1–5여야 합니다)"
        exit 1
        ;;
esac

# VLAN ID (NET_TYPE=2 또는 5)
if [ "$NET_TYPE" = "2" ] || [ "$NET_TYPE" = "5" ]; then
    if [ -z "${VLAN_ID}" ]; then
        echo ""
        read -r -p "VLAN ID를 입력하세요: " VLAN_ID
        if [ -z "$VLAN_ID" ]; then
            echo -e "${RED}[ERR ]${NC} VLAN ID가 필요합니다."
            exit 1
        fi
    else
        echo ""
        read -r -p "VLAN ID [현재: ${VLAN_ID}]: " _vlan_input
        [ -n "$_vlan_input" ] && VLAN_ID="$_vlan_input"
    fi
fi

if [ "$NET_TYPE" = "3" ]; then
    echo ""
    read -r -p "OVN localnet 이름 [현재: ${LOCALNET_NAME}]: " _ln
    [ -n "$_ln" ] && LOCALNET_NAME="$_ln"
fi

if [ "$NET_TYPE" = "4" ]; then
    echo ""
    read -r -p "Bond 두 번째 NIC [현재: ${BOND_INTERFACE_2}]: " _nic2
    [ -n "$_nic2" ] && BOND_INTERFACE_2="$_nic2"
    read -r -p "Bond 모드 (active-backup / 802.3ad) [현재: ${BOND_MODE}]: " _mode
    [ -n "$_mode" ] && BOND_MODE="$_mode"
fi

# MTU 설정
echo ""
read -r -p "MTU를 설정하시겠습니까? (기본값을 사용하려면 비워두세요)${MTU:+ [현재: ${MTU}]}: " _mtu_input
[ -n "$_mtu_input" ] && MTU="$_mtu_input"

case "$NET_TYPE" in
    1) gen_nncp_linux_bridge ;;
    2) gen_nncp_linux_bridge_vlan ;;
    3) gen_nncp_ovs_bridge ;;
    4) gen_nncp_bond_linux_bridge ;;
    5) gen_nncp_vlan_linux_bridge ;;
esac
