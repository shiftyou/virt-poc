# Migration Toolkit for Virtualization (MTV) Lab

This is a lab for migrating VMs from VMware to OpenShift Virtualization.

```
VMware vSphere
  └─ VM (Windows/Linux)
       │  MTV Provider registration
       ▼
Migration Toolkit for Virtualization
  └─ Migration Plan creation
       │  Cold Migration or Warm Migration
       ▼
OpenShift Virtualization
  └─ VirtualMachine (poc-mtv namespace)
```

---

## Prerequisites

- MTV Operator installed (`operators/mtv-operator.md` for reference)
- vSphere access information (vCenter URL, username/password)
- VMware VDDK image (`VDDK_IMAGE` in `env.conf`)
- `11-mtv.sh` execution completed

---

## ⚠️ Required Checklist Before VMware Migration

Please verify the following **before migration** to prevent migration failures and data loss.

---

### 1. Disable Hot-plug (VMware)

**You must disable CPU Hot-plug / Memory Hot-plug** on the VM targeted for migration.

If Hot-plug is enabled during migration,
the VM will not start properly in OpenShift Virtualization.

**Disable via Console:**
1. vCenter → Right-click VM → **Edit Settings**
2. **VM Options** tab → **Advanced** → **Edit Configuration**
3. Check and change the following parameters:

```
cpuid.coresPerSocket = <cores per socket>
vcpu.hotadd          = FALSE    ← Disable Hot-plug CPU
mem.hotadd           = FALSE    ← Disable Hot-plug Memory
```

Or shut down the VM and uncheck **Edit Settings → CPU/Memory → Enable CPU/Memory Hot Add**

---

### 2. Enable Shared Disk (Multi-writer) — Required for Warm Migration

To use Warm Migration, you must **enable Shared Disk (Multi-writer)** for VMDK snapshots.

> Not applicable for Cold Migration.

**vSphere settings:**
1. vCenter → Right-click VM → **Edit Settings**
2. Select disk → **Advanced** → **Sharing** → Select **Multi-writer**

Or add directly to `.vmx` file:

```
diskN.shared = "multi-writer"
```

---

### 3. Windows VM — Disable Fast Startup + Normal Shutdown

When migrating a Windows VM, you must complete both of the following.

#### 3-1. Disable Fast Startup

If Fast Startup is enabled during migration, the disk is copied in hibernation state,
which prevents normal booting in OpenShift.

**Configure within Windows:**
```
Control Panel → Power Options → Choose what the power buttons do → Uncheck Turn on fast startup (recommended)
```

Or PowerShell:
```powershell
powercfg /hibernate off
```

#### 3-2. Normal Shutdown Before Migration

After disabling Fast Startup, **perform a full Shutdown** before migration.
It must be Shutdown, not Restart.

```powershell
# Full shutdown from PowerShell
Stop-Computer -Force
```

---

### 4. Warm Migration — Enable vSphere CBT (Changed Block Tracking)

Warm Migration gradually migrates a VM while it is running.
For this, you must enable **CBT (Changed Block Tracking)** in vSphere.

Without CBT, the entire disk is copied repeatedly, making Warm Migration inefficient.

**How to enable CBT:**

Shut down the VM and add to `.vmx` file, or configure via vSphere API:

```
ctkEnabled = "TRUE"
scsiN:M.ctkEnabled = "TRUE"
```

Or PowerCLI:
```powershell
$vm = Get-VM -Name "target-vm"
$spec = New-Object VMware.Vim.VirtualMachineConfigSpec
$spec.changeTrackingEnabled = $true
$vm.ExtensionData.ReconfigVM($spec)
```

**Verify:**
```powershell
(Get-VM "target-vm").ExtensionData.Config.ChangeTrackingEnabled
# → Must be True
```

> After enabling CBT, **create and delete a snapshot once** for CBT to take actual effect.

---

## MTV Configuration

### Provider Registration

```bash
source env.conf

# Create vSphere Provider Secret
oc create secret generic vsphere-secret \
  -n openshift-mtv \
  --from-literal=user=<vCenter_user> \
  --from-literal=password=<vCenter_password> \
  --from-literal=cacert="" \
  --from-literal=insecureSkipVerify=true

# Register vSphere Provider
oc apply -f - <<EOF
apiVersion: forklift.konveyor.io/v1beta1
kind: Provider
metadata:
  name: vsphere-provider
  namespace: openshift-mtv
spec:
  type: vsphere
  url: https://<vCenter_IP>/sdk
  secret:
    name: vsphere-secret
    namespace: openshift-mtv
EOF
```

### Register VDDK ConfigMap

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: vddk-config
  namespace: openshift-mtv
data:
  vddkInitImage: ${VDDK_IMAGE}
EOF
```

### Create Migration Plan (Cold)

```bash
oc apply -f - <<EOF
apiVersion: forklift.konveyor.io/v1beta1
kind: Plan
metadata:
  name: poc-cold-migration
  namespace: openshift-mtv
spec:
  provider:
    source:
      name: vsphere-provider
      namespace: openshift-mtv
    destination:
      name: host
      namespace: openshift-mtv
  targetNamespace: poc-mtv
  map:
    network:
      name: poc-network-map
      namespace: openshift-mtv
    storage:
      name: poc-storage-map
      namespace: openshift-mtv
  vms:
    - id: <vm-moref-id>
EOF
```

---

## Lab Verification

```bash
# Check Provider status
oc get provider -n openshift-mtv

# Check Migration Plan status
oc get plan -n openshift-mtv

# Check Migration progress
oc get migration -n openshift-mtv

# Check migrated VMs
oc get vm -n poc-mtv
```

---

## Troubleshooting

```bash
# MTV Controller logs
oc logs -n openshift-mtv deployment/forklift-controller --tail=50

# Verify VDDK image
oc get configmap vddk-config -n openshift-mtv -o yaml

# Provider status details
oc describe provider vsphere-provider -n openshift-mtv

# Migration failure events
oc get events -n openshift-mtv --sort-by='.lastTimestamp' | tail -20
```

---

## Rollback

```bash
# Delete Migration Plan
oc delete plan poc-cold-migration -n openshift-mtv

# Delete Provider
oc delete provider vsphere-provider -n openshift-mtv
oc delete secret vsphere-secret -n openshift-mtv

# Delete migrated VMs
oc delete namespace poc-mtv
```
