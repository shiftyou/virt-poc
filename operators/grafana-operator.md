# Grafana Operator Installation

## Overview

The Grafana Operator deploys and manages Grafana instances in the OpenShift cluster.
It can configure dashboards to visualize VM metrics (CPU, memory, network, disk) from OpenShift Virtualization.

---

## Prerequisites

- cluster-admin privileges
- OpenShift User Workload Monitoring enabled

---

## Installation Methods

### Method 1: OpenShift Console (Web UI)

1. Navigate to **Operators > OperatorHub** menu
2. Search for `Grafana`
3. Select **Grafana Operator** (Community)
4. Click `Install`
5. Settings:
   - Installation mode: `A specific namespace on the cluster`
   - Installed Namespace: `poc-grafana` (create new)
6. Click `Install`

### Method 2: CLI (YAML)

```bash
# Create Namespace
oc new-project poc-grafana

# Install Operator
cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: grafana-operator
  namespace: poc-grafana
spec:
  targetNamespaces:
  - poc-grafana
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: grafana-operator
  namespace: poc-grafana
spec:
  channel: v5
  name: grafana-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF
```

### Verify Installation

```bash
oc get csv -n poc-grafana | grep grafana
```

---

## Create Grafana Instance

```bash
cat <<'EOF' | oc apply -f -
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: grafana
  namespace: poc-grafana
  labels:
    dashboards: grafana
spec:
  config:
    auth:
      disable_login_form: "false"
    security:
      admin_user: admin
      admin_password: grafana123
  route:
    spec:
      tls:
        termination: edge
EOF
```

### Check Access URL

```bash
oc get route grafana-route -n poc-grafana
```
