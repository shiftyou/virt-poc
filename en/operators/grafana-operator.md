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
  name: poc-grafana
  namespace: poc-grafana
  labels:
    dashboards: poc-grafana
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

> The label `dashboards: poc-grafana` and instance name `poc-grafana` are load-bearing — [11-coo](../11-coo/11-coo.md) and [12-grafana](../12-grafana/12-grafana.md) look up this exact label via `instanceSelector` to register their `GrafanaDatasource`/`GrafanaDashboard` resources, and the route name (`<name>-route`) is used to print the access URL.

### Check Access URL

```bash
oc get route poc-grafana-route -n poc-grafana
```

---

## Note — Dashboards/Datasources in Other Namespaces

`GrafanaDashboard` and `GrafanaDatasource` resources are matched to this Grafana instance purely via `instanceSelector.matchLabels.dashboards: poc-grafana` — they can live in a different namespace than the Grafana instance itself (e.g. [11-coo](../11-coo/11-coo.md) creates them in `poc-monitoring`). If such a cross-namespace resource never syncs, add a namespace selector to the Grafana CR so the Operator watches that namespace too:

```bash
oc patch grafana poc-grafana -n poc-grafana --type=merge -p '{
  "spec": {
    "namespaceSelector": {
      "matchLabels": {}
    }
  }
}'
```

or reinstall the Operator with Installation mode `All namespaces on the cluster` instead of a single namespace.
