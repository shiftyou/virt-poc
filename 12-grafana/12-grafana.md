# Grafana Operator + OpenShift Prometheus DataSource + Dashboards

Deploy Grafana via the Grafana Operator, integrate with OpenShift built-in Prometheus, and deploy two dashboards for OpenShift Virtualization monitoring.

---

## Overview

This lab covers:

- Grafana Community Operator installation (namespace-scoped to `poc-monitoring`)
- Grafana instance deployment with Route access
- OpenShift built-in Prometheus datasource integration (thanos-querier:9091 + Bearer token)
- Dashboard 1: **KubeVirt VM Overall Status** (`poc-vm-overview`) — inline JSON, kubevirt metrics
- Dashboard 2: **OpenShift Virtualization Dashboard** (`grafana-dashboard-ocp-v`) — loaded from external URL

---

## Prerequisites

- Grafana Community Operator installed (see installation guide below)
- `GRAFANA_ADMIN_PASS` configured in `env.conf` (default: `grafana123`)

---

## Install Grafana Community Operator

Install the Grafana Operator from OperatorHub (community-operators) scoped to the `poc-monitoring` namespace.

```bash
# Create namespace (if it does not exist)
oc new-project poc-monitoring

# Install Grafana Operator (namespace-scoped)
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: grafana-operator-group
  namespace: poc-monitoring
spec:
  targetNamespaces:
    - poc-monitoring
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: grafana-operator
  namespace: poc-monitoring
spec:
  channel: v5
  name: grafana-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF

# Verify installation complete (wait for Succeeded status)
oc get csv -n poc-monitoring | grep grafana
# grafana-operator.v5.x.x   Grafana Operator   5.x.x   Succeeded

# Re-run setup script to update GRAFANA_INSTALLED=true
./11-grafana.sh
```

---

## Deploy Grafana Instance

```bash
source env.conf

oc apply -f - <<EOF
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: poc-grafana
  namespace: poc-monitoring
  labels:
    dashboards: poc-grafana
spec:
  config:
    auth:
      disable_login_form: "false"
    auth.anonymous:
      enabled: "false"
    security:
      admin_user: admin
      admin_password: ${GRAFANA_ADMIN_PASS:-grafana123}
EOF
```

### Create OpenShift Route

```bash
oc apply -f - <<'EOF'
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: poc-grafana-route
  namespace: poc-monitoring
  labels:
    app: grafana
spec:
  to:
    kind: Service
    name: poc-grafana-service
  port:
    targetPort: grafana
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

# Print access URL
echo "https://$(oc get route poc-grafana-route -n poc-monitoring \
  -o jsonpath='{.spec.host}')"
```

---

## Integrate OpenShift Prometheus DataSource

Grafana connects to OpenShift's built-in Prometheus via the thanos-querier endpoint using a Bearer token.

```bash
# Grant cluster-monitoring-view permission to Grafana SA
oc create clusterrolebinding grafana-cluster-monitoring-view \
  --clusterrole=cluster-monitoring-view \
  --serviceaccount=poc-monitoring:poc-grafana-sa 2>/dev/null || true

# Obtain Prometheus token
TOKEN=$(oc create token poc-grafana-sa -n poc-monitoring --duration=8760h)

# Create GrafanaDatasource
oc apply -f - <<EOF
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: prometheus-datasource
  namespace: poc-monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: poc-grafana
  datasource:
    name: Prometheus
    type: prometheus
    access: proxy
    url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
    isDefault: true
    jsonData:
      httpHeaderName1: Authorization
      timeInterval: 5s
      tlsSkipVerify: true
    secureJsonData:
      httpHeaderValue1: Bearer ${TOKEN}
EOF
```

---

## Dashboard 1: KubeVirt VM Overall Status (poc-vm-overview)

Deploys a Grafana dashboard with inline JSON showing VM status across the cluster.

**Key PromQL queries used in this dashboard:**

```promql
# Running VMs count
sum(kubevirt_vmi_phase_count{phase=~"Running|running"}) or vector(0)

# Paused VMs count
sum(kubevirt_vmi_phase_count{phase=~"Paused|paused"}) or vector(0)

# Abnormal VMIs (Pending/Failed)
sum(kubevirt_vmi_phase_count{phase!~"Running|running|Paused|paused"}) or vector(0)

# Total active VMIs
count(kubevirt_vmi_info) or vector(0)

# CPU utilization (vCPU seconds/s) per VM
rate(kubevirt_vmi_cpu_usage_seconds_total{namespace=~"$namespace", name=~"$vm"}[5m])

# Memory usage (resident bytes)
kubevirt_vmi_memory_resident_bytes{namespace=~"$namespace", name=~"$vm"}

# Memory utilization (%)
kubevirt_vmi_memory_resident_bytes / (kubevirt_vmi_memory_resident_bytes + kubevirt_vmi_memory_available_bytes)

# Network RX/TX
rate(kubevirt_vmi_network_receive_bytes_total{namespace=~"$namespace", name=~"$vm"}[5m])
rate(kubevirt_vmi_network_transmit_bytes_total{namespace=~"$namespace", name=~"$vm"}[5m])

# Storage read/write
rate(kubevirt_vmi_storage_read_traffic_bytes_total{namespace=~"$namespace", name=~"$vm"}[5m])
rate(kubevirt_vmi_storage_write_traffic_bytes_total{namespace=~"$namespace", name=~"$vm"}[5m])
```

**Dashboard features:**
- VM Status Summary — stat panels for Running, Paused, Abnormal, Total counts
- VM Inventory — table view of all VMIs across the cluster
- CPU, Memory, Network I/O, Storage I/O time series panels
- Namespace and VM Name template variables for filtering

---

## Dashboard 2: OpenShift Virtualization Dashboard (grafana-dashboard-ocp-v)

Deploys the community OpenShift Virtualization dashboard from an external URL.

```bash
oc apply -f - <<'EOF'
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: grafana-dashboard-ocp-v
  namespace: poc-monitoring
  labels:
    app: poc-grafana
spec:
  resyncPeriod: 5m
  instanceSelector:
    matchLabels:
      dashboards: poc-grafana
  folder: "Openshift Virtualization"
  url: https://raw.githubusercontent.com/leoaaraujo/articles/master/openshift-virtualization-monitoring/files/ocp-v-dashboard.json
EOF
```

**What this dashboard shows:**
- OpenShift Virtualization cluster overview
- VM lifecycle metrics (creation, deletion, migration rates)
- Resource utilization across all namespaces
- Node-level VM density and resource pressure
- Storage and network I/O aggregated by namespace

The dashboard is automatically fetched from the URL and synchronized by the Grafana Operator (`resyncPeriod: 5m`).

---

## Access Grafana

```bash
# Get Grafana URL
echo "https://$(oc get route poc-grafana-route -n poc-monitoring \
  -o jsonpath='{.spec.host}')"
```

**Login credentials:**

```bash
# GRAFANA_ADMIN_PASS value from env.conf (default: grafana123)
oc get secret grafana-admin-credentials -n poc-monitoring \
  -o jsonpath='{.data.GF_SECURITY_ADMIN_USER}' | base64 -d && echo
oc get secret grafana-admin-credentials -n poc-monitoring \
  -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' | base64 -d && echo
```

**Navigate to dashboards:**

1. Login to Grafana URL
2. Left menu → **Dashboards**
3. **KubeVirt VM Overall Status** — `/d/poc-vm-overview`
4. **Openshift Virtualization** folder → ocp-v dashboard — `/d/ocp-v`

---

## VM Status Monitoring PromQL Reference

With the Prometheus DataSource integrated, use the following PromQL in **Explore** or custom panels:

```promql
# VM running state (number of Running VMs)
sum(kubevirt_vmi_phase_count{phase="Running"})

# CPU utilization per VM
rate(kubevirt_vmi_vcpu_seconds_total[5m])

# VM memory usage
kubevirt_vmi_memory_used_bytes

# VM available memory
kubevirt_vmi_memory_available_bytes

# VM network receive
rate(kubevirt_vmi_network_receive_bytes_total[5m])

# VM network transmit
rate(kubevirt_vmi_network_transmit_bytes_total[5m])

# VM disk read
rate(kubevirt_vmi_storage_read_traffic_bytes_total[5m])

# VM disk write
rate(kubevirt_vmi_storage_write_traffic_bytes_total[5m])

# Live Migration status
kubevirt_vmi_migration_phase_transition_time_from_creation_seconds
```

---

## Troubleshooting

### Grafana Pod not starting

```bash
oc get pods -n poc-monitoring -l app=poc-grafana
oc describe pod -n poc-monitoring -l app=poc-grafana
```

### DataSource connection fails

```bash
# Check ServiceAccount token
oc get serviceaccount poc-grafana-sa -n poc-monitoring

# Check ClusterRoleBinding
oc get clusterrolebinding grafana-cluster-monitoring-view

# Check thanos-querier is accessible
oc get service thanos-querier -n openshift-monitoring
```

### Dashboard not showing in Grafana

```bash
# Check GrafanaDashboard synchronization status
oc get grafanadashboard -n poc-monitoring
oc describe grafanadashboard poc-vm-overview -n poc-monitoring

# Dashboard may take up to resyncPeriod (5m) to appear
```

### Check overall status

```bash
# Grafana Pod status
oc get pods -n poc-monitoring -l app=grafana

# Check Grafana Route
oc get route -n poc-monitoring

# GrafanaDatasource list
oc get grafanadatasource -n poc-monitoring

# GrafanaDashboard list
oc get grafanadashboard -n poc-monitoring
```

---

## Rollback

```bash
./11-grafana.sh --cleanup
# or manually:
oc delete namespace poc-monitoring
oc delete clusterrolebinding grafana-cluster-monitoring-view
```
