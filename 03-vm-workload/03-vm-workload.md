# VM Workload

Explains how to deploy VMs in the `poc-vm` namespace using the poc template with bridge network and cloud-init static IP.

```
poc Template (openshift namespace)
        │  oc process → VirtualMachine creation
        ▼
VirtualMachine (poc-vm)
        │
        ├─ rootdisk (DataVolume ← poc DataSource clone)
        ├─ additional disk (PVC)
        │
        ├─ eth0 (Pod Network — masquerade)
        └─ eth1 (poc-bridge-nad → Linux Bridge → physical network)
```

---

## Prerequisites

- `01-template` complete — `poc` Template and DataSource registered
- `02-network` complete — NNCP / NAD configured
- `03-vm-workload.sh` complete — `poc-vm` namespace and NAD registered

```bash
# Check prerequisites
oc get template poc -n openshift
oc get datasource poc -n openshift-virtualization-os-images
oc get nncp poc-bridge-nncp
oc get net-attach-def poc-bridge-nad -n poc-vm
```

---

## 1. VM Creation (using poc template)

Process the `poc` Template to create a VirtualMachine object.

```bash
# Basic creation (auto-generated name)
oc process -n openshift poc | oc apply -n poc-vm -f -

# Specify VM name
oc process -n openshift poc \
  -p NAME=my-poc-vm \
  | oc apply -n poc-vm -f -

# Start VM
virtctl start my-poc-vm -n poc-vm
```

### VM Status Check

```bash
# VM list
oc get vm -n poc-vm

# VM details (check Phase)
oc get vmi -n poc-vm

# Check Pod
oc get pods -n poc-vm

# Console access
virtctl console my-poc-vm -n poc-vm

# VNC access
virtctl vnc my-poc-vm -n poc-vm
```

---

## 2. Storage Addition

Hot-plug a data disk to a running VM.

### Hot-plug after PVC creation

```bash
# Create PVC for data
oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-poc-vm-data
  namespace: poc-vm
spec:
  accessModes:
    - ReadWriteMany
  volumeMode: Block
  resources:
    requests:
      storage: 10Gi
  storageClassName: ocs-external-storagecluster-ceph-rbd
EOF

# Hot-plug disk to running VM
virtctl addvolume my-poc-vm \
  --volume-name=my-poc-vm-data \
  --disk-type=disk \
  -n poc-vm
```

### Add disk after VM stop (permanent attachment)

```bash
# Add disk directly to VM spec
oc patch vm my-poc-vm -n poc-vm --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/domain/devices/disks/-",
    "value": {"name": "datadisk", "disk": {"bus": "virtio"}}
  },
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "datadisk",
      "persistentVolumeClaim": {"claimName": "my-poc-vm-data"}
    }
  }
]'
```

### Verification

```bash
# Check disk inside VM
virtctl console my-poc-vm -n poc-vm
# lsblk
# fdisk -l
```

---

## 3. Network Addition (secondary NIC)

Connect `poc-bridge-nad` as a secondary network to the VM.

> If the VM is running, stop it first before making changes.

```bash
# Stop VM
virtctl stop my-poc-vm -n poc-vm

# Add secondary NIC
oc patch vm my-poc-vm -n poc-vm --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/domain/devices/interfaces/-",
    "value": {"name": "bridge-net", "bridge": {}, "model": "virtio"}
  },
  {
    "op": "add",
    "path": "/spec/template/spec/networks/-",
    "value": {
      "name": "bridge-net",
      "multus": {"networkName": "poc-bridge-nad"}
    }
  }
]'

# Start VM
virtctl start my-poc-vm -n poc-vm
```

### Verification

```bash
# Check NIC in VMI
oc get vmi my-poc-vm -n poc-vm \
  -o jsonpath='{range .status.interfaces[*]}{.name}: {.ipAddress}{"\n"}{end}'
```

---

## 4. Static IP / Domain / Router Configuration

Configure a static IP on the secondary NIC (`eth1`).
Configure via cloud-init during initial setup, or set directly inside the VM.

> The ConsoleYAMLSample VM created by `03-vm-workload.sh` already includes cloud-init networkData.

### Method A — Initial configuration via cloud-init networkData

Add `networkData` to the existing `cloudinitdisk` volume when creating the VM.
Since it must be applied **before VM boot**, patch it in `runStrategy: Halted` state and then start.

```bash
# Create VM (Halted state)
oc process -n openshift poc \
  -p NAME=my-poc-vm \
  | sed 's/  running: false/  runStrategy: Halted/' \
  | oc apply -n poc-vm -f -

# Check cloudinitdisk volume index (grep -n is 1-based → convert to 0-based)
CI_IDX=$(oc get vm my-poc-vm -n poc-vm \
  -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' | \
  grep -n "cloudinitdisk" | cut -d: -f1 | head -1)
CI_IDX=$(( CI_IDX - 1 ))

# Add networkData to existing cloudinitdisk (before VM start)
oc patch vm my-poc-vm -n poc-vm --type=json -p="[
  {\"op\": \"add\",
   \"path\": \"/spec/template/spec/volumes/${CI_IDX}/cloudInitNoCloud/networkData\",
   \"value\": \"version: 2\nethernets:\n  eth1:\n    dhcp4: false\n    addresses:\n      - 192.168.100.10/24\n    gateway4: 192.168.100.1\n    nameservers:\n      addresses:\n        - 8.8.8.8\n\"}
]"

# Start VM
virtctl start my-poc-vm -n poc-vm
```

The resulting `cloudinitdisk` volume is configured as follows:

```yaml
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
            - 192.168.100.10/24
          gateway4: 192.168.100.1
          nameservers:
            addresses:
              - 8.8.8.8
```

### Method B — Configure via nmcli inside the VM

Connect to the VM console and configure directly.

```bash
virtctl console my-poc-vm -n poc-vm
```

Inside the VM:

```bash
# Check secondary NIC name (eth1 or ens3, etc.)
ip link show

# Configure static IP
nmcli con add type ethernet ifname eth1 con-name eth1-static \
  ip4 192.168.100.10/24 gw4 192.168.100.1

# Configure DNS
nmcli con mod eth1-static ipv4.dns "8.8.8.8 8.8.4.4"
nmcli con mod eth1-static ipv4.dns-search "poc.example.com"

# Activate
nmcli con up eth1-static

# Set hostname
hostnamectl set-hostname my-poc-vm.poc.example.com

# Verify
ip addr show eth1
ip route
cat /etc/resolv.conf
```

### Router (gateway) configuration

```bash
# Route specific subnets through secondary NIC
ip route add 10.0.0.0/8 via 192.168.100.1 dev eth1

# Persistent configuration (nmcli)
nmcli con mod eth1-static +ipv4.routes "10.0.0.0/8 192.168.100.1"
nmcli con up eth1-static
```

---

## 5. Live Migration

Move a VM to another node without interruption.

### Prerequisites check

```bash
# Check current node running the VM
oc get vmi my-poc-vm -n poc-vm \
  -o jsonpath='{.status.nodeName}{"\n"}'

# Check storage ReadWriteMany (required for Live Migration)
oc get pvc -n poc-vm
```

### Execute Live Migration

```bash
# Start migration with virtctl
virtctl migrate my-poc-vm -n poc-vm

# Or create VirtualMachineInstanceMigration object directly
oc apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: my-poc-vm-migration
  namespace: poc-vm
spec:
  vmiName: my-poc-vm
EOF
```

### Check Migration Status

```bash
# Migration progress
oc get vmim -n poc-vm

# Detailed check
oc describe vmim my-poc-vm-migration -n poc-vm

# Verify node change after migration completes
oc get vmi my-poc-vm -n poc-vm \
  -o jsonpath='{.status.nodeName}{"\n"}'
```

### Cancel Migration

```bash
virtctl migrate-cancel my-poc-vm -n poc-vm
```

---

## Status Check Commands

```bash
# VM / VMI overall status
oc get vm,vmi -n poc-vm

# VM events
oc describe vm my-poc-vm -n poc-vm

# VM Runner Pod logs
oc logs -n poc-vm \
  $(oc get pod -n poc-vm -l vm.kubevirt.io/name=my-poc-vm -o name)

# DataVolume status (root disk clone progress)
oc get dv -n poc-vm
```

---

## Rollback

```bash
# Stop and delete VM
virtctl stop my-poc-vm -n poc-vm
oc delete vm my-poc-vm -n poc-vm

# Delete DataVolume (root disk)
oc delete dv my-poc-vm -n poc-vm

# Delete additional PVC
oc delete pvc my-poc-vm-data -n poc-vm

# Delete NAD
oc delete net-attach-def poc-bridge-nad -n poc-vm

# Delete namespace
oc delete namespace poc-vm
```
