# OpenShift Console Built-in Monitoring Dashboards (No Grafana Operator)

Register custom OpenShift Virtualization dashboards directly into the OpenShift web console's built-in **Observe → Dashboards** view — no Grafana Operator, Grafana instance, or Route required.

---

## Overview

The OpenShift web console renders custom monitoring dashboards on its own, without Grafana, whenever it finds a `ConfigMap` in the `openshift-config-managed` namespace labeled `console.openshift.io/dashboard: "true"`. The `data` key (ending in `.json`) holds a classic Grafana 6.x-style dashboard definition (`rows`/`panels`/`span`), and the console evaluates every PromQL query against the in-cluster **Thanos Querier** — the same data source the built-in dashboards use.

This lab covers:

- Permission check for writing to `openshift-config-managed`
- Dashboard 1: **KubeVirt VM Overall Status** (`poc-vm-overview`) — VM status summary, CPU/Memory/Network/Storage per VM
- Dashboard 2: **OpenShift Virtualization Cluster Overview** (`poc-ocpv-overview`) — VM distribution by node, phase breakdown, live migration status

**Trade-offs versus the Grafana Operator approach:**

- The data source is always the cluster's own Thanos Querier — you cannot point these dashboards at an external or custom Prometheus.
- Only the panel types the console's dashboard renderer understands are supported (`row`, `graph`, `singlestat`) — this is an older, narrower schema than modern Grafana panels (`timeseries`, `stat`, `table`).
- This is a lightly-documented console extension point, not a fully productized API — the ConfigMap schema could change across OpenShift versions.
- Writing to `openshift-config-managed` requires cluster-admin.

If you need full Grafana panel features, alerting, or a datasource pointing outside the cluster, use the Grafana Operator path instead (see [11-coo](../11-coo/11-coo.md) step 5/5 for an example that registers a Grafana datasource).

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
# or manually:
oc delete configmap poc-vm-overview-dashboard -n openshift-config-managed
oc delete configmap poc-ocpv-overview-dashboard -n openshift-config-managed
```
