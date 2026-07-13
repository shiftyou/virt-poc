# Kubernetes NMState Operator Installation

## Overview

The Kubernetes NMState Operator is an Operator that declaratively manages network configuration on nodes.
It configures Linux Bridge, Bond, VLAN, etc. through `NodeNetworkConfigurationPolicy (NNCP)`,
and allows querying the current network state of each node with `NodeNetworkState (NNS)`.

It is required for VM network (NAD/Multus) configuration in OpenShift Virtualization.

---

## Prerequisites

- cluster-admin privileges

---

## Installation Methods

### Method 1: OpenShift Console (Web UI)

1. Navigate to **Operators > OperatorHub** menu
2. Search for `Kubernetes NMState`
3. Select **Kubernetes NMState Operator**
4. Click `Install`
5. Settings:
   - Installation mode: `All namespaces on the cluster`
   - Installed Namespace: `openshift-nmstate`
6. Click `Install`
7. After installation, **Create NMState instance**:
   - Operators > Installed Operators > Kubernetes NMState Operator
   - **NMState** tab > Click `Create NMState`
   - Create with default values

### Method 2: CLI (YAML)

```bash
# Install Namespace and Operator
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nmstate
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-nmstate
  namespace: openshift-nmstate
spec:
  targetNamespaces:
  - openshift-nmstate
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubernetes-nmstate-operator
  namespace: openshift-nmstate
spec:
  channel: stable
  name: kubernetes-nmstate-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Create NMState instance (after Operator installation is complete)
cat <<'EOF' | oc apply -f -
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
EOF
```

### Verify Installation

```bash
# Check Operator installation
oc get csv -n openshift-nmstate | grep nmstate

# Check NMState handler pods
oc get pods -n openshift-nmstate

# Query network state per node
oc get nodenetworkstate
```

### Query Node Network Interfaces

```bash
# List ethernet interfaces for a specific node
NODE=worker-0
oc get nns $NODE -o jsonpath='{range .status.currentState.interfaces[?(@.type=="ethernet")]}{.name}{"\n"}{end}'
```
