# Network Configuration (NNCP / NAD)

Configure NNCP (NodeNetworkConfigurationPolicy) and NAD (NetworkAttachmentDefinition)
to connect VMs to the physical network in OpenShift Virtualization.

When running `02-network.sh`, select one of 4 modes.

---

## Method Comparison

| Item | Linux Bridge | OVN Localnet | Linux Bridge + VLAN | OVN Localnet + VLAN |
|------|-------------|-------------|---------------------|---------------------|
| CNI driver | `cnv-bridge` | `ovn-k8s-cni-overlay` | `cnv-bridge` | `ovn-k8s-cni-overlay` |
| VLAN isolation | ❌ | ❌ | ✅ (VLAN ID in NAD) | ✅ (vlanID in NAD) |
| OVN port security·ACL | ❌ | ✅ | ❌ | ✅ |
| Switch requirements | Access or Trunk | Trunk (OVN handles) | Trunk | Trunk |
| NNCP extra config | bridge only | bridge + `ovn.bridge-mappings` | bridge + VLAN trunk port | bridge + `ovn.bridge-mappings` |

---

## Prerequisites

- NMState Operator installed and NMState CR created (see `operators/nmstate-operator.md`)
- `BRIDGE_INTERFACE`, `BRIDGE_NAME`, `SECONDARY_IP_PREFIX` configured in `env.conf`
- Namespace: `poc-network` (fixed)

```bash
# NMState Operator status
oc get csv -n openshift-nmstate | grep nmstate

# NMState CR existence check
oc get nmstate

# Check node interface names
oc get nns <worker-node> \
  -o jsonpath='{range .status.currentState.interfaces[?(@.type=="ethernet")]}{.name}{"\n"}{end}'
```

---

## Method 1. Linux Bridge

```
Physical NIC (BRIDGE_INTERFACE)
    │  NNCP → Create Linux Bridge
    ▼
Linux Bridge (BRIDGE_NAME)
    │  NAD → cnv-bridge CNI
    ▼
VM eth1 (L2 direct connection)
```

### NNCP

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: poc-bridge-nncp
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: br1                     # BRIDGE_NAME
        type: linux-bridge
        state: up
        ipv4:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ens4              # BRIDGE_INTERFACE
```

### NAD

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: poc-bridge-nad
  namespace: poc-network
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/br1
spec:
  config: '{
    "cniVersion": "0.3.1",
    "name": "poc-bridge-nad",
    "type": "cnv-bridge",
    "bridge": "br1",
    "macspoofchk": true,
    "ipam": {}
  }'
```

---

## Method 2. OVN Localnet

OVN-Kubernetes handles switching.
Add `ovn.bridge-mappings` to NNCP to map the physical bridge to an OVN localnet name.

> **Key**: The `bridge-mappings[].localnet` value in NNCP and the `"name"` value in NAD CNI config must **match**.

```
Physical NIC (BRIDGE_INTERFACE)
    │  NNCP → Linux Bridge + OVN bridge-mappings
    ▼
Linux Bridge (BRIDGE_NAME) ← OVN localnet: "poc-localnet"
    │  NAD → ovn-k8s-cni-overlay CNI
    ▼
VM eth1 (OVN port security·ACL applied)
```

### NNCP

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: poc-localnet-nncp
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: br1
        type: linux-bridge
        state: up
        ipv4:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ens4
    ovn:
      bridge-mappings:
        - localnet: poc-localnet      # Must match NAD "name" value
          bridge: br1
          state: present
```

### NAD

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: poc-localnet-nad
  namespace: poc-network
spec:
  config: '{
    "cniVersion": "0.3.1",
    "name": "poc-localnet",           # Must match NNCP bridge-mappings localnet value
    "type": "ovn-k8s-cni-overlay",
    "topology": "localnet",
    "netAttachDefName": "poc-network/poc-localnet-nad"
  }'
```

---

## Method 3. Linux Bridge + VLAN filtering

Configure Linux Bridge port in **trunk mode** to separate multiple VLANs with a single physical NIC.
Assign different VLAN IDs per NAD to place VMs on the desired VLAN.

> The physical switch port must also be set to **trunk mode**.

```
Physical NIC (BRIDGE_INTERFACE) — connected to switch trunk port
    │  NNCP → Linux Bridge + VLAN trunk port
    ▼
Linux Bridge (BRIDGE_NAME)
    │  NAD → cnv-bridge + vlan: 100
    ▼
VM eth1 (placed in VLAN 100)
```

### NNCP

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: poc-bridge-nncp
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: br1
        type: linux-bridge
        state: up
        ipv4:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ens4
              vlan:
                mode: trunk            # Enable VLAN filtering
                trunk-tags:
                  - id-range:
                      min: 1
                      max: 4094        # Allow all VLANs (reduce range as needed)
```

### NAD (VLAN 100 example)

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: poc-bridge-vlan-nad
  namespace: poc-network
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/br1
spec:
  config: '{
    "cniVersion": "0.3.1",
    "name": "poc-bridge-vlan-nad",
    "type": "cnv-bridge",
    "bridge": "br1",
    "vlan": 100,                       # VLAN ID for the VM to connect to
    "macspoofchk": true,
    "ipam": {}
  }'
```

> For a different VLAN (e.g., 200), reuse the same NNCP and create a new NAD with `"vlan": 200`.

---

## Method 4. OVN Localnet + VLAN

Specify `vlanID` in OVN bridge-mappings + NAD.
NNCP is the same as Method 2; only add `vlanID` to the NAD.

```
Physical NIC (BRIDGE_INTERFACE) — connected to switch trunk port
    │  NNCP → Linux Bridge + OVN bridge-mappings
    ▼
Linux Bridge ← OVN localnet: "poc-localnet"
    │  NAD → ovn-k8s-cni-overlay + vlanID: 100
    ▼
VM eth1 (OVN port security + VLAN 100)
```

### NNCP

Same as Method 2 NNCP (`poc-localnet-nncp`).

### NAD (VLAN 100 example)

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: poc-localnet-vlan-nad
  namespace: poc-network
spec:
  config: '{
    "cniVersion": "0.3.1",
    "name": "poc-localnet",
    "type": "ovn-k8s-cni-overlay",
    "topology": "localnet",
    "netAttachDefName": "poc-network/poc-localnet-vlan-nad",
    "vlanID": 100
  }'
```

---

## VM Creation (Common)

Connect the selected NAD as a secondary network and configure a static IP on eth1 via cloud-init.
Two VMs (`poc-network-vm-1`, `poc-network-vm-2`) are deployed.

| VM | eth1 IP |
|----|---------|
| poc-network-vm-1 | `SECONDARY_IP_PREFIX`.10/24 |
| poc-network-vm-2 | `SECONDARY_IP_PREFIX`.11/24 |

> `SECONDARY_IP_PREFIX` default: `192.168.100` (can be changed in env.conf)
> `02-network.sh` performs the patches below automatically.

```bash
NAD_NAME="poc-bridge-nad"           # Change based on selected method
SECONDARY_IP_PREFIX="192.168.100"   # Uses env.conf value

for suffix in 1 2; do
  VM_NAME="poc-network-vm-${suffix}"
  IP_SUFFIX=$([ "$suffix" = "1" ] && echo "10" || echo "11")

  # Create VM from poc template (Halted state)
  oc process -n openshift poc -p NAME="${VM_NAME}" \
    | sed 's/  running: false/  runStrategy: Halted/' \
    | oc apply -n "poc-network" -f -

  # Add secondary NIC
  oc patch vm "${VM_NAME}" -n "poc-network" --type=json -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/domain/devices/interfaces/-",
      "value": {"name": "bridge-net", "bridge": {}, "model": "virtio"}
    },
    {
      "op": "add",
      "path": "/spec/template/spec/networks/-",
      "value": {"name": "bridge-net", "multus": {"networkName": "'"${NAD_NAME}"'"}}
    }
  ]'

  # Add networkData to existing cloudinitdisk volume (before VM start)
  CI_IDX=$(oc get vm "${VM_NAME}" -n "poc-network" \
    -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' | \
    grep -n "cloudinitdisk" | cut -d: -f1 | head -1)
  CI_IDX=$(( CI_IDX - 1 ))
  oc patch vm "${VM_NAME}" -n "poc-network" --type=json -p="[
    {\"op\": \"add\",
     \"path\": \"/spec/template/spec/volumes/${CI_IDX}/cloudInitNoCloud/networkData\",
     \"value\": \"version: 2\nethernets:\n  eth1:\n    dhcp4: false\n    addresses:\n      - ${SECONDARY_IP_PREFIX}.${IP_SUFFIX}/24\n    gateway4: ${SECONDARY_IP_PREFIX}.1\n    nameservers:\n      addresses:\n        - 8.8.8.8\n\"}
  ]"

  virtctl start "${VM_NAME}" -n "poc-network"
done
```

The resulting `cloudinitdisk` volume:

```yaml
- name: cloudinitdisk
  cloudInitNoCloud:
    userData: |-
      #cloud-config
      user: cloud-user
      password: ...
      chpasswd: { expire: False }
    networkData: |
      version: 2
      ethernets:
        eth1:
          dhcp4: false
          addresses:
            - 192.168.100.10/24
          gateway4: 192.168.100.1
          nameservers:
            addresses:
              - 8.8.8.8
```

### VM Network Verification

```bash
# VMI NIC status (both VMs)
for vm in poc-network-vm-1 poc-network-vm-2; do
  echo "=== ${vm} ==="
  oc get vmi "${vm}" -n "poc-network" \
    -o jsonpath='{range .status.interfaces[*]}{.name}: {.ipAddress}{"\n"}{end}'
done

# VM console access
virtctl console poc-network-vm-1 -n "poc-network"
# ip addr show eth1
# ping 192.168.100.11   ← communication test to vm-2
```

---

## Status Check

```bash
# NNCP status
oc get nncp

# Per-node application status (NNCE)
oc get nnce

# Check bridge in NodeNetworkState
oc get nns <node> -o yaml | grep -A5 "linux-bridge"

# Check OVN bridge-mappings (Method 2/4)
oc get nncp poc-localnet-nncp -o jsonpath='{.spec.desiredState.ovn}' | python3 -m json.tool

# NAD list
oc get net-attach-def -n poc-network
```

---

## Rollback

```bash
# Delete NAD
oc delete net-attach-def -n poc-network --all

# Delete NNCP (remove Bridge)
oc delete nncp poc-bridge-nncp poc-localnet-nncp 2>/dev/null || true

# Delete namespace
oc delete namespace poc-network
```

---

## Troubleshooting

```bash
# Check NNCP failure reason
oc describe nncp <nncp-name>

# Check per-node NNCE errors
oc describe nnce <node>.<nncp-name>

# NMState handler logs
oc logs -n openshift-nmstate -l component=kubernetes-nmstate-handler -f

# Check network state directly on node
oc debug node/<node> -- chroot /host nmstatectl show

# Check OVN localnet mapping (Method 2/4)
oc debug node/<node> -- chroot /host ovs-vsctl list open .
```

### OVN Localnet — localnet name mismatch

If the NNCP `bridge-mappings[].localnet` value and the NAD CNI config `"name"` value differ,
the VM network interface will not be created.

```bash
# Check localnet name in NNCP
oc get nncp poc-localnet-nncp \
  -o jsonpath='{.spec.desiredState.ovn.bridge-mappings[0].localnet}'

# Check name in NAD CNI config
oc get net-attach-def poc-localnet-nad -n poc-network \
  -o jsonpath='{.spec.config}' | python3 -m json.tool | grep '"name"'
```

Both values must be identical.
