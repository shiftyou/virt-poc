# Self Node Remediation (SNR) Operator Installation

## Overview

Self Node Remediation (SNR) is an Operator where a node restarts itself to recover when a node failure occurs.
Unlike FAR, it operates without external IPMI, detecting failed nodes through inter-node communication and restarting them.

---

## Prerequisites

- cluster-admin privileges
- openshift-workload-availability namespace (shared with FAR)

---

## Installation Methods

### Method 1: OpenShift Console (Web UI)

1. Navigate to **Operators > OperatorHub** menu
2. Search for `Self Node Remediation`
3. Select **Self Node Remediation Operator**
4. Click `Install`
5. Settings:
   - Installation mode: `All namespaces on the cluster`
   - Installed Namespace: `openshift-workload-availability`
6. Click `Install`

### Method 2: CLI (YAML)

```bash
# Create Namespace if it does not exist (shared with FAR)
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-workload-availability
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# OperatorGroup (shared with FAR, skip if already exists)
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: workload-availability
  namespace: openshift-workload-availability
spec:
  targetNamespaces:
    - openshift-workload-availability
EOF

# Create Subscription
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: self-node-remediation-operator
  namespace: openshift-workload-availability
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: self-node-remediation-operator
  channel: "stable"
EOF
```

---

## Verify Installation

```bash
# Check CSV status
oc get csv -n openshift-workload-availability | grep self-node

# Check SNR DaemonSet (deployed on all nodes)
oc get daemonset -n openshift-workload-availability | grep self-node

# Check SNR Pod status
oc get pods -n openshift-workload-availability | grep self-node
```

---

## SNR Configuration

After installation, running apply.sh in the `01-environment/snr/` directory
will create SNR settings and the **Node Health Check (NHC)** CR together.

```bash
cd 01-environment/snr
./apply.sh
```

> **The NHC (Node Health Check) Operator must also be installed** for automatic recovery to work.
> NHC detects the node state and triggers SNR.
> → Refer to [06-nhc-operator.md](./06-nhc-operator.md)

---

## Troubleshooting

```bash
# Check SNR Operator logs
oc logs -n openshift-workload-availability deployment/self-node-remediation-operator-controller-manager

# Check SNR DaemonSet Pod logs
oc logs -n openshift-workload-availability -l app.kubernetes.io/name=self-node-remediation

# Check SelfNodeRemediation status
oc get selfnoderemediation -A
```
