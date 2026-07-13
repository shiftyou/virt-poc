# Descheduler Practice

A practice where KubeDescheduler detects node load and automatically relocates VMs.

```
Step 1: Start 3 VMs on any node without nodeSelector
┌──────────────────┐     ┌──────────────────────────────┐
│  NODE1           │     │  NODE2, ...                  │
│                  │     │                              │
│  (empty)         │     │  ● vm-1   (deployed)         │
│                  │     │  ● vm-2   (deployed)         │
│                  │     │  ● vm-fixed (deployed)       │
└──────────────────┘     └──────────────────────────────┘

Step 2: Live Migrate all 3 VMs to NODE1 (temporarily apply nodeSelector)
┌─────────────────────────────────┐     ┌──────────────┐
│  NODE1 (TEST_NODE)              │     │  NODE2, ...  │
│                                 │     │              │
│  ● vm-1        (250m CPU)       │     │  (available) │
│  ● vm-2        (250m CPU)       │     │              │
│  ● vm-fixed    (250m CPU) [evict=false] │     │      │
│                                 │     │              │
│  Migration complete → remove nodeSelector   │        │
└─────────────────────────────────┘     └──────────────┘

Step 3: Deploy trigger VM on NODE1 → CPU exceeds 70%
┌─────────────────────────────────┐     ┌──────────────┐
│  NODE1                          │     │  NODE2, ...  │
│                                 │     │              │
│  ● vm-1        (250m CPU)       │     │  (available) │
│  ● vm-2        (250m CPU)       │     │              │
│  ● vm-fixed    (250m CPU) [evict=false] │     │      │
│  ● vm-trigger  (calculated CPU) │     │              │
│                                 │     │              │
│  CPU usage > 70%  ← threshold exceeded │            │
└─────────────────────────────────┘     └──────────────┘

Step 4: Descheduler triggers (within 60 seconds)
┌─────────────────────────────────┐     ┌──────────────────────┐
│  NODE1                          │     │  NODE2, ...          │
│                                 │     │                      │
│  ● vm-fixed   (annotation protected) │  ● vm-1  (Migration) │
│  ● vm-trigger (newest → retained)   │  ● vm-2  (Migration)  │
└─────────────────────────────────┘     └──────────────────────┘
```

---

## Prerequisites

- `01-template` complete — poc Template and DataSource registered
- Kube Descheduler Operator installed (see `operators/descheduler-operator.md`)
- 2 or more worker nodes (destination nodes needed for VM relocation)
- `06-descheduler.sh` execution complete

---

## Configuration Overview

| VM | Node pinned | CPU request | Descheduler target | Reason |
|----|-------------|-------------|-------------------|--------|
| poc-descheduler-vm-1 | NODE1 | 250m | ✅ Target | no annotation |
| poc-descheduler-vm-2 | NODE1 | 250m | ✅ Target | no annotation |
| poc-descheduler-vm-fixed | NODE1 | 250m | ❌ Excluded | `descheduler.alpha.kubernetes.io/evict: "false"` |
| poc-descheduler-vm-trigger | NODE1 | calculated value | ✅ Potential target | deployed last |

---

## KubeDescheduler Configuration

```yaml
apiVersion: operator.openshift.io/v1
kind: KubeDescheduler
metadata:
  name: cluster
  namespace: openshift-kube-descheduler-operator
spec:
  managementState: Managed
  deschedulingIntervalSeconds: 60
  profiles:
    - LifecycleAndUtilization
  profileCustomizations:
    devLowNodeUtilizationThresholds: High
    namespaces:
      included:
        - poc-descheduler
```

### High Threshold Meaning

| Category | CPU | Memory | Pods |
|----------|-----|--------|------|
| **underutilized** (migration destination) | < 40% | < 40% | < 40% |
| **overutilized** (migration source) | > 70% | > 70% | > 70% |

When NODE1 CPU requests total exceeds **70%** of Allocatable → judged as overutilized → Live Migration of vm-1, vm-2 triggers

---

## Annotation — vm-fixed protection principle

```yaml
# VM spec.template.metadata.annotations
descheduler.alpha.kubernetes.io/evict: "false"
```

Adding the above annotation to the VM's Pod template excludes that Pod from Descheduler eviction targets.

```bash
# Patch applied in 06-descheduler.sh
oc patch vm poc-descheduler-vm-fixed -n poc-descheduler --type=merge -p '{
  "spec": {
    "template": {
      "metadata": {
        "annotations": {
          "descheduler.alpha.kubernetes.io/evict": "false"
        }
      }
    }
  }
}'
```

`descheduler.alpha.kubernetes.io/evict: "false"` → Descheduler excludes vm-fixed's virt-launcher Pod from eviction targets → stays on NODE1

---

## Practice Verification

### Initial state check

```bash
# Verify all VMs are placed on NODE1
oc get vmi -n poc-descheduler -o wide

# NODE1 CPU request status
NODE1=$(oc get node -l node-role.kubernetes.io/worker \
  -o jsonpath='{.items[0].metadata.name}')

oc get pods --all-namespaces \
  --field-selector="spec.nodeName=${NODE1}" \
  -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.containers[0].resources.requests.cpu}{"\n"}{end}'

# Per-node resource status
oc describe node $NODE1 | grep -A 10 "Allocated resources"
```

### Verify Descheduler operation (wait 60 seconds)

```bash
# Real-time monitoring of VM node changes
oc get vmi -n poc-descheduler -o wide --watch

# Check Descheduler events
oc get events -n poc-descheduler \
  --field-selector reason=Evicted \
  --sort-by='.lastTimestamp'

# Check Descheduler logs
oc logs -n openshift-kube-descheduler-operator \
  deployment/descheduler --tail=50
```

### Verify expected results

```bash
# Confirm vm-1, vm-2 moved to another node
oc get vmi -n poc-descheduler -o \
  custom-columns=NAME:.metadata.name,NODE:.status.nodeName,PHASE:.status.phase

# NAME                          NODE      PHASE
# poc-descheduler-vm-1          worker-1  Running   ← moved
# poc-descheduler-vm-2          worker-2  Running   ← moved
# poc-descheduler-vm-fixed      worker-0  Running   ← retained (PDB)
# poc-descheduler-vm-trigger    worker-0  Running   ← retained

# Check PDB status
oc get pdb -n poc-descheduler
```

### Check migration history

```bash
# VirtualMachineInstanceMigration records
oc get vmim -n poc-descheduler

# Migration details
oc describe vmim -n poc-descheduler
```

---

## Check and Adjust Descheduler Configuration

```bash
# Check current KubeDescheduler configuration
oc get kubedescheduler cluster \
  -n openshift-kube-descheduler-operator -o yaml

# Adjust interval (for faster testing: 30 seconds)
oc patch kubedescheduler cluster \
  -n openshift-kube-descheduler-operator \
  --type=merge \
  -p '{"spec":{"deschedulingIntervalSeconds":30}}'

# Restart Descheduler Pod
oc rollout restart deployment/descheduler \
  -n openshift-kube-descheduler-operator
```

---

## Troubleshooting

```bash
# When Descheduler is not working
oc logs -n openshift-kube-descheduler-operator \
  deployment/descheduler | grep -E "evict|migrate|error|LowNode"

# Check VM evictionStrategy
oc get vm -n poc-descheduler -o \
  jsonpath='{range .items[*]}{.metadata.name}: {.spec.template.spec.evictionStrategy}{"\n"}{end}'
# → All should be LiveMigrate

# Check PDB status (should only have vm-fixed)
oc get pdb -n poc-descheduler

# Check node taints (cause of Migration failure)
oc get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

---

## Rollback

```bash
# Reset KubeDescheduler configuration (remove namespace restriction)
oc patch kubedescheduler cluster \
  -n openshift-kube-descheduler-operator \
  --type=merge \
  -p '{"spec":{"profileCustomizations":{"namespaces":null}}}'

# Delete VMs and namespace
oc delete namespace poc-descheduler
```

---

## DevKubeVirtRelieveAndMigrate Profile

When using the `DevKubeVirtRelieveAndMigrate` profile, the Descheduler detects node pressure based on PSI (Pressure Stall Information) and automatically migrates VMs.
To use this profile, the kernel parameter `psi=1` must be enabled on worker nodes.

Apply the following MachineConfig first:

```bash
oc apply -f - <<'EOF'
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-openshift-machineconfig-worker-psi-karg
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  kernelArguments:
  - psi=1
EOF
```

> **Note**: When MachineConfig is applied, the Machine Config Operator sequentially restarts worker nodes (drain → reboot → uncordon).
> Configure Descheduler after all worker node restarts are complete (`oc get mcp worker` status shows `UPDATED=True`).

```bash
# Check MachineConfigPool status (wait until UPDATED=True)
oc get mcp worker -w

# Apply DevKubeVirtRelieveAndMigrate profile to KubeDescheduler
oc patch kubedescheduler cluster \
  -n openshift-kube-descheduler-operator \
  --type=merge \
  -p '{"spec":{"profiles":["DevKubeVirtRelieveAndMigrate"]}}'
```
