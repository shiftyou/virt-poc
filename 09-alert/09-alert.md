# VM Alert Practice

Configure alert rules for VM status using OpenShift Monitoring (Prometheus).

```
Prometheus (OpenShift Monitoring)
  └─ PrometheusRule (Alert rules)
       └─ kubevirt_vmi_phase_count and other VM metrics monitoring
            └─ AlertManager → Send notifications (Email/Slack/PagerDuty)
```

---

## Prerequisites

- OpenShift Monitoring enabled (included by default)
- User-defined project monitoring enabled (when using alerts in user namespaces)
- `08-alert.sh` execution complete

---

## VM Creation (for Alert testing)

When `08-alert.sh` is executed, `poc-alert-vm` is automatically created from the poc template.
Use the created VM to directly trigger each alert condition and verify the behavior.

```bash
# Check VM status
oc get vm,vmi -n poc-alert

# VM console access
virtctl console poc-alert-vm -n poc-alert
```

---

## Enable User-defined Project Monitoring

Required to apply PrometheusRule to user namespaces (such as poc-alert).

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
```

---

## Key VM Metrics

| Metric | Description |
|--------|-------------|
| `kubevirt_vmi_phase_count` | VMI count by phase — phase values (lowercase): `pending` / `scheduling` / `scheduled` / `running` / `succeeded` |
| `kubevirt_vmi_vcpu_seconds_total` | vCPU usage time |
| `kubevirt_vmi_network_traffic_bytes_total` | VM network traffic |
| `kubevirt_vmi_storage_iops_total` | VM storage IOPS |
| `kubevirt_vmi_memory_available_bytes` | VM available memory |
| `kubevirt_vmi_migration_data_processed_bytes` | Migration data processed |

---

## PrometheusRule Example — VM Alerts

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: poc-vm-alerts
  namespace: poc-alert
  labels:
    role: alert-rules
    openshift.io/prometheus-rule-evaluation-scope: leaf-prometheus
spec:
  groups:
    - name: poc-vm-availability
      interval: 30s
      rules:

        # When a VM is stopped (succeeded = graceful stop)
        # kubevirt_vmi_phase_count label phase values are lowercase: pending/scheduling/scheduled/running/succeeded
        # failed / unknown do not appear in metrics in this environment, so detect via succeeded
        - alert: VMStopped
          expr: |
            kubevirt_vmi_phase_count{phase="succeeded"} > 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "VM has stopped"
            description: "{{ $value }} VM(s) in succeeded (stopped) state detected in namespace {{ $labels.namespace }}."

        # VM waiting in pending state for more than 5 minutes
        - alert: VMStuckPending
          expr: |
            kubevirt_vmi_phase_count{phase="pending"} > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "VM is waiting in pending state"
            description: "{{ $value }} VM(s) in pending state exist in namespace {{ $labels.namespace }}."

        # VM stuck in scheduling/scheduled phase for more than 10 minutes
        - alert: VMStuckStarting
          expr: |
            kubevirt_vmi_phase_count{phase=~"scheduling|scheduled"} > 0
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "VM is stuck while starting"
            description: "VM(s) in {{ $labels.phase }} state have persisted for more than 10 minutes in namespace {{ $labels.namespace }}."

        # Live Migration failure
        - alert: VMLiveMigrationFailed
          expr: |
            increase(kubevirt_vmi_migration_phase_transition_time_seconds_count{phase="Failed"}[10m]) > 0
          labels:
            severity: warning
          annotations:
            summary: "VM Live Migration has failed"
            description: "Live Migration of VM {{ $labels.vmi }} has failed."

    - name: poc-vm-resources
      interval: 60s
      rules:

        # VM low memory (available memory below 100MiB)
        - alert: VMLowMemory
          expr: |
            kubevirt_vmi_memory_available_bytes < 100 * 1024 * 1024
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "VM memory is running low"
            description: "Available memory for VM {{ $labels.name }} (namespace: {{ $labels.namespace }}) is {{ $value | humanize }}."
```

---

## How to Trigger Alerts

Actually create each alert condition and verify the behavior.

---

### 1. VMStopped — Trigger by stopping a VM to Succeeded state

> Actual KubeVirt phase values: `Pending` / `Scheduling` / `Scheduled` / `Running` / `Succeeded`
> `Failed` / `Unknown` do not appear in metrics, so detect stopped state via **Succeeded (graceful shutdown)**.

When a VM is stopped with `virtctl stop`, the VMI phase transitions to **Succeeded**.
The alert fires when the `for: 2m` condition is met.

```bash
# 1) Stop VM
virtctl stop poc-alert-vm -n poc-alert

# 2) Check VMI phase (Succeeded)
oc get vmi -n poc-alert

# 3) After 2 minutes: check VMStopped in Console → Observe → Alerting
```

**Recovery:**

```bash
virtctl start poc-alert-vm -n poc-alert
```

---

### 2. VMStuckPending — Trigger VM to Pending state

Setting resource (CPU/memory) requests larger than cluster capacity keeps the VMI in **Pending** state.
The alert fires when the `for: 5m` condition is met.

```bash
# 1) Patch with excessive memory request (e.g., 9999Gi)
oc patch vm poc-alert-vm -n poc-alert --type=merge -p \
  '{"spec":{"template":{"spec":{"domain":{"resources":{"requests":{"memory":"9999Gi"}}}}}}}'

# 2) Restart VM → VMI stays in Pending state
virtctl restart poc-alert-vm -n poc-alert

# 3) Check VMI status (confirm Pending)
oc get vmi -n poc-alert

# 4) After 5 minutes: check VMStuckPending in Console → Observe → Alerting
```

**Recovery:**

```bash
oc patch vm poc-alert-vm -n poc-alert --type=merge -p \
  '{"spec":{"template":{"spec":{"domain":{"resources":{"requests":{"memory":"2Gi"}}}}}}}'
virtctl start poc-alert-vm -n poc-alert
```

---

### 3. VMStuckStarting — Trigger VM to stop in Scheduling/Scheduled state

Specifying a non-existent node with `nodeSelector` causes the VMI to fail to be placed by the scheduler,
stalling in **Scheduling** or **Scheduled** state.
The alert fires when the `for: 10m` condition is met.

```bash
# 1) Patch to specify a non-existent node
oc patch vm poc-alert-vm -n poc-alert --type=merge -p \
  '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"nonexistent-node"}}}}}'

# 2) Restart VM
virtctl restart poc-alert-vm -n poc-alert

# 3) Check VMI phase (Scheduling or Scheduled)
oc get vmi -n poc-alert

# 4) After 10 minutes: check VMStuckStarting in Console → Observe → Alerting
```

**Recovery:**

```bash
oc patch vm poc-alert-vm -n poc-alert --type=json \
  -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'
virtctl start poc-alert-vm -n poc-alert
```

---

### 5. VMLiveMigrationFailed — Trigger Live Migration failure

Force a Migration attempt when there are no available destination nodes or resources are insufficient.

```bash
# 1) Confirm VM is in Running state
oc get vmi poc-alert-vm -n poc-alert

# 2) Add taint to all worker nodes (no migration destination)
for node in $(oc get nodes -l node-role.kubernetes.io/worker -o name); do
  oc adm taint node "${node#node/}" migration-test=blocked:NoSchedule --overwrite
done

# 3) Start Live Migration → transition to Failed
virtctl migrate poc-alert-vm -n poc-alert

# 4) Check Migration status
oc get vmim -n poc-alert

# 5) Within 10 minutes: check VMLiveMigrationFailed in Console → Observe → Alerting
```

**Recovery:**

```bash
for node in $(oc get nodes -l node-role.kubernetes.io/worker -o name); do
  oc adm taint node "${node#node/}" migration-test=blocked:NoSchedule-
done
```

---

### 6. VMLowMemory — Trigger VM low memory

Exhaust memory inside the VM using the `stress` tool.
The alert fires when `kubevirt_vmi_memory_available_bytes < 100MiB` persists for `for: 5m`.

```bash
# 1) Access VM console
virtctl console poc-alert-vm -n poc-alert

# 2) Install and run stress inside the VM (RHEL/CentOS)
sudo dnf install -y stress-ng
# Occupy more than VM allocated memory - 100MiB (e.g., 1700m for a 1.8Gi VM)
stress-ng --vm 1 --vm-bytes 1700m --timeout 600s &

# 3) Check available memory
free -m

# 4) After 5 minutes: check VMLowMemory in Console → Observe → Alerting
```

**Recovery (inside VM):**

```bash
# Terminate stress-ng
kill %1
# Or
killall stress-ng
```

---

## How to Check Alert Status

Alerts transition through 3 stages: **Inactive → Pending → Firing**.

| State | Meaning |
|-------|---------|
| Inactive | Condition not met (normal) |
| Pending | Condition met, waiting for `for:` duration |
| Firing | Persisted through `for:` condition → actual notification sent |

---

### Method 1. OpenShift Console (fastest)

```
OpenShift Console
  → Observe
    → Alerting
      → Alert Rules   ← Verify PrometheusRule registered (Inactive/Pending/Firing)
      → Alerts        ← List of currently Firing alerts
```

- **Alert Rules** tab: Check the `poc-vm-alerts` rule and current state of each alert
- **Alerts** tab: Displays only Firing state alerts

> ⚠️ After enabling user-defined project monitoring, it takes 1-2 minutes for Pods to start.
> If not visible in Console, refresh after a moment.

---

### Method 2. CLI — Direct Prometheus API query

Query alert status by making direct API requests to the User Workload Monitoring Prometheus.

```bash
# Query all current alert states (including Pending/Firing)
oc exec -n openshift-user-workload-monitoring \
  prometheus-user-workload-0 -- \
  curl -s http://localhost:9090/api/v1/alerts \
  | python3 -m json.tool

# Filter specific alerts only
oc exec -n openshift-user-workload-monitoring \
  prometheus-user-workload-0 -- \
  curl -s http://localhost:9090/api/v1/alerts \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for a in data['data']['alerts']:
    if 'VM' in a['labels'].get('alertname',''):
        print(a['labels']['alertname'], '->', a['state'])
        print('  labels:', a['labels'])
        print('  annotations:', a['annotations'])
"
```

Example output:
```
VMNotRunning -> firing
  labels: {'alertname': 'VMNotRunning', 'namespace': 'poc-alert', 'phase': 'Failed', 'severity': 'critical'}
  annotations: {'description': '1 VM(s) in Failed state detected in namespace poc-alert.', ...}
```

---

### Method 3. CLI — Verify PrometheusRule loading

Verify that Prometheus has actually loaded the PrometheusRule.

```bash
# Check whether rule is loaded — no output means loading failed
oc exec -n openshift-user-workload-monitoring \
  prometheus-user-workload-0 -- \
  curl -s http://localhost:9090/api/v1/rules \
  | python3 -m json.tool | grep -A2 '"name": "VMNotRunning"'

# Check PrometheusRule resource
oc get prometheusrule -n poc-alert
oc describe prometheusrule poc-vm-alerts -n poc-alert
```

#### Label, RBAC, and namespace label requirements

| Item | Required | Description |
|------|----------|-------------|
| Namespace label | ❌ Not required | PrometheusRule is auto-detected without namespace label. `openshift.io/cluster-monitoring` label is for ServiceMonitor only |
| PrometheusRule label | **Conditional** | Required only when `prometheus-user-workload`'s `ruleSelector` requires a specific label |
| `monitoring-edit` RBAC | ❌ Not required | Not applicable when running with cluster-admin. Only needed when regular users create/modify PrometheusRule directly |
| `monitoring-rules-edit` RBAC | ❌ Not required | Same as above |

**Most common cause — `ruleSelector` mismatch**

If `ruleSelector` is configured on `prometheus-user-workload`, the PrometheusRule must have a label matching that condition to be loaded.

```bash
# Check ruleSelector / ruleNamespaceSelector
oc get prometheus -n openshift-user-workload-monitoring user-workload \
  -o jsonpath='{.spec.ruleSelector}' && echo ""
oc get prometheus -n openshift-user-workload-monitoring user-workload \
  -o jsonpath='{.spec.ruleNamespaceSelector}' && echo ""
```

- If output is `{}` or empty → **all PrometheusRules auto-detected** (no label required)
- If `matchLabels` present → PrometheusRule must have that label

Example output:
```json
{"matchExpressions":[
  {"key":"openshift.io/user-monitoring","operator":"NotIn","values":["false"]},
  {"key":"openshift.io/prometheus-rule-evaluation-scope","operator":"In","values":["leaf-prometheus"]}
]}
```
→ PrometheusRule **must** have label `openshift.io/prometheus-rule-evaluation-scope: leaf-prometheus`.
→ `openshift.io/user-monitoring` label passes condition if absent (NotIn condition)

**Add label to already deployed PrometheusRule (takes effect immediately):**

```bash
oc label prometheusrule poc-vm-alerts -n poc-alert \
  openshift.io/prometheus-rule-evaluation-scope=leaf-prometheus

# Verify loading after 30 seconds to 1 minute
oc exec -n openshift-user-workload-monitoring \
  prometheus-user-workload-0 -- \
  curl -s http://localhost:9090/api/v1/rules \
  | python3 -m json.tool | grep '"name"'
```

---

#### When nothing is output — Step-by-step diagnosis

**Step 1: Verify the PrometheusRule resource exists**

```bash
oc get prometheusrule -n poc-alert
```

If absent, re-run `08-alert.sh` or apply manually.

---

**Step 2: Verify all User Workload Monitoring Pods are Running**

```bash
oc get pods -n openshift-user-workload-monitoring
```

`prometheus-user-workload-0`, `prometheus-operator-*`, etc. must be Running.
If Pods are absent, the `enableUserWorkload: true` ConfigMap has not been applied.

```bash
oc get configmap cluster-monitoring-config -n openshift-monitoring \
  -o jsonpath='{.data.config\.yaml}'
```

---

**Step 3: Check Prometheus logs for rule loading errors**

```bash
oc logs -n openshift-user-workload-monitoring prometheus-user-workload-0 \
  -c prometheus --tail=50 | grep -i "rule\|error\|poc-alert"
```

If there are `error loading rules` or `parse error` messages, there is a YAML syntax error in the PrometheusRule.

---

**Step 4: Output full rule list and check by group name**

```bash
oc exec -n openshift-user-workload-monitoring \
  prometheus-user-workload-0 -- \
  curl -s http://localhost:9090/api/v1/rules \
  | python3 -m json.tool | grep '"name"'
```

If `poc-vm-availability` or `poc-vm-resources` group appears, they are loaded.
If no groups appear, Prometheus has not yet scanned that namespace —
**retry after 1-2 minutes** or restart the Pod.

```bash
# Restart Prometheus (last resort)
oc delete pod prometheus-user-workload-0 -n openshift-user-workload-monitoring
```

---

### Method 4. CLI — Verify AlertManager reception

Verify that AlertManager has received the alert (only delivered at Firing stage).

```bash
# Check AlertManager Pod
oc get pods -n openshift-monitoring | grep alertmanager

# Query currently active alerts via AlertManager API
oc exec -n openshift-monitoring alertmanager-main-0 -- \
  curl -s http://localhost:9093/api/v2/alerts \
  | python3 -m json.tool | grep -A5 "alertname"
```

---

### Method 5. Direct access to Prometheus/AlertManager UI via Port-forward

```bash
# Prometheus UI (port forwarding)
oc port-forward -n openshift-user-workload-monitoring \
  prometheus-user-workload-0 9090:9090 &
# Browser: http://localhost:9090/alerts

# AlertManager UI (port forwarding)
oc port-forward -n openshift-monitoring \
  alertmanager-main-0 9093:9093 &
# Browser: http://localhost:9093
```

In the Prometheus UI → **Alerts** menu, you can check the Pending/Firing state of each alert and the remaining `for:` time in real time.

---

## AlertManager Receiver Configuration (Slack Example)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-main
  namespace: openshift-monitoring
stringData:
  alertmanager.yaml: |
    global:
      slack_api_url: 'https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK'
    route:
      receiver: slack-notifications
      group_by: ['alertname', 'namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 1h
    receivers:
      - name: slack-notifications
        slack_configs:
          - channel: '#ocp-alerts'
            title: '[{{ .Status | toUpper }}] {{ .CommonAnnotations.summary }}'
            text: '{{ .CommonAnnotations.description }}'
            send_resolved: true
```

---

## Troubleshooting

| Symptom | Check command | Cause |
|---------|---------------|-------|
| No Alert Rules in Console | `oc get prometheusrule -n poc-alert` | PrometheusRule not deployed |
| No groups in rules API | `oc get pods -n openshift-user-workload-monitoring` | User Workload Monitoring not enabled |
| Groups exist but no alerts | Check Prometheus logs | PrometheusRule YAML syntax error |
| Alert not transitioning from Pending to Firing | `oc exec alertmanager-main-0 -- curl .../api/v2/alerts` | AlertManager configuration error |

```bash
# 1. Check PrometheusRule resource and syntax
oc get prometheusrule -n poc-alert
oc describe prometheusrule poc-vm-alerts -n poc-alert

# 2. Check User Workload Monitoring Pod status
oc get pods -n openshift-user-workload-monitoring

# 3. Check enableUserWorkload configuration
oc get configmap cluster-monitoring-config -n openshift-monitoring \
  -o jsonpath='{.data.config\.yaml}'

# 4. Check Prometheus logs for rule loading errors
oc logs -n openshift-user-workload-monitoring prometheus-user-workload-0 \
  -c prometheus --tail=50 | grep -i "rule\|error\|poc"

# 5. Check full list of loaded rule groups
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -- \
  curl -s http://localhost:9090/api/v1/rules \
  | python3 -m json.tool | grep '"name"'

# 6. Check AlertManager status
oc get pods -n openshift-monitoring | grep alertmanager
```

---

## Rollback

```bash
oc delete prometheusrule poc-vm-alerts -n poc-alert
oc delete namespace poc-alert
```
