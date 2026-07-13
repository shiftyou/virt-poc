# Node Health Check (NHC) Operator Installation

## Overview

The Node Health Check (NHC) Operator continuously monitors node status and
triggers a remediation template (SNR or FAR) when it detects an abnormal node.

SNR/FAR defines the **method** of recovery, while NHC determines the **timing** of recovery.
Both Operators must be used together to complete automatic recovery.

```
NHC (detection) → SNR/FAR Template (execute recovery)
```

---

## Prerequisites

- Self Node Remediation Operator or FAR Operator installation complete
- `openshift-workload-availability` namespace exists

---

## Installation Methods

### Method 1: OpenShift Console (Web UI)

1. Navigate to **Operators > OperatorHub** menu
2. Search for `Node Health Check`
3. Select **Node Health Check Operator**
4. Click `Install`
5. Settings:
   - Installation mode: `All namespaces on the cluster`
   - Installed Namespace: `openshift-workload-availability`
6. Click `Install`

### Method 2: CLI (YAML)

```bash
# Create Namespace (skip if already exists)
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-workload-availability
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# OperatorGroup (skip if already exists)
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
  name: node-healthcheck-operator
  namespace: openshift-workload-availability
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: node-healthcheck-operator
  channel: "stable"
EOF
```

---

## Verify Installation

```bash
# Check CSV status (should be Succeeded)
oc get csv -n openshift-workload-availability | grep node-health

# Check NHC Controller Pod
oc get pods -n openshift-workload-availability | grep node-health
```

---

## NHC Configuration

After installation, running apply.sh in the `01-environment/snr/` directory
will create the NHC CR together.

```bash
cd 01-environment/snr
./apply.sh
```

---

## Troubleshooting

```bash
# Check NHC Controller logs
oc logs -n openshift-workload-availability \
  deployment/node-healthcheck-operator-controller-manager

# Check NodeHealthCheck status
oc get nodehealthcheck -A

# Check node Condition (whether abnormality is detected)
oc get nodes -o custom-columns="NAME:.metadata.name,READY:.status.conditions[?(@.type=='Ready')].status"

# Check remediation history
oc get events -n openshift-workload-availability | grep -i remediat
```
