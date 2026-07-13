# Self Node Remediation (SNR) Lab

This lab demonstrates how the Node Health Check Operator detects an unhealthy node
and Self Node Remediation automatically recovers it by restarting the node itself.

```
NHC (detection) → SelfNodeRemediationTemplate (execute recovery)

Step 1: Normal state
┌───────────────────────────┐     ┌──────────────┐
│  NODE1 (Ready)            │     │  NODE2       │
│  ● poc-snr-vm-1 (Running) │     │  (available) │
│  ● poc-snr-vm-2 (Running) │     │              │
└───────────────────────────┘     └──────────────┘

Step 2: NODE1 failure simulation (kubelet stopped)
┌───────────────────────────┐     ┌──────────────┐
│  NODE1 (NotReady)         │     │  NODE2       │
│  ✗ kubelet stopped        │     │  (available) │
└───────────────────────────┘     └──────────────┘
         │
         ▼  NHC detects (unhealthy condition met)
         ▼  SelfNodeRemediation created
         ▼  NODE1 self-restarts (watchdog / reboot)

Step 3: Recovery complete
┌───────────────────────────┐     ┌──────────────┐
│  NODE1 (Ready, after restart) │  │  NODE2       │
│  ● poc-snr-vm-1 (Running) │     │  (available) │
│  ● poc-snr-vm-2 (Running) │     │              │
└───────────────────────────┘     └──────────────┘
```

---

## Prerequisites

- `01-template` completed — `poc` Template and DataSource registered
- Self Node Remediation Operator installed (`operators/snr-operator.md` for reference)
- Node Health Check Operator installed (`operators/nhc-operator.md` for reference)
- 2 or more worker nodes
- `14-snr.sh` execution completed

---

## Configuration Overview

| Resource | Role |
|--------|------|
| SelfNodeRemediationTemplate | Defines SNR recovery method |
| NodeHealthCheck | Detects node status + SNR trigger condition |
| poc-snr-vm-1, vm-2 | Recovery target VMs (placed on NODE1) |

---

## SNR Operation Principle

```
NHC monitors nodes
  └─ Condition met (e.g.: Ready=False for 300s or more)
       └─ SelfNodeRemediation CR created
            └─ SNR DaemonSet (Pod on that node) detects it
                 └─ Node self-restarts (watchdog or reboot)
                      └─ Returns to Ready after restart
```

SNR operates **without external IPMI**. It self-recovers using the node's watchdog device or direct reboot.

---

## SelfNodeRemediationTemplate

```yaml
apiVersion: self-node-remediation.medik8s.io/v1alpha1
kind: SelfNodeRemediationTemplate
metadata:
  name: poc-snr-template
  namespace: openshift-workload-availability
spec:
  template:
    spec:
      remediationStrategy: ResourceDeletion
```

`remediationStrategy`:
- `ResourceDeletion`: Force-deletes Pods/VolumeAttachments on the node then restarts (default)
- `OutOfServiceTaint`: Adds `node.kubernetes.io/out-of-service` taint → force delete

---

## NodeHealthCheck Settings

```yaml
apiVersion: remediation.medik8s.io/v1alpha1
kind: NodeHealthCheck
metadata:
  name: poc-snr-nhc
spec:
  remediationTemplate:
    apiVersion: self-node-remediation.medik8s.io/v1alpha1
    kind: SelfNodeRemediationTemplate
    name: poc-snr-template
    namespace: openshift-workload-availability
  selector:
    matchExpressions:
      - key: node-role.kubernetes.io/worker
        operator: Exists
  unhealthyConditions:
    - type: Ready
      status: "False"
      duration: 300s
    - type: Ready
      status: Unknown
      duration: 300s
```

---

## Lab Verification

### Initial State Check

```bash
# Check NHC status
oc get nodehealthcheck poc-snr-nhc

# Check SNR Template
oc get selfnoderemediationtemplate -n openshift-workload-availability

# Check VM placement
oc get vmi -n poc-snr -o wide
```

### Node Failure Simulation

```bash
# Stop kubelet on TEST_NODE (run directly on the node)
oc debug node/${TEST_NODE} -- chroot /host systemctl stop kubelet

# Check node status (verify change to NotReady)
oc get nodes -w
```

### Verify NHC → SNR Triggered

```bash
# Check NHC status (whether unhealthy is detected)
oc get nodehealthcheck poc-snr-nhc -o yaml | grep -A 20 status

# Verify SelfNodeRemediation CR creation (auto-created by NHC)
oc get selfnoderemediation -A

# Check SNR events
oc get events -n openshift-workload-availability \
  --sort-by='.lastTimestamp' | grep -i remediat

# Check NHC events
oc describe nodehealthcheck poc-snr-nhc | grep -A 20 "Events:"
```

### Verify After Recovery

```bash
# Verify node recovery (returns to Ready)
oc get nodes

# Check VM status (returns to Running after restart)
oc get vmi -n poc-snr -o wide

# Verify SelfNodeRemediation CR auto-deleted
oc get selfnoderemediation -A
```

---

## Troubleshooting

```bash
# NHC Controller logs
oc logs -n openshift-workload-availability \
  deployment/node-healthcheck-operator-controller-manager --tail=50

# SNR DaemonSet Pod logs (for the affected node)
oc logs -n openshift-workload-availability \
  -l app.kubernetes.io/name=self-node-remediation \
  --tail=50

# SNR details
oc describe selfnoderemediation -A

# Check node restart history
oc debug node/${TEST_NODE} -- chroot /host last reboot | head -5
```

---

## Rollback

```bash
# Delete NodeHealthCheck
oc delete nodehealthcheck poc-snr-nhc

# Delete SelfNodeRemediationTemplate
oc delete selfnoderemediationtemplate poc-snr-template \
  -n openshift-workload-availability

# Delete VMs and namespace
oc delete namespace poc-snr
```
