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
trap 'echo -e "\n\033[0;31m[ERROR]\033[0m Command failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-load env.conf (when running standalone)
ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

VM_NS="poc-vm"
NNCP_NAME="${NNCP_NAME:-poc-bridge-nncp}"
BRIDGE_NAME="${BRIDGE_NAME:-br-poc}"
BRIDGE_INTERFACE="${BRIDGE_INTERFACE:-ens4}"
NNCP_IFACE_TYPE="${NNCP_IFACE_TYPE:-linux-bridge}"
NET_TYPE="${NET_TYPE:-1}"
NAD_NAME="${NAD_NAME:-}"
LOCALNET_NAME="${LOCALNET_NAME:-poc-localnet}"
VLAN_ID="${VLAN_ID:-100}"
SECONDARY_IP_PREFIX="${SECONDARY_IP_PREFIX:-192.168.200}"
SECONDARY_IP_START="${SECONDARY_IP_START:-60}"

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

    if [ -n "$NNCP_NAME" ] && oc get nncp "$NNCP_NAME" &>/dev/null; then
        detect_nncp_type "$NNCP_NAME"
        select_localnet
    fi
    resolve_nad_name
    save_network_env

    print_ok "Configuration confirmed"
    print_info "  VM_NS            : ${VM_NS}"
    print_info "  BRIDGE_NAME      : ${BRIDGE_NAME}"
    print_info "  NNCP_IFACE_TYPE  : ${NNCP_IFACE_TYPE}"
    print_info "  LOCALNET_NAME    : ${LOCALNET_NAME}"
    print_info "  NAD_NAME         : ${NAD_NAME}"

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
                detect_nncp_type "$_n"
                printf "    %-35s %-15s %-20s %s\n" "$_n" "$(nncp_type_label "$NNCP_IFACE_TYPE")" "${BRIDGE_NAME:-N/A}" "${BRIDGE_INTERFACE:-N/A}"
            done
            echo ""
            local _first_nncp
            _first_nncp=$(echo "$_all_nncps" | head -1)
            read -r -p "  Enter NNCP name to use [default: ${_first_nncp}]: " _input_nncp
            [ -z "$_input_nncp" ] && _input_nncp="$_first_nncp"
            NNCP_NAME="$_input_nncp"
            detect_nncp_type "$NNCP_NAME"
            select_localnet
            print_ok "Using NNCP '${NNCP_NAME}' (type: $(nncp_type_label "$NNCP_IFACE_TYPE"), bridge: ${BRIDGE_NAME})"
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
    print_step "2/4  NAD — Register NetworkAttachmentDefinition (${NAD_NAME} → ${VM_NS})"

    local nad_file="nad-${NAD_NAME}.yaml"
    if [ "$NNCP_IFACE_TYPE" = "ovs-bridge" ]; then
        local _vlan_line=""
        if [ "$NET_TYPE" = "2" ] && [ "${NNCP_BRIDGE_HAS_VLAN:-}" != "true" ]; then
            _vlan_line="
        \"vlanID\": ${VLAN_ID},"
        elif [ "${NNCP_BRIDGE_HAS_VLAN:-}" = "true" ]; then
            print_warn "NNCP bridge port is a VLAN sub-interface, skipping vlanID in NAD."
        fi
            cat > "$nad_file" <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${VM_NS}
spec:
  config: |-
    {
        "cniVersion": "0.3.1",
        "name": "${LOCALNET_NAME}",
        "type": "ovn-k8s-cni-overlay",
        "topology": "localnet",${_vlan_line}
        "netAttachDefName": "${VM_NS}/${NAD_NAME}",
        "physicalNetworkName": "${LOCALNET_NAME}",
        "mtu": ${NAD_MTU:-1500}
    }
EOF
    elif [ "$NET_TYPE" = "2" ] && [ "$NNCP_IFACE_TYPE" != "vlan" ]; then
        cat > "$nad_file" <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${VM_NS}
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/${BRIDGE_NAME}
spec:
  config: |-
    {
        "cniVersion": "0.3.1",
        "name": "${NAD_NAME}",
        "type": "bridge",
        "bridge": "${BRIDGE_NAME}",
        "vlan": ${VLAN_ID},
        "ipam": {},
        "macspoofchk": true,
        "preserveDefaultVlan": false
    }
EOF
    else
        cat > "$nad_file" <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${VM_NS}
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/${BRIDGE_NAME}
spec:
  config: |-
    {
        "cniVersion": "0.3.1",
        "name": "${NAD_NAME}",
        "type": "bridge",
        "bridge": "${BRIDGE_NAME}",
        "ipam": {},
        "macspoofchk": true,
        "preserveDefaultVlan": false
    }
EOF
    fi
    echo "Generated file: ${nad_file}"
    oc apply -f "$nad_file"
    print_ok "NAD ${NAD_NAME} registered (namespace: ${VM_NS})"
}

# =============================================================================
# Step 3: Create VM (poc template + poc-bridge-nad)
# =============================================================================
step_vm() {
    print_step "3/4  Create VM (poc template + ${NAD_NAME})"

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

    # Add secondary NIC — distinguish OVN localnet vs Linux Bridge
    local _net_label="secondary-net"
    local _net_ref="${NAD_NAME}"
    if [ "${NNCP_IFACE_TYPE:-}" = "ovs-bridge" ]; then
        _net_ref="${VM_NS}/${NAD_NAME}"
    fi
    oc patch vm "$VM_NAME" -n "$VM_NS" --type=json -p="[
      {
        \"op\": \"add\",
        \"path\": \"/spec/template/spec/domain/devices/interfaces/-\",
        \"value\": {\"name\": \"${_net_label}\", \"bridge\": {}, \"model\": \"virtio\"}
      },
      {
        \"op\": \"add\",
        \"path\": \"/spec/template/spec/networks/-\",
        \"value\": {\"name\": \"${_net_label}\", \"multus\": {\"networkName\": \"${_net_ref}\"}}
      }
    ]"

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
           \"value\": \"version: 2\\nethernets:\\n  eth1:\\n    dhcp4: false\\n    addresses:\\n      - ${SECONDARY_IP_PREFIX}.$(( SECONDARY_IP_START + 2 ))/24\\n    gateway4: ${SECONDARY_IP_PREFIX}.1\\n    nameservers:\\n      addresses:\\n        - 8.8.8.8\\n\"}
        ]"
        print_ok "networkData added (eth1: ${SECONDARY_IP_PREFIX}.$(( SECONDARY_IP_START + 2 ))/24)"
    else
        print_warn "cloudinitdisk volume not found. networkData not configured."
    fi

    virtctl start "$VM_NAME" -n "$VM_NS" 2>/dev/null || true
    print_ok "VM ${VM_NAME} created (eth0: masquerade, eth1: ${NAD_NAME}, IP: ${SECONDARY_IP_PREFIX}.$(( SECONDARY_IP_START + 2 ))/24)"
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
  description: "Connect NAD ${NAD_NAME} (${NNCP_IFACE_TYPE}) as a secondary network to a poc template-based VM, and configure a static IP on eth1 via cloud-init."
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
                  name: secondary-net
            memory:
              guest: 2Gi
          networks:
            - name: default
              pod: {}
            - name: secondary-net
              multus:
                networkName: ${NAD_NAME}
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
                        - ${SECONDARY_IP_PREFIX}.$(( SECONDARY_IP_START + 3 ))/24
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
