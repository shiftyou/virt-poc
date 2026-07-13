# Resource Inventory — What Each Lab Creates

This document summarizes the **namespaces, VMs, and key resources** created by each lab script after execution.

---

## Summary Table

| Lab | Namespace(s) | VMs | Key Resources |
|-----|-------------|-----|---------------|
| 00-prepare | — | — | (local files only) |
| 01-template | — | — | DataVolume, DataSource, Template |
| 02-network | `poc-network` | 2 | NNCP, NAD |
| 03-vm-workload | `poc-vm` | 1 | NAD |
| 04-multitenancy | `poc-multitenancy-1`, `-2` | 2 | Users, RBAC, OAuth |
| 05-network-policy | `poc-network-policy-1`, `-2` | 2 | NetworkPolicy ×3 |
| 06-resource-quota | `poc-resource-quota` | 3 | ResourceQuota |
| 07-descheduler | `poc-descheduler` | 4 | KubeDescheduler |
| 08-liveness-probe | `poc-liveness-probe` | 1 | — |
| 09-alert | `poc-alert` | 1 | PrometheusRule |
| 10-node-exporter | `poc-node-exporter` | 1 | Service, ServiceMonitor |
| 11-coo | `poc-monitoring` | 1 | MonitoringStack, ServiceMonitor, PrometheusRule |
| 12-grafana | `poc-monitoring` | — | Grafana, GrafanaDashboard ×2, GrafanaDatasource |
| 13-mtv | `poc-mtv` | — | — |
| 14-oadp | `poc-oadp` | 1 | DPA, Backup, OBC, Secret |
| 15-node-maintenance | `poc-maintenance` | 2 | NodeMaintenance (YAML) |
| 16-snr | `poc-snr` | 2 | SelfNodeRemediationTemplate, NodeHealthCheck |
| 17-far | `poc-far` | — | FenceAgentsRemediationTemplate, NodeHealthCheck, Secret |
| 18-add-node | — | — | (operational — cordon/drain/rejoin) |
| 19-hyperconverged | — | — | (read-only — HyperConverged info) |
| 20-logging | — | — | LokiStack, ClusterLogForwarder, OBC, Secret |
| 21-upgrade | — | — | (documentation only) |

**Totals:** 17 namespaces created, ~23 VMs

---

## Detailed Breakdown

### 00-prepare — Air-gapped Preparation

- **Namespaces:** none
- **VMs:** none
- **Resources:** local file downloads and tarball creation only

---

### 01-template — Golden Image & Template

- **Namespaces:** none (uses existing `openshift`, `openshift-virtualization-os-images`)
- **VMs:** none (creates a Template for other labs)
- **Resources:**

| Kind | Name | Namespace |
|------|------|-----------|
| DataVolume | `poc-golden` | `openshift-virtualization-os-images` |
| DataSource | `poc-golden` | `openshift-virtualization-os-images` |
| Template | `poc` | `openshift` |
| ConsoleYAMLSample | `poc-datasource` | — |

---

### 02-network — NNCP + NAD + VM Networking

- **Namespaces:** `poc-network`
- **VMs:**

| VM Name | Namespace | Secondary NIC IP |
|---------|-----------|-----------------|
| `poc-network-vm-1` | `poc-network` | `192.168.100.21/24` |
| `poc-network-vm-2` | `poc-network` | `192.168.100.22/24` |

- **Resources:**

| Kind | Name | Namespace |
|------|------|-----------|
| NNCP | `br1-nncp` (configurable) | cluster-scoped |
| NAD | `poc-bridge-nad` or `poc-bridge-vlan-nad` | `poc-network` (+other `poc-*` NS) |
| NMState | `nmstate` | cluster-scoped |
| ConsoleYAMLSample | NNCP/NAD samples | — |

---

### 03-vm-workload — VM Creation & Live Migration

- **Namespaces:** `poc-vm`
- **VMs:**

| VM Name | Namespace | Secondary NIC IP |
|---------|-----------|-----------------|
| `poc-vm` | `poc-vm` | `192.168.100.31/24` |

- **Resources:**

| Kind | Name | Namespace |
|------|------|-----------|
| NAD | `poc-bridge-nad` | `poc-vm` |
| ConsoleYAMLSample | `poc-virtualmachine` | — |

---

### 04-multitenancy — Namespace Isolation & RBAC

- **Namespaces:** `poc-multitenancy-1`, `poc-multitenancy-2`
- **VMs:**

| VM Name | Namespace |
|---------|-----------|
| `poc-mt-vm-1` | `poc-multitenancy-1` |
| `poc-mt-vm-2` | `poc-multitenancy-2` |

- **Resources:**

| Kind | Name | Namespace |
|------|------|-----------|
| Secret | `htpasswd-secret` | `openshift-config` |
| OAuth IDP | `poc-htpasswd` | cluster-scoped |
| Users | `user1`, `user2`, `user3`, `user4` | — |
| RoleBinding | user1→NS1 admin, user2→NS1 view | `poc-multitenancy-1` |
| RoleBinding | user3→NS2 admin, user4→NS2 view | `poc-multitenancy-2` |
| RoleBinding | user1,user3→view | `openshift-virtualization-os-images` |

---

### 05-network-policy — NetworkPolicy

- **Namespaces:** `poc-network-policy-1`, `poc-network-policy-2`
- **VMs:**

| VM Name | Namespace |
|---------|-----------|
| `poc-vm-1` | `poc-network-policy-1` |
| `poc-vm-2` | `poc-network-policy-2` |

- **Resources:**

| Kind | Name | Namespace |
|------|------|-----------|
| NetworkPolicy | `deny-all` | NS1, NS2 |
| NetworkPolicy | `allow-same-network` | NS1, NS2 |
| NetworkPolicy | `allow-access-from-project1` | NS2 only |
| ConsoleYAMLSample | 3 samples | — |

---

### 06-resource-quota — ResourceQuota

- **Namespaces:** `poc-resource-quota`
- **VMs:**

| VM Name | Namespace | Notes |
|---------|-----------|-------|
| `poc-quota-vm-1` | `poc-resource-quota` | created and started |
| `poc-quota-vm-2` | `poc-resource-quota` | created and started |
| `poc-quota-vm-3` | `poc-resource-quota` | expected to be rejected by quota |

- **Resources:**

| Kind | Name | Namespace |
|------|------|-----------|
| ResourceQuota | `poc-quota` | `poc-resource-quota` |
| ConsoleYAMLSample | `poc-resource-quota` | — |

Quota limits: pods=10, requests.cpu=2, requests.memory=4Gi

---

### 07-descheduler — VM Rescheduling

- **Namespaces:** `poc-descheduler`
- **VMs:**

| VM Name | Namespace | Notes |
|---------|-----------|-------|
| `poc-descheduler-vm-1` | `poc-descheduler` | descheduler target |
| `poc-descheduler-vm-2` | `poc-descheduler` | descheduler target |
| `poc-descheduler-vm-3` | `poc-descheduler` | descheduler target |
| `poc-descheduler-vm-fixed` | `poc-descheduler` | pinned to node, excluded |
| `poc-descheduler-vm-trigger` | — | YAML generated, not applied |

- **Resources:**

| Kind | Name | Namespace |
|------|------|-----------|
| KubeDescheduler | `cluster` | `openshift-kube-descheduler-operator` |
| ConsoleYAMLSample | `poc-kubedescheduler` | — |

---

### 08-liveness-probe — VM Health Check

- **Namespaces:** `poc-liveness-probe`
- **VMs:**

| VM Name | Namespace | Probes |
|---------|-----------|--------|
| `poc-liveness-vm` | `poc-liveness-probe` | HTTP liveness + readiness on port 80 |

- **Resources:**

| Kind | Name | Namespace |
|------|------|-----------|
| ConsoleYAMLSample | `poc-liveness-vm` | — |

---

### 09-alert — PrometheusRule Alerts

- **Namespaces:** `poc-alert`
- **VMs:**

| VM Name | Namespace |
|---------|-----------|
| `poc-alert-vm` | `poc-alert` |

- **Resources:**

| Kind | Name | Namespace |
|------|------|-----------|
| ConfigMap | `cluster-monitoring-config` | `openshift-monitoring` |
| PrometheusRule | `poc-vm-alerts` | `poc-alert` |
| ConsoleYAMLSample | `poc-prometheusrule-vm-alerts` | — |

Alerts: VMStoppedByName, VMStopped, VMStuckPending, VMStuckStarting, VMLiveMigrationFailed, VMLowMemory

---

### 10-node-exporter — Custom Metrics

- **Namespaces:** `poc-node-exporter`
- **VMs:**

| VM Name | Namespace | Labels |
|---------|-----------|--------|
| `poc-node-exporter-vm` | `poc-node-exporter` | `monitor=metrics` |

- **Resources:**

| Kind | Name | Namespace |
|------|------|-----------|
| Service | `node-exporter-service` | `poc-node-exporter` |
| ServiceMonitor | `node-exporter-monitor` | `poc-node-exporter` |
| ConsoleYAMLSample | `poc-servicemonitor-node-exporter` | — |

Namespace label: `openshift.io/cluster-monitoring=true`

---

### 11-coo — Cluster Observability Operator

- **Namespaces:** `poc-monitoring`
- **VMs:**

| VM Name | Namespace | Labels |
|---------|-----------|--------|
| `poc-coo-vm` | `poc-monitoring` | `monitor=metrics` |

- **Resources:**

| Kind | Name | Namespace |
|------|------|-----------|
| Service | `poc-monitoring-node-exporter` | `poc-monitoring` |
| ServiceMonitor | `poc-vm-node-exporter-console` | `poc-monitoring` |
| MonitoringStack | `poc-monitoring-stack` | `poc-monitoring` |
| ServiceMonitor | `poc-vm-node-exporter` | `poc-monitoring` |
| PrometheusRule | `poc-vm-alerts` | `poc-monitoring` |
| GrafanaDashboard | `poc-vm-node-exporter` | `poc-monitoring` (if Grafana installed) |
| GrafanaDatasource | `coo-prometheus-datasource` | `poc-monitoring` (if Grafana installed) |

Also creates per-VMI Service + ServiceMonitor in each namespace with running VMIs.

---

### 12-grafana — Grafana Dashboards

- **Namespaces:** `poc-monitoring` (shared with 11-coo)
- **VMs:** none
- **Resources:**

| Kind | Name | Namespace |
|------|------|-----------|
| Grafana | `poc-grafana` | `poc-monitoring` |
| Route | `poc-grafana-route` | `poc-monitoring` |
| ClusterRoleBinding | `grafana-cluster-monitoring-view` | cluster-scoped |
| GrafanaDatasource | `prometheus-datasource` | `poc-monitoring` |
| GrafanaDashboard | `poc-vm-overview` | `poc-monitoring` |
| GrafanaDashboard | `grafana-dashboard-ocp-v` | `poc-monitoring` |

---

### 13-mtv — VMware Migration

- **Namespaces:** `poc-mtv`
- **VMs:** none (displays pre-migration checklist only)
- **Resources:** none

---

### 14-oadp — VM Backup/Restore

- **Namespaces:** `poc-oadp`
- **VMs:**

| VM Name | Namespace |
|---------|-----------|
| `poc-oadp-vm` | `poc-oadp` |

- **Resources:**

| Kind | Name | Namespace |
|------|------|-----------|
| ObjectBucketClaim | `obc-backups` | `openshift-adp` (ODF only) |
| Secret | `cloud-credentials` | `openshift-adp` |
| DataProtectionApplication | `poc-dpa` | `openshift-adp` |
| Backup | `poc-oadp-backup` | `openshift-adp` |
| VolumeSnapshotClass | `poc-volumesnapshotclass` | cluster-scoped (YAML only) |
| ConsoleYAMLSample | 3 samples | — |

Restore YAML is generated but not applied.

---

### 15-node-maintenance — Node Maintenance + Live Migration

- **Namespaces:** `poc-maintenance`
- **VMs:**

| VM Name | Namespace | evictionStrategy |
|---------|-----------|-----------------|
| `poc-maintenance-vm-1` | `poc-maintenance` | LiveMigrate |
| `poc-maintenance-vm-2` | `poc-maintenance` | LiveMigrate |

- **Resources:**

| Kind | Name | Namespace |
|------|------|-----------|
| NodeMaintenance | `maintenance-${NODE1}` | cluster-scoped (YAML only) |
| ConsoleYAMLSample | `poc-nodemaintenance` | — |

VirtualMachineInstanceMigration YAML files are also generated.

---

### 16-snr — Self Node Remediation

- **Namespaces:** `poc-snr`
- **VMs:**

| VM Name | Namespace | Notes |
|---------|-----------|-------|
| `poc-snr-vm-1` | `poc-snr` | pinned to test node, LiveMigrate |
| `poc-snr-vm-2` | `poc-snr` | pinned to test node, LiveMigrate |

- **Resources:**

| Kind | Name | Namespace |
|------|------|-----------|
| SelfNodeRemediationTemplate | `poc-snr-template` | `openshift-workload-availability` |
| NodeHealthCheck | `poc-snr-nhc` | cluster-scoped |
| ConsoleYAMLSample | `poc-nodehealthcheck-snr` | — |

NHC triggers: Ready=False or Unknown for 300s

---

### 17-far — Fence Agent Remediation

- **Namespaces:** `poc-far`
- **VMs:** none
- **Resources:**

| Kind | Name | Namespace |
|------|------|-----------|
| Secret | `poc-far-credentials` | `openshift-workload-availability` |
| FenceAgentsRemediationTemplate | `poc-far-template` | `openshift-workload-availability` |
| NodeHealthCheck | `poc-far-nhc` | cluster-scoped |
| ConsoleYAMLSample | 2 samples | — |

---

### 18-add-node — Worker Node Removal & Rejoin

- **Namespaces:** none
- **VMs:** none
- **Resources:** none (interactive operational procedure: cordon → drain → delete node → kubelet restart → CSR approve)

---

### 19-hyperconverged — CPU Overcommit Settings

- **Namespaces:** none
- **VMs:** none
- **Resources:** none (read-only — displays current HyperConverged CR settings and provides patch examples)

---

### 20-logging — LokiStack Audit Logging

- **Namespaces:** none (uses existing `openshift-logging`)
- **VMs:** none
- **Resources:**

| Kind | Name | Namespace |
|------|------|-----------|
| APIServer | `cluster` (patched) | cluster-scoped |
| ObjectBucketClaim | `obc-loki` | `openshift-logging` (ODF only) |
| Secret | `logging-loki-s3` | `openshift-logging` |
| LokiStack | `logging-loki` | `openshift-logging` |
| ClusterLogForwarder | `instance` | `openshift-logging` |
| ClusterLogging | `instance` | `openshift-logging` (v5 only) |
| ServiceAccount | `collector` | `openshift-logging` (v6 only) |
| UIPlugin | `logging` | cluster-scoped (v6 only) |

---

### 21-upgrade — Airgap OCP Upgrade

- Documentation only (`21-upgrade.md`), no shell script.

---

## All Created Namespaces (alphabetical)

| Namespace | Created by |
|-----------|------------|
| `poc-alert` | 09-alert |
| `poc-descheduler` | 07-descheduler |
| `poc-far` | 17-far |
| `poc-liveness-probe` | 08-liveness-probe |
| `poc-maintenance` | 15-node-maintenance |
| `poc-monitoring` | 11-coo, 12-grafana |
| `poc-mtv` | 13-mtv |
| `poc-multitenancy-1` | 04-multitenancy |
| `poc-multitenancy-2` | 04-multitenancy |
| `poc-network` | 02-network |
| `poc-network-policy-1` | 05-network-policy |
| `poc-network-policy-2` | 05-network-policy |
| `poc-oadp` | 14-oadp |
| `poc-resource-quota` | 06-resource-quota |
| `poc-snr` | 16-snr |
| `poc-vm` | 03-vm-workload |

## All Created VMs (by namespace)

| Namespace | VM Name | Lab |
|-----------|---------|-----|
| `poc-network` | `poc-network-vm-1` | 02 |
| `poc-network` | `poc-network-vm-2` | 02 |
| `poc-vm` | `poc-vm` | 03 |
| `poc-multitenancy-1` | `poc-mt-vm-1` | 04 |
| `poc-multitenancy-2` | `poc-mt-vm-2` | 04 |
| `poc-network-policy-1` | `poc-vm-1` | 05 |
| `poc-network-policy-2` | `poc-vm-2` | 05 |
| `poc-resource-quota` | `poc-quota-vm-1` | 06 |
| `poc-resource-quota` | `poc-quota-vm-2` | 06 |
| `poc-resource-quota` | `poc-quota-vm-3` | 06 |
| `poc-descheduler` | `poc-descheduler-vm-1` | 07 |
| `poc-descheduler` | `poc-descheduler-vm-2` | 07 |
| `poc-descheduler` | `poc-descheduler-vm-3` | 07 |
| `poc-descheduler` | `poc-descheduler-vm-fixed` | 07 |
| `poc-liveness-probe` | `poc-liveness-vm` | 08 |
| `poc-alert` | `poc-alert-vm` | 09 |
| `poc-node-exporter` | `poc-node-exporter-vm` | 10 |
| `poc-monitoring` | `poc-coo-vm` | 11 |
| `poc-oadp` | `poc-oadp-vm` | 14 |
| `poc-maintenance` | `poc-maintenance-vm-1` | 15 |
| `poc-maintenance` | `poc-maintenance-vm-2` | 15 |
| `poc-snr` | `poc-snr-vm-1` | 16 |
| `poc-snr` | `poc-snr-vm-2` | 16 |
