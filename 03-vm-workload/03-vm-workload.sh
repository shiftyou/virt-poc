#!/bin/bash
# =============================================================================
# 03-vm-workload.sh
#
# Create poc-vm namespace, register NAD, and deploy VM (poc template + bridge network)
# Prepares the VM workload execution environment.
#
# Usage: ./03-vm-workload.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-load env.conf (when running standalone)
ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

VM_NS="poc-vm"
NNCP_NAME="${NNCP_NAME:-poc-bridge-nncp}"
BRIDGE_NAME="${BRIDGE_NAME}"
SECONDARY_IP_PREFIX="${SECONDARY_IP_PREFIX:-192.168.100}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

print_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERR ]${NC} $1"; }
print_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

# =============================================================================
# Pre-flight checks
# =============================================================================
preflight() {
    print_step "Pre-flight checks"

    # Check OpenShift Virtualization Operator
    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator not installed → skipping."
        print_warn "  Installation guide: operators/kubevirt-hyperconverged-operator.md"
        exit 77
    fi

    print_ok "Configuration confirmed"
    print_info "  VM_NS       : ${VM_NS}"
    print_info "  BRIDGE_NAME : ${BRIDGE_NAME}"

    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift."
        exit 1
    fi
    print_ok "Cluster connection: $(oc whoami) @ $(oc whoami --show-server)"

    # Check NNCP / Bridge
    if ! oc get nncp "$NNCP_NAME" &>/dev/null; then
        print_warn "NNCP '${NNCP_NAME}' not found."
        # Display available NNCP list and prompt for selection
        local _all_nncps
        _all_nncps=$(oc get nncp -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' || true)
        if [ -n "$_all_nncps" ]; then
            print_info "List of NNCPs currently in the cluster:"
            echo ""
            printf "    %-35s %-15s %-20s %s\n" "NNCP Name" "Type" "Bridge Name" "NIC"
            echo "    ────────────────────────────────────────────────────────────────────────"
            for _n in $_all_nncps; do
                local _b _nic _ob
                _b=$(oc get nncp "$_n" \
                    -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.name}{end}' \
                    2>/dev/null || true)
                if [ -n "$_b" ]; then
                    _nic=$(oc get nncp "$_n" \
                        -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.bridge.port[0].name}{end}' \
                        2>/dev/null || true)
                    printf "    %-35s %-15s %-20s %s\n" "$_n" "linux-bridge" "$_b" "${_nic:-N/A}"
                else
                    _ob=$(oc get nncp "$_n" \
                        -o jsonpath='{.spec.desiredState.ovn.bridge-mappings[0].bridge}' \
                        2>/dev/null || true)
                    if [ -n "$_ob" ]; then
                        printf "    %-35s %-15s %-20s %s\n" "$_n" "ovn-localnet" "$_ob" "-"
                    else
                        printf "    %-35s %-15s %-20s %s\n" "$_n" "unknown" "-" "-"
                    fi
                fi
            done
            echo ""
            local _first_nncp
            _first_nncp=$(echo "$_all_nncps" | head -1)
            read -r -p "  Enter NNCP name to use [default: ${_first_nncp}]: " _input_nncp
            [ -z "$_input_nncp" ] && _input_nncp="$_first_nncp"
            NNCP_NAME="$_input_nncp"
            # Extract bridge name from selected NNCP
            local _new_br
            _new_br=$(oc get nncp "$NNCP_NAME" \
                -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.name}{end}' \
                2>/dev/null || true)
            [ -z "$_new_br" ] && _new_br=$(oc get nncp "$NNCP_NAME" \
                -o jsonpath='{.spec.desiredState.ovn.bridge-mappings[0].bridge}' \
                2>/dev/null || true)
            [ -n "$_new_br" ] && BRIDGE_NAME="$_new_br"
            print_ok "Using NNCP '${NNCP_NAME}' (bridge: ${BRIDGE_NAME})"
        else
            print_warn "No available NNCPs. Please run 02-network first."
        fi
    else
        local status
        status=$(oc get nncp "$NNCP_NAME" \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
        if [ "$status" = "True" ]; then
            print_ok "NNCP ${NNCP_NAME} Available"
        else
            print_warn "NNCP ${NNCP_NAME} status: ${status:-Unknown}"
        fi
    fi
}

# =============================================================================
# Step 1: Create namespace
# =============================================================================
step_namespace() {
    print_step "1/3  Create namespace (${VM_NS})"

    if oc get namespace "${VM_NS}" &>/dev/null; then
        print_ok "Namespace ${VM_NS} already exists — skipping"
    else
        oc new-project "${VM_NS}" > /dev/null
        print_ok "Namespace ${VM_NS} created"
    fi
}

# Migrate spec.running (deprecated) → spec.runStrategy
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
# Step 2: Register NAD
# =============================================================================
step_nad() {
    print_step "2/4  NAD — Register NetworkAttachmentDefinition (${VM_NS})"

    cat > nad-vm-bridge.yaml <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: poc-bridge-nad
  namespace: ${VM_NS}
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/${BRIDGE_NAME}
spec:
  config: |-
    {
        "cniVersion": "0.3.1",
        "name": "poc-bridge-nad",
        "type": "bridge",
        "bridge": "${BRIDGE_NAME}",
        "ipam": {},
        "macspoofchk": true,
        "preserveDefaultVlan": false
    }
EOF
    echo "Generated file: nad-vm-bridge.yaml"
    oc apply -f nad-vm-bridge.yaml

    print_ok "NAD poc-bridge-nad registered (namespace: ${VM_NS})"
}

# =============================================================================
# Step 3: Create VM (poc template + poc-bridge-nad)
# =============================================================================
step_vm() {
    print_step "3/4  Create VM (poc template + poc-bridge-nad)"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc Template not found — skipping VM creation. (Run 01-template first)"
        return
    fi

    local VM_NAME="poc-vm"

    if oc get vm "$VM_NAME" -n "$VM_NS" &>/dev/null; then
        print_ok "VM $VM_NAME already exists — skipping"
        return
    fi

    local vm_yaml="${SCRIPT_DIR}/vm-${VM_NAME}.yaml"
    oc process -n openshift poc -p NAME="$VM_NAME" | \
        sed 's/runStrategy: Always/runStrategy: Halted/' | \
        sed 's/  running: false/  runStrategy: Halted/' > "${vm_yaml}"
    echo "Generated file: ${vm_yaml}"
    oc apply -n "$VM_NS" -f "${vm_yaml}"

    ensure_runstrategy "$VM_NAME" "$VM_NS"

    # Add secondary NIC (poc-bridge-nad)
    oc patch vm "$VM_NAME" -n "$VM_NS" --type=json -p='[
      {
        "op": "add",
        "path": "/spec/template/spec/domain/devices/interfaces/-",
        "value": {"name": "bridge-net", "bridge": {}, "model": "virtio"}
      },
      {
        "op": "add",
        "path": "/spec/template/spec/networks/-",
        "value": {"name": "bridge-net", "multus": {"networkName": "poc-bridge-nad"}}
      }
    ]'

    # cloud-init networkData — eth1 static IP (03 → .31/24)
    local ci_idx
    ci_idx=$(oc get vm "$VM_NAME" -n "$VM_NS" \
        -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' 2>/dev/null | \
        grep -n "cloudinitdisk" | cut -d: -f1 | head -1)
    [ -n "$ci_idx" ] && ci_idx=$(( ci_idx - 1 ))

    if [ -n "$ci_idx" ]; then
        oc patch vm "$VM_NAME" -n "$VM_NS" --type=json -p="[
          {\"op\": \"add\",
           \"path\": \"/spec/template/spec/volumes/${ci_idx}/cloudInitNoCloud/networkData\",
           \"value\": \"version: 2\\nethernets:\\n  eth1:\\n    dhcp4: false\\n    addresses:\\n      - ${SECONDARY_IP_PREFIX}.31/24\\n    gateway4: ${SECONDARY_IP_PREFIX}.1\\n    nameservers:\\n      addresses:\\n        - 8.8.8.8\\n\"}
        ]"
        print_ok "networkData added (eth1: ${SECONDARY_IP_PREFIX}.31/24)"
    else
        print_warn "cloudinitdisk volume not found. networkData not configured."
    fi

    virtctl start "$VM_NAME" -n "$VM_NS" 2>/dev/null || true
    print_ok "VM ${VM_NAME} created (eth0: masquerade, eth1: poc-bridge-nad, IP: ${SECONDARY_IP_PREFIX}.31/24)"
}

# =============================================================================
# Step 4: Register ConsoleYAMLSample
# =============================================================================
step_consoleyamlsamples() {
    print_step "4/4  Register ConsoleYAMLSample"

    cat > consoleyamlsample-virtualmachine.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-virtualmachine
spec:
  title: "Create POC VirtualMachine (Bridge network + cloud-init static IP)"
  description: "Connect a Linux Bridge NAD (${BRIDGE_NAME}) as a secondary network to a poc template-based VM, and configure a static IP on eth1 via cloud-init. Apply after registering poc Template and NAD."
  targetResource:
    apiVersion: kubevirt.io/v1
    kind: VirtualMachine
  yaml: |
    apiVersion: kubevirt.io/v1
    kind: VirtualMachine
    metadata:
      name: poc-vm
      namespace: ${VM_NS}
    spec:
      runStrategy: Halted
      template:
        spec:
          domain:
            cpu:
              cores: 1
              sockets: 1
              threads: 1
            devices:
              disks:
                - disk:
                    bus: virtio
                  name: rootdisk
                - disk:
                    bus: virtio
                  name: cloudinitdisk
              interfaces:
                - masquerade: {}
                  model: virtio
                  name: default
                - bridge: {}
                  model: virtio
                  name: bridge-net
            memory:
              guest: 2Gi
          networks:
            - name: default
              pod: {}
            - name: bridge-net
              multus:
                networkName: poc-bridge-nad
          volumes:
            - dataVolume:
                name: poc-vm
              name: rootdisk
            - name: cloudinitdisk
              cloudInitNoCloud:
                userData: |-
                  #cloud-config
                  user: cloud-user
                  password: changeme
                  chpasswd: { expire: False }
                networkData: |
                  version: 2
                  ethernets:
                    eth1:
                      dhcp4: false
                      addresses:
                        - ${SECONDARY_IP_PREFIX}.10/24
                      gateway4: ${SECONDARY_IP_PREFIX}.1
                      nameservers:
                        addresses:
                          - 8.8.8.8
      dataVolumeTemplates:
        - metadata:
            name: poc-vm
          spec:
            sourceRef:
              kind: DataSource
              name: poc
              namespace: openshift-virtualization-os-images
            storage:
              resources:
                requests:
                  storage: 30Gi
EOF
    echo "Generated file: consoleyamlsample-virtualmachine.yaml"
    oc apply -f consoleyamlsample-virtualmachine.yaml
    print_ok "ConsoleYAMLSample poc-virtualmachine registered"
}

# =============================================================================
# Completion summary
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! VM workload environment is ready.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Namespace : ${CYAN}oc get namespace ${VM_NS}${NC}"
    echo -e "  NAD check : ${CYAN}oc get net-attach-def -n ${VM_NS}${NC}"
    echo ""
    echo -e "  Next steps: Refer to 03-vm-workload.md"
    echo -e "    - VM creation using poc template"
    echo -e "    - Storage addition"
    echo -e "    - Network addition"
    echo -e "    - Static IP / Domain / Router configuration"
    echo -e "    - Live Migration"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Delete 03-vm-workload resources"
    oc delete project poc-vm --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-virtualmachine --ignore-not-found 2>/dev/null || true
    print_ok "03-vm-workload resources deleted"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  VM Workload — Namespace + NAD + VM (poc template + bridge network)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_nad
    step_vm
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
