# Fence Agents Remediation (FAR) Lab

This lab demonstrates how the Node Health Check Operator detects an unhealthy node
and FAR automatically recovers it by forcibly restarting (fencing) the node via IPMI/BMC.

```
NHC (detection) → FenceAgentsRemediationTemplate (IPMI fencing)

Step 1: Normal state
┌───────────────────────────┐     ┌──────────────┐
│  NODE1 (Ready)            │     │  NODE2       │
│  ● poc-far-vm-1 (Running) │     │  (available) │
│  ● poc-far-vm-2 (Running) │     │              │
└───────────────────────────┘     └──────────────┘

Step 2: NODE1 failure simulation (kubelet stopped)
┌───────────────────────────┐     ┌──────────────┐
│  NODE1 (NotReady)         │     │  NODE2       │
│  ✗ kubelet stopped        │     │  (available) │
└───────────────────────────┘     └──────────────┘
         │
         ▼  NHC detects (unhealthy condition met)
         ▼  FenceAgentsRemediation created
         ▼  IPMI/BMC → Physical node power restart

Step 3: Recovery complete
┌───────────────────────────┐     ┌──────────────┐
│  NODE1 (Ready, after reboot) │  │  NODE2       │
│  ● poc-far-vm-1 (Running) │     │  (available) │
│  ● poc-far-vm-2 (Running) │     │              │
└───────────────────────────┘     └──────────────┘
```

---

## Prerequisites

- `01-template` completed — `poc` Template and DataSource registered
- Fence Agents Remediation Operator installed (`operators/far-operator.md` for reference)
- Node Health Check Operator installed (`operators/nhc-operator.md` for reference)
- IPMI/BMC accessible on worker nodes
- `FENCE_AGENT_IP`, `FENCE_AGENT_USER`, `FENCE_AGENT_PASS` configured in `env.conf`
- `16-far.sh` execution completed

---

## Configuration Overview

| Resource | Namespace | Role |
|--------|------------|------|
| Secret `poc-far-credentials` | `openshift-workload-availability` | Secure storage of IPMI `--password` |
| FenceAgentsRemediationTemplate | `openshift-workload-availability` | Defines IPMI fencing method |
| NodeHealthCheck | cluster-scoped | Detects node status + FAR trigger condition |

---

## FAR vs SNR Comparison

| Item | FAR | SNR |
|------|-----|-----|
| Recovery method | IPMI/BMC power control | Node self-restart |
| External hardware required | Required (BMC) | Not required |
| Recovery reliability | High (hardware level) | Medium (OS level) |
| Applicable environment | Bare metal | Bare metal / Virtual |

---

## IPMI Credentials Secret

The password is managed separately as a Secret. The IPMI password is stored in the `--password` key.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: poc-far-credentials
  namespace: openshift-workload-availability
stringData:
  --password: "<FENCE_AGENT_PASS>"
```

```bash
oc create secret generic poc-far-credentials \
  -n openshift-workload-availability \
  --from-literal=--password=<FENCE_AGENT_PASS>
```

---

## FenceAgentsRemediationTemplate

```yaml
apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
kind: FenceAgentsRemediationTemplate
metadata:
  annotations:
    remediation.medik8s.io/multiple-templates-support: "true"
  name: poc-far-template
  namespace: openshift-workload-availability
spec:
  template:
    spec:
      agent: fence_ipmilan
      nodeparameters:
        --ip:
          <worker-node-fqdn-1>: <bmc-ip-1>
          <worker-node-fqdn-2>: <bmc-ip-2>
          <worker-node-fqdn-3>: <bmc-ip-3>
      remediationStrategy: ResourceDeletion
      retrycount: 5
      retryinterval: 5s
      sharedSecretName: poc-far-credentials
      sharedparameters:
        --action: reboot
        --lanplus: ""
        --username: <FENCE_AGENT_USER>
      timeout: 1m0s
```

- `nodeparameters[--ip]`: Node FQDN → BMC IP mapping (specify BMC IP per node)
- `sharedSecretName`: Name of Secret containing `--password`
- `sharedparameters`: Parameters applied commonly to all nodes (excluding password)
- `agent`: Choose from `fence_ipmilan`, `fence_idrac`, `fence_ilo`, etc. depending on IPMI environment

---

## NodeHealthCheck Settings

```yaml
apiVersion: remediation.medik8s.io/v1alpha1
kind: NodeHealthCheck
metadata:
  name: poc-far-nhc
spec:
  remediationTemplate:
    apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
    kind: FenceAgentsRemediationTemplate
    name: poc-far-template
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
oc get nodehealthcheck poc-far-nhc

# Check FAR Template
oc get fenceagentsremediationtemplate -n openshift-workload-availability

# Check VM placement
oc get vmi -n poc-far -o wide

# Test IPMI connection
ipmitool -I lanplus -H ${FENCE_AGENT_IP} \
  -U ${FENCE_AGENT_USER} -P ${FENCE_AGENT_PASS} chassis power status
```

### Node Failure Simulation

```bash
# Stop kubelet on TEST_NODE (run directly on the node)
oc debug node/${TEST_NODE} -- chroot /host systemctl stop kubelet

# Check node status (verify change to NotReady)
oc get nodes -w
```

### Verify NHC → FAR Triggered

```bash
# Check NHC status (whether unhealthy is detected)
oc get nodehealthcheck poc-far-nhc -o yaml | grep -A 20 status

# Verify FenceAgentsRemediation CR creation (auto-created by NHC)
oc get fenceagentsremediation -A

# Check FAR events
oc get events -n openshift-workload-availability \
  --sort-by='.lastTimestamp' | grep -i remediat

# Verify IPMI fencing execution
oc logs -n openshift-workload-availability \
  deployment/fence-agents-remediation-operator-controller-manager --tail=50
```

### Verify After Recovery

```bash
# Verify node recovery (returns to Ready)
oc get nodes

# Check VM status (returns to Running after restart)
oc get vmi -n poc-far -o wide

# Verify FenceAgentsRemediation CR auto-deleted
oc get fenceagentsremediation -A
```

---

## Troubleshooting

```bash
# FAR Operator logs
oc logs -n openshift-workload-availability \
  deployment/fence-agents-remediation-operator-controller-manager --tail=50

# NHC Controller logs
oc logs -n openshift-workload-availability \
  deployment/node-healthcheck-operator-controller-manager --tail=50

# FAR CR details
oc describe fenceagentsremediation -A

# Direct IPMI test
ipmitool -I lanplus -H ${FENCE_AGENT_IP} \
  -U ${FENCE_AGENT_USER} -P ${FENCE_AGENT_PASS} chassis power status

# Check node reboot history
oc debug node/${TEST_NODE} -- chroot /host last reboot | head -5
```

---

## Rollback

```bash
# Delete NodeHealthCheck
oc delete nodehealthcheck poc-far-nhc

# Delete FenceAgentsRemediationTemplate
oc delete fenceagentsremediationtemplate poc-far-template \
  -n openshift-workload-availability

# Delete VMs and namespace
oc delete namespace poc-far
```
