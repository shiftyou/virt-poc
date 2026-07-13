# Kube Descheduler Operator Installation

## Overview

The Kube Descheduler Operator is an Operator that reschedules unevenly placed Pods
to optimize Pod distribution across the cluster.

Since VMs (VirtualMachineInstances) are managed like Pods, it is also used to optimize
node distribution for VMs.

---

## Prerequisites

- cluster-admin privileges

---

## Installation Methods

### Method 1: OpenShift Console (Web UI)

1. Navigate to **Operators > OperatorHub** menu
2. Search for `Kube Descheduler`
3. Select **Kube Descheduler Operator**
4. Click `Install`
5. Settings:
   - Update channel: `stable`
   - Installation mode: `All namespaces on the cluster`
   - Installed Namespace: `openshift-kube-descheduler-operator`
6. Click `Install`

### Method 2: CLI (YAML)

```bash
# 1. Create Namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-kube-descheduler-operator
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# 2. Create OperatorGroup
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kube-descheduler
  namespace: openshift-kube-descheduler-operator
spec:
  targetNamespaces:
    - openshift-kube-descheduler-operator
EOF

# 3. Create Subscription
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-kube-descheduler-operator
  namespace: openshift-kube-descheduler-operator
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: cluster-kube-descheduler-operator
  channel: "stable"
EOF
```

---

## Verify Installation

```bash
# Check CSV status
oc get csv -n openshift-kube-descheduler-operator

# Check Descheduler Pod status
oc get pods -n openshift-kube-descheduler-operator
```

---

## Descheduler Configuration

After installation, refer to the guide in the `01-environment/descheduler/` directory.

```bash
cd 01-environment/descheduler
./apply.sh
```

---

## Troubleshooting

```bash
# Check Descheduler Operator logs
oc logs -n openshift-kube-descheduler-operator deployment/descheduler-operator

# Check KubeDescheduler CR status
oc get kubedescheduler -n openshift-kube-descheduler-operator -o yaml

# Check Descheduler events
oc get events -n openshift-kube-descheduler-operator --sort-by='.lastTimestamp'
```
