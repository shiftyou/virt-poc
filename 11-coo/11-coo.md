# Cluster Observability Operator (COO) + VM node_exporter

Namespace-scoped monitoring using the Cluster Observability Operator (COO) with VM node_exporter scraping.

---

## OpenShift Monitoring vs Cluster Observability Operator (COO)

OpenShift has two independent Prometheus-based monitoring stacks.

| Item | OpenShift Monitoring | COO (MonitoringStack) |
|------|----------------------|----------------------|
| **Operator** | Built into OpenShift platform | Requires separate Operator installation |
| **Scope** | Entire cluster (+ user-workload) | Per namespace |
| **API** | `monitoring.coreos.com/v1` | `monitoring.rhobs/v1` |
| **Configuration** | ConfigMap (`cluster-monitoring-config`) | `MonitoringStack` CR |
| **Console integration** | Console → Observe → Metrics (direct display) | Not supported (port-forward or Grafana) |
| **Data isolation** | user-workload can be separated per namespace | Fully isolated per MonitoringStack |
| **Retention period** | Shared cluster configuration | Independent configuration per MonitoringStack |
| **Multi-tenancy** | Separate query permissions via RBAC | Separate Prometheus instances entirely |
| **Primary use case** | Common platform and app monitoring | Independent monitoring per team/project |

### Which one to choose?

- **OpenShift Monitoring (user-workload)** — Check directly in OpenShift Console without additional infrastructure.
  Suitable for single cluster, centralized monitoring.

- **COO MonitoringStack** — Deploy Prometheus independently per namespace.
  Suitable when per-team metric isolation, separate retention policies, or cluster Prometheus load distribution is needed.

- **Use both stacks together** (this POC configuration) — Secure visibility in OpenShift Console with `monitoring.coreos.com/v1` ServiceMonitor,
  while simultaneously collecting into COO Prometheus with `monitoring.rhobs/v1` ServiceMonitor.

```
[VM node_exporter]
      │
      ├─ Service (poc-monitoring-node-exporter)
      │       │
      │       ├─ ServiceMonitor (monitoring.coreos.com/v1)
      │       │       └─ OpenShift user-workload Prometheus
      │       │               └─ Console → Observe → Metrics
      │       │
      │       └─ ServiceMonitor (monitoring.rhobs/v1)
      │               └─ COO Prometheus (poc-monitoring-stack)
      │                       └─ Grafana / port-forward
```

---

## Prerequisites

- Cluster Observability Operator installed (OperatorHub → "Cluster Observability Operator")
- OpenShift Virtualization installed (`VIRT_INSTALLED=true` in `env.conf`)
- poc Template registered (run `01-template/01-template.sh`)
- `COO_INSTALLED=true` set in `env.conf`

### Install Cluster Observability Operator

Install COO from OperatorHub (Red Hat operators) or refer to `operators/coo-operator.md`.

```bash
# Verify installation
oc get csv --all-namespaces | grep cluster-observability-operator
# cluster-observability-operator.v0.x.x   Cluster Observability Operator   Succeeded
```

---

## 1. Create VM from poc template

```bash
VM_NAME="poc-coo-vm"
NS="poc-monitoring"

# Create VM from poc template
oc process -n openshift poc -p NAME="$VM_NAME" > ${VM_NAME}.yaml
oc apply -n "$NS" -f ${VM_NAME}.yaml

# Propagate monitor=metrics label to virt-launcher Pod
oc patch vm "$VM_NAME" -n "$NS" --type=merge -p '{
  "spec": {
    "template": {
      "metadata": {
        "labels": {
          "monitor": "metrics"
        }
      }
    }
  }
}'

# Start VM
virtctl start "$VM_NAME" -n "$NS"

# Check status
oc get vmi "$VM_NAME" -n "$NS"
```

When the VM is in Running state, install node_exporter inside the VM.

```bash
# Access VM console
virtctl console "$VM_NAME" -n "$NS"

# Install node_exporter inside VM (refer to 09-node-exporter/node-exporter-install.sh)
```

---

## 2. Create node-exporter Service

Specify the virt-launcher Pod (`monitor=metrics`) as the selector to access node_exporter (9100) inside the VM.
In masquerade networking, Pod port is NAT'd to VM port.

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: poc-monitoring-node-exporter
  namespace: poc-monitoring
  labels:
    app: poc-monitoring-vm
    monitoring.rhobs/stack: poc-monitoring-stack
spec:
  ports:
    - name: metrics
      protocol: TCP
      port: 9100
      targetPort: 9100
  selector:
    monitor: metrics
  type: ClusterIP
EOF
```

Check Endpoints:

```bash
oc get endpoints poc-monitoring-node-exporter -n poc-monitoring
```

---

## 3. Deploy MonitoringStack

Automatically collects ServiceMonitor / PrometheusRule / PodMonitor that have the `resourceSelector` label (`monitoring.rhobs/stack: poc-monitoring-stack`).

```bash
oc apply -f - <<'EOF'
apiVersion: monitoring.rhobs/v1alpha1
kind: MonitoringStack
metadata:
  name: poc-monitoring-stack
  namespace: poc-monitoring
spec:
  logLevel: info
  retention: 24h
  resourceSelector:
    matchLabels:
      monitoring.rhobs/stack: poc-monitoring-stack
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  prometheusConfig:
    replicas: 1
  alertmanagerConfig:
    enabled: true
EOF
```

Verify deployment:

```bash
oc get monitoringstack -n poc-monitoring
oc get pods -n poc-monitoring -l app.kubernetes.io/name=prometheus
oc get pods -n poc-monitoring -l app.kubernetes.io/name=alertmanager
```

---

## 4. Create ServiceMonitors

### ServiceMonitor for COO (`monitoring.rhobs/v1`)

Connected to MonitoringStack's Prometheus via the `monitoring.rhobs/stack` label.

```bash
oc apply -f - <<'EOF'
apiVersion: monitoring.rhobs/v1
kind: ServiceMonitor
metadata:
  name: poc-vm-node-exporter
  namespace: poc-monitoring
  labels:
    monitoring.rhobs/stack: poc-monitoring-stack
spec:
  selector:
    matchLabels:
      app: poc-monitoring-vm
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
      relabelings:
        - targetLabel: job
          replacement: poc-monitoring-vm
        - sourceLabels: [__meta_kubernetes_endpoint_hostname]
          targetLabel: vmname
EOF
```

### ServiceMonitor for OpenShift Console (`monitoring.coreos.com/v1`)

To query metrics in OpenShift Console's **Observe → Metrics** tab,
a `monitoring.coreos.com/v1` ServiceMonitor and namespace label are required.

```bash
# Add user-workload monitoring label to namespace
oc label namespace poc-monitoring openshift.io/cluster-monitoring=true --overwrite

oc apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: poc-vm-node-exporter-console
  namespace: poc-monitoring
  labels:
    app: poc-monitoring-vm
spec:
  selector:
    matchLabels:
      app: poc-monitoring-vm
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
      relabelings:
        - targetLabel: job
          replacement: poc-monitoring-vm
        - sourceLabels: [__meta_kubernetes_endpoint_hostname]
          targetLabel: vmname
EOF
```

Check ServiceMonitor list:

```bash
# For COO
oc get servicemonitor.monitoring.rhobs -n poc-monitoring

# For OpenShift Console
oc get servicemonitor.monitoring.coreos.com -n poc-monitoring
```

---

## 5. PrometheusRule (VM alert rules)

```bash
oc apply -f - <<'EOF'
apiVersion: monitoring.rhobs/v1
kind: PrometheusRule
metadata:
  name: poc-vm-alerts
  namespace: poc-monitoring
  labels:
    monitoring.rhobs/stack: poc-monitoring-stack
spec:
  groups:
    - name: vm.rules
      interval: 30s
      rules:
        - alert: VMNotRunning
          expr: kubevirt_vmi_phase_count{phase!="Running"} > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "VM is not in Running state"
            description: "VM {{ $labels.name }} state: {{ $labels.phase }}"
        - alert: VMHighMemoryUsage
          expr: >
            (kubevirt_vmi_memory_resident_bytes /
             (kubevirt_vmi_memory_resident_bytes + kubevirt_vmi_memory_available_bytes)) > 0.9
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "VM memory usage exceeds 90%"
            description: "VM {{ $labels.name }} has high memory usage."
EOF
```

---

## 6. View COO Metrics

COO MonitoringStack's Prometheus is not directly integrated with OpenShift Console as a cluster internal service.
Instead, query metrics via two routes.

> **Key principle**
> - OpenShift Console only shows the `monitoring.coreos.com/v1` ServiceMonitor → **user-workload Prometheus** route
> - COO Prometheus (`monitoring.rhobs/v1`) is accessed outside Console via Grafana or port-forward
> - This POC attaches both types of ServiceMonitor to the same Service for **simultaneous collection from both**

```
[poc-monitoring-node-exporter Service]
         │
         ├─ monitoring.coreos.com/v1 ServiceMonitor
         │        └─ user-workload Prometheus (OpenShift built-in)
         │                 └─ Console → Observe → Metrics ✔ (Project: poc-monitoring)
         │
         └─ monitoring.rhobs/v1 ServiceMonitor
                  └─ COO Prometheus (prometheus-operated)
                           ├─ Grafana → COO-Prometheus DataSource ✔
                           └─ port-forward → http://localhost:9090 ✔
```

---

### Method 1 — OpenShift Console (Observe → Metrics)

Query the same metrics in the console through **user-workload Prometheus** rather than COO Prometheus.

**Query steps:**

1. Access OpenShift Console
2. **Project** dropdown at top → select `poc-monitoring`
3. Left menu → **Observe → Metrics**
4. Enter query in PromQL input and click **Run queries**:

```promql
# VM available memory
node_memory_MemAvailable_bytes{job="poc-monitoring-vm"}

# VM CPU utilization
rate(node_cpu_seconds_total{job="poc-monitoring-vm",mode!="idle"}[5m])

# VM disk read speed
rate(node_disk_read_bytes_total{job="poc-monitoring-vm"}[5m])
```

**Check alert rules:**

- **Observe → Alerting** → `poc-monitoring` project
- Check `VMNotRunning`, `VMHighMemoryUsage` alert status

**Verify prerequisites:**

```bash
# Check namespace label
oc get namespace poc-monitoring --show-labels | grep cluster-monitoring

# Verify ServiceMonitor registration
oc get servicemonitor.monitoring.coreos.com poc-vm-node-exporter-console -n poc-monitoring

# Verify Endpoints active (node_exporter must be running in VM)
oc get endpoints poc-monitoring-node-exporter -n poc-monitoring
```

> **When metrics are not visible**
> - If Endpoints are empty, node_exporter is not running in the VM → run `09-node-exporter/node-exporter-install.sh`
> - If user-workload-monitoring is disabled:
>   ```bash
>   oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml | grep enableUserWorkload
>   # If enableUserWorkload: true is absent, it needs to be enabled
>   ```

---

### Method 2 — Grafana (COO Prometheus DataSource)

Query in Grafana through a DataSource directly connected to COO Prometheus.
`coo-prometheus-datasource` is automatically registered when `11-coo.sh` is executed (if Grafana is installed).

**Verify DataSource registration:**

```bash
oc get grafanadatasource coo-prometheus-datasource -n poc-monitoring
```

**Manual creation if registration is needed:**

```bash
oc apply -f - <<'EOF'
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: coo-prometheus-datasource
  namespace: poc-monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: poc-grafana
  datasource:
    name: COO-Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus-operated.poc-monitoring.svc.cluster.local:9090
    isDefault: false
    jsonData:
      timeInterval: 5s
EOF
```

**Access Grafana and query steps:**

```bash
# Check Grafana Route
oc get route -n poc-monitoring -l app=grafana -o jsonpath='{.items[0].spec.host}'
```

1. Access `https://<grafana-route>` → `admin` / `grafana123` (or env.conf value)
2. Left menu → **Explore**
3. DataSource dropdown at top → select **COO-Prometheus**
4. Enter PromQL in **Metrics browser** or directly:

```promql
# node_exporter metrics (COO Prometheus collected)
node_memory_MemAvailable_bytes{job="poc-monitoring-vm"}
rate(node_cpu_seconds_total{job="poc-monitoring-vm",mode!="idle"}[5m])
```

> **When DataSource connection fails**
> COO Prometheus Pod may still be starting up.
> ```bash
> oc get pods -n poc-monitoring -l app.kubernetes.io/name=prometheus
> # STATUS must be Running for Grafana to query successfully
> ```

**Note — Direct access to COO Prometheus via Port-forward:**

```bash
oc port-forward svc/prometheus-operated 9090:9090 -n poc-monitoring
# Browser: http://localhost:9090
# Targets tab → check poc-vm-node-exporter ServiceMonitor scrape targets
# Alerts tab → check VMNotRunning, VMHighMemoryUsage alert status
```

---

## Status Check

```bash
# MonitoringStack
oc get monitoringstack -n poc-monitoring

# All deployed Pods
oc get pods -n poc-monitoring

# ServiceMonitor (COO)
oc get servicemonitor.monitoring.rhobs -n poc-monitoring

# ServiceMonitor (console)
oc get servicemonitor.monitoring.coreos.com -n poc-monitoring

# PrometheusRule
oc get prometheusrule -n poc-monitoring

# VM status
oc get vmi poc-coo-vm -n poc-monitoring
```

---

## Rollback

```bash
./11-coo.sh --cleanup
# or manually:
oc delete namespace poc-monitoring
oc delete clusterrolebinding grafana-cluster-monitoring-view
```
