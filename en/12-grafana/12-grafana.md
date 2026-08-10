# OpenShift Console Built-in Monitoring Dashboards (No Grafana Operator)

Register custom OpenShift Virtualization dashboards directly into the OpenShift web console's built-in **Observe → Dashboards** view — no Grafana Operator, Grafana instance, or Route required.

---

## Overview

The OpenShift web console renders custom monitoring dashboards on its own, without Grafana, whenever it finds a `ConfigMap` in the `openshift-config-managed` namespace labeled `console.openshift.io/dashboard: "true"`. The `data` key (ending in `.json`) holds a classic Grafana 6.x-style dashboard definition (`rows`/`panels`/`span`), and the console evaluates every PromQL query against the in-cluster **Thanos Querier** — the same data source the built-in dashboards use.

This section covers (`12-grafana.sh` steps 1/4–2/4):

- Permission check for writing to `openshift-config-managed`
- Dashboard 1: **KubeVirt VM Overall Status** (`poc-vm-overview`) — VM status summary, CPU/Memory/Network/Storage per VM
- Dashboard 2: **OpenShift Virtualization Cluster Overview** (`poc-ocpv-overview`) — VM distribution by node, phase breakdown, live migration status

**Trade-offs versus [Using the Grafana Operator](#using-the-grafana-operator):**

- The data source is always the cluster's own Thanos Querier — you cannot point these dashboards at an external or custom Prometheus.
- Only the panel types the console's dashboard renderer understands are supported (`row`, `graph`, `singlestat`) — this is an older, narrower schema than modern Grafana panels (`timeseries`, `stat`, `table`).
- This is a lightly-documented console extension point, not a fully productized API — the ConfigMap schema could change across OpenShift versions.
- Writing to `openshift-config-managed` requires cluster-admin.

If you need full Grafana panel features, alerting, or a datasource pointing outside the cluster, see [Using the Grafana Operator](#using-the-grafana-operator) below. If Red Hat subscription support matters more than Grafana's ecosystem maturity, see [Using Cluster Observability Operator (COO) and Red Hat build of Perses](#using-cluster-observability-operator-coo-and-red-hat-build-of-perses-recommended) instead — the Grafana Operator installed below is a **Community** Operator and is not covered by a Red Hat subscription.

---

## Prerequisites

- Cluster-admin access (`oc auth can-i create configmap -n openshift-config-managed` must return `yes`)
- No operator installation needed

---

## How It Works

```bash
oc auth can-i create configmap -n openshift-config-managed
```

Any ConfigMap matching this shape is picked up automatically by the console — no restart or resync period needed, changes are reflected on next page load:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: <any-name>
  namespace: openshift-config-managed
  labels:
    console.openshift.io/dashboard: "true"
data:
  <any-name>.json: |
    { ... Grafana 6.x-style dashboard JSON ... }
```

---

## Dashboard 1: KubeVirt VM Overall Status (poc-vm-overview)

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
- VM Status Summary — singlestat panels for Running, Paused, Abnormal, Total counts
- CPU, Memory, Network I/O, Storage I/O time series panels
- Namespace and VM Name template variables for filtering

**Apply manually:**

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: poc-vm-overview-dashboard
  namespace: openshift-config-managed
  labels:
    console.openshift.io/dashboard: "true"
data:
  poc-vm-overview.json: |
    { ... see 12-grafana.sh for the full JSON ... }
EOF
```

---

## Dashboard 2: OpenShift Virtualization Cluster Overview (poc-ocpv-overview)

**Key PromQL queries used in this dashboard:**

```promql
# VM count by node
count(kubevirt_vmi_info) by (node)

# VMI count by phase (cluster total)
sum(kubevirt_vmi_phase_count) by (phase)

# Live migrations currently pending / scheduling / running
sum(kubevirt_vmi_migrations_in_pending_phase) or vector(0)
sum(kubevirt_vmi_migrations_in_scheduling_phase) or vector(0)
sum(kubevirt_vmi_migrations_in_running_phase) or vector(0)

# Live migrations failed (cumulative counter)
sum(kubevirt_vmi_migrations_failed) or vector(0)
```

**Dashboard features:**
- VM distribution across nodes (stacked graph)
- VMI phase breakdown across the cluster
- Live migration status singlestats (Pending / Scheduling / Running / Failed)

---

## Access the Dashboards

1. Log in to the OpenShift web console as a user with monitoring view access
2. Switch to the **Administrator** perspective
3. **Observe → Dashboards**
4. Select from the dashboard dropdown:
   - **KubeVirt VM Overall Status**
   - **OpenShift Virtualization Cluster Overview**

---

## VM Status Monitoring PromQL Reference

With no datasource setup needed, use the following PromQL directly in **Observe → Metrics**:

```promql
# VM running state (number of Running VMs)
sum(kubevirt_vmi_phase_count{phase="Running"})

# CPU utilization per VM
rate(kubevirt_vmi_cpu_usage_seconds_total[5m])

# VM memory usage
kubevirt_vmi_memory_resident_bytes

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

# Live migrations in progress
sum(kubevirt_vmi_migrations_in_running_phase)
```

---

## Troubleshooting

### Permission denied creating the ConfigMap

```bash
oc auth can-i create configmap -n openshift-config-managed
# must return "yes" — cluster-admin (or equivalent) is required
```

### Dashboard not showing in the console

```bash
# Confirm the ConfigMap exists with the correct label
oc get configmap -n openshift-config-managed -l console.openshift.io/dashboard=true

# Confirm the JSON key ends in .json and parses correctly
oc get configmap poc-vm-overview-dashboard -n openshift-config-managed \
  -o jsonpath='{.data.poc-vm-overview\.json}' | python3 -m json.tool > /dev/null && echo OK
```

If the ConfigMap and label are correct but the dashboard is still missing, do a hard refresh of the console tab — the dashboard list is loaded once per page session.

### No data in panels

```bash
# Verify the KubeVirt metrics exist in Thanos Querier
oc exec -n openshift-monitoring sts/thanos-querier -c thanos-query -- \
  wget -qO- --header "Authorization: Bearer $(oc whoami -t)" \
  'https://localhost:9091/api/v1/query?query=kubevirt_vmi_info' --no-check-certificate
```

---

## Rollback

```bash
./12-grafana.sh --cleanup
# removes the console ConfigMaps here, and also the Grafana Operator
# resources from "Using the Grafana Operator" below, if present

# or manually:
oc delete configmap poc-vm-overview-dashboard -n openshift-config-managed
oc delete configmap poc-ocpv-overview-dashboard -n openshift-config-managed
```

---

# Using the Grafana Operator

Deploy the same two dashboards as `GrafanaDashboard` custom resources managed by the [Grafana Operator](../operators/grafana-operator.md), instead of (or in addition to) the console ConfigMaps above. Use this path when you need modern Grafana panel types (`timeseries`, `stat`), Grafana alerting, or dashboards viewable outside the OpenShift console.

## Prerequisites

- Grafana Operator installed — see [operators/grafana-operator.md](../operators/grafana-operator.md). A `Grafana` instance labeled `dashboards: poc-grafana` is **not** required beforehand: `12-grafana.sh` creates one automatically (namespace `poc-grafana`) if it doesn't find one.
- `GRAFANA_INSTALLED=true` in `env.conf` (auto-detected from the installed CSV when `12-grafana.sh` runs)

---

## How It Works

`12-grafana.sh` runs this as step 3/4, automatically skipped only if the Grafana Operator itself is not installed:

1. If no `Grafana` instance labeled `dashboards: poc-grafana` exists yet, one is created — namespace `poc-grafana`, `admin` / `GRAFANA_ADMIN_PASSWORD` from `env.conf` (default `grafana123`), edge-terminated Route. This is the same shape documented in [operators/grafana-operator.md](../operators/grafana-operator.md); the script just applies it for you if it's missing.
2. A dedicated `ServiceAccount` (`poc-grafana-view`) and a `ClusterRoleBinding` to `cluster-monitoring-view` are created so Grafana can authenticate to the in-cluster Thanos Querier.
3. A `GrafanaDatasource` (`thanos-querier-datasource`) is registered against `https://thanos-querier.openshift-monitoring.svc.cluster.local:9091`, using a Bearer token issued to that ServiceAccount.
4. Two `GrafanaDashboard` resources (`poc-vm-overview-operator`, `poc-ocpv-overview-operator`) are created with the same PromQL queries as Dashboard 1/2 above, using the modern Grafana panel schema (`stat`, `timeseries`).

All resources are created in whichever namespace the `Grafana` instance lives in — the one just created, or an existing one if you already had one labeled `dashboards: poc-grafana` elsewhere (`poc-grafana` by convention either way).

> The ServiceAccount token is generated with `oc create token --duration=8760h` (1 year). Tokens are capped by the cluster's `service-account-max-token-expiration` setting and will need to be regenerated — just rerun `12-grafana.sh` — if the cluster enforces a shorter limit or after expiry.

---

## Deploy

```bash
./12-grafana.sh
# step 3/4 runs automatically once the Grafana Operator is detected — it
# creates the poc-grafana instance too if one doesn't already exist
```

---

## Access

```bash
oc get route poc-grafana-route -n <grafana-namespace> -o jsonpath='{.spec.host}'
```

Log in (`admin` / the password configured on the `Grafana` CR) → **Dashboards** → **KubeVirt VM Overall Status (Operator)** / **OpenShift Virtualization Cluster Overview (Operator)**.

---

## Troubleshooting

### Datasource shows "Unauthorized" in Grafana

```bash
# The Bearer token may have expired — regenerate by rerunning the script
./12-grafana.sh
```

### GrafanaDashboard/GrafanaDatasource not syncing

```bash
oc get grafanadashboard,grafanadatasource -n <grafana-namespace>
oc describe grafanadashboard poc-vm-overview-operator -n <grafana-namespace>
# If the dashboard/datasource live in a different namespace than the Grafana
# instance, the Grafana CR needs a namespaceSelector covering it — see
# operators/grafana-operator.md.
```

---

## Rollback

```bash
./12-grafana.sh --cleanup
# removes these Operator-based resources, and also the console ConfigMaps
# from "OpenShift Console Built-in Monitoring Dashboards" above, if present

# or manually:
oc delete grafanadashboard poc-vm-overview-operator poc-ocpv-overview-operator -n <grafana-namespace>
oc delete grafanadatasource thanos-querier-datasource -n <grafana-namespace>
oc delete serviceaccount poc-grafana-view -n <grafana-namespace>
oc delete clusterrolebinding grafana-cluster-monitoring-view
```

Neither `--cleanup` nor the manual commands above remove the `Grafana` instance itself (or its namespace) — it's treated as a shared resource other labs (e.g. [11-coo](../11-coo/11-coo.md)) may also register datasources/dashboards into. Delete it explicitly if you're done with it entirely:

```bash
oc delete grafana poc-grafana -n <grafana-namespace>
oc delete project <grafana-namespace>   # only if nothing else uses this namespace
```

---

# Using Cluster Observability Operator (COO) and Red Hat build of Perses (Recommended)

The Grafana Operator used above is a **Community** Operator — it is not covered by a Red Hat subscription. Red Hat's supported alternative for custom dashboards is the **Cluster Observability Operator (COO)**, itself a Red Hat-shipped operator, together with its `Monitoring` `UIPlugin`, which enables the **Red Hat build of Perses** — a Red Hat-maintained downstream build of the CNCF Perses project. It renders dashboards natively inside **Observe → Dashboards (Perses)** in the OpenShift console and uses native Kubernetes RBAC instead of a separate Grafana user database.

Full installation, datasource registration, dashboard deployment (including a way to import the same `poc-vm-overview` / `poc-ocpv-overview` dashboards defined above via COO's built-in Grafana-import tool), RBAC, and rollback steps are documented in **[operators/perses-coo.md](../operators/perses-coo.md)**.

**Prerequisites:**

- OpenShift 4.15+ and Cluster Observability Operator 1.5+, installed from the **Red Hat catalog** (`source: redhat-operators`) — the same COO instance used by [11-coo](../11-coo/11-coo.md)

**Access (once configured per operators/perses-coo.md):**

Administrator perspective → **Observe → Dashboards (Perses)** → select the dashboard from the dropdown.
