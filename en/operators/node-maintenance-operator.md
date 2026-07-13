# Node Maintenance Operator (NMO) Installation

## Overview

The Node Maintenance Operator (NMO) is an Operator that safely transitions nodes to maintenance mode.
It processes nodes with `cordon` + `drain` to move workloads to other nodes before performing maintenance tasks.
In OpenShift Virtualization environments, it supports zero-downtime maintenance by integrating with VM live migration.

---

## Prerequisites

- cluster-admin privileges

---

## Installation Methods

### Method 1: OpenShift Console (Web UI)

1. Navigate to **Operators > OperatorHub** menu
2. Search for `Node Maintenance`
3. Select **Node Maintenance Operator**
4. Click `Install`
5. Settings:
   - Installation mode: `All namespaces on the cluster`
   - Installed Namespace: `openshift-operators`
6. Click `Install`

### Method 2: CLI (YAML)

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-operators
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: node-maintenance-operator
  namespace: openshift-operators
spec:
  channel: stable
  name: node-maintenance-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

### Verify Installation

```bash
oc get csv -n openshift-operators | grep node-maintenance
```

---

## Usage

### Start Node Maintenance

```bash
cat <<'EOF' | oc apply -f -
apiVersion: nodemaintenance.medik8s.io/v1beta1
kind: NodeMaintenance
metadata:
  name: maintenance-worker-0
spec:
  nodeName: worker-0
  reason: "Hardware inspection"
EOF
```

### Check Maintenance Status

```bash
oc get nodemaintenance
oc describe nodemaintenance maintenance-worker-0
```

### End Maintenance

```bash
oc delete nodemaintenance maintenance-worker-0
```
