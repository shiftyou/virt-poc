# Node Maintenance Lab

This lab uses the Node Maintenance Operator to safely put a worker node into maintenance mode
and demonstrates the process of VMs automatically migrating to another node via Live Migration.

```
Step 1: VM is running on the maintenance target node
┌──────────────────────────────────┐     ┌──────────────┐
│  NODE1 (maintenance target)       │     │  NODE2       │
│                                  │     │              │
│  ● poc-maintenance-vm-1 (Running) │     │  (available) │
│  ● poc-maintenance-vm-2 (Running) │     │              │
└──────────────────────────────────┘     └──────────────┘

Step 2: NodeMaintenance created → cordon + drain triggered
┌──────────────────────────────────┐     ┌──────────────────────────────────┐
│  NODE1 (SchedulingDisabled)      │     │  NODE2                           │
│                                  │     │                                  │
│  ● poc-maintenance-vm-1          │ ──▶ │  ● poc-maintenance-vm-1 (Migration) │
│  ● poc-maintenance-vm-2          │ ──▶ │  ● poc-maintenance-vm-2 (Migration) │
└──────────────────────────────────┘     └──────────────────────────────────┘

Step 3: Maintenance complete → NodeMaintenance deleted → uncordon
┌──────────────────────────────────┐     ┌──────────────────────────────────┐
│  NODE1 (Ready)                   │     │  NODE2                           │
│                                  │     │                                  │
│  (empty)                         │     │  ● poc-maintenance-vm-1 (Running) │
│                                  │     │  ● poc-maintenance-vm-2 (Running) │
└──────────────────────────────────┘     └──────────────────────────────────┘
```

---

## Prerequisites

- `01-template` completed — `poc` Template and DataSource registered
- Node Maintenance Operator installed (`operators/node-maintenance-operator.md` for reference)
- 2 or more worker nodes
- `13-node-maintenance.sh` execution completed

---

## Configuration Overview

| VM | evictionStrategy | Description |
|----|-----------------|------|
| poc-maintenance-vm-1 | LiveMigrate | Automatic Migration target during maintenance |
| poc-maintenance-vm-2 | LiveMigrate | Automatic Migration target during maintenance |

---

## NodeMaintenance Operation Principle

```yaml
apiVersion: nodemaintenance.medik8s.io/v1beta1
kind: NodeMaintenance
metadata:
  name: maintenance-<node-name>
spec:
  nodeName: <node-name>
  reason: "Hardware inspection"
```

When a NodeMaintenance object is created:

1. **Cordon** — Changes node to `SchedulingDisabled` state (blocks new Pod scheduling)
2. **Drain** — Evicts Pods from the node in order
3. **VM Live Migration** — VMs with `evictionStrategy: LiveMigrate` automatically migrate to another node

---

## Lab Procedure

### 1. Verify VM Placement

```bash
# Check the maintenance target node
TEST_NODE=$(oc get node -l node-role.kubernetes.io/worker \
  -o jsonpath='{.items[0].metadata.name}')
echo "Target node: ${TEST_NODE}"

# Check VM placement
oc get vmi -n poc-maintenance -o wide
```

### 2. Start NodeMaintenance

```bash
TEST_NODE=$(oc get node -l node-role.kubernetes.io/worker \
  -o jsonpath='{.items[0].metadata.name}')

cat <<EOF | oc apply -f -
apiVersion: nodemaintenance.medik8s.io/v1beta1
kind: NodeMaintenance
metadata:
  name: maintenance-${TEST_NODE}
spec:
  nodeName: ${TEST_NODE}
  reason: "POC maintenance lab"
EOF
```

### 3. Verify Maintenance Progress

```bash
# Check NodeMaintenance status
oc get nodemaintenance
oc describe nodemaintenance maintenance-${TEST_NODE}

# Check node status (SchedulingDisabled)
oc get node ${TEST_NODE}

# Real-time monitoring of VM Migration progress
oc get vmi -n poc-maintenance -o wide --watch
```

### 4. Verify Migration Complete

```bash
# Verify VMs have moved to another node
oc get vmi -n poc-maintenance \
  -o custom-columns=NAME:.metadata.name,NODE:.status.nodeName,PHASE:.status.phase

# Check Migration history
oc get vmim -n poc-maintenance
```

### 5. End Maintenance (uncordon)

```bash
# Delete NodeMaintenance → recover node
oc delete nodemaintenance maintenance-${TEST_NODE}

# Verify node Ready status
oc get node ${TEST_NODE}
```

---

## Status Check Commands

```bash
# Full list of NodeMaintenance
oc get nodemaintenance

# Node status (Cordon status)
oc get nodes

# VM Migration records
oc get vmim -n poc-maintenance

# Migration details
oc describe vmim -n poc-maintenance

# Check events
oc get events -n poc-maintenance \
  --sort-by='.lastTimestamp' | tail -20
```

---

## Troubleshooting

```bash
# When VM is not migrating — check evictionStrategy
oc get vm -n poc-maintenance \
  -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.template.spec.evictionStrategy}{"\n"}{end}'
# → All must be LiveMigrate

# When drain stalls — check PodDisruptionBudget
oc get pdb -A

# Node Maintenance Operator logs
oc logs -n openshift-operators \
  deployment/node-maintenance-operator -f

# Force uncordon (emergency recovery)
oc adm uncordon ${TEST_NODE}
```

---

## Rollback

```bash
# Delete NodeMaintenance (end maintenance)
oc delete nodemaintenance --all

# Delete VMs and namespace
oc delete namespace poc-maintenance
```
