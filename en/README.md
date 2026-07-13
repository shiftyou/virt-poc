# virt-poc (English)

OpenShift Virtualization POC — automated scripts for air-gapped environments.

## Quick Start

```bash
cd en
./setup.sh          # Configure environment (creates env.conf)
./poc.sh start     # Run all labs (01-21)
./check-features.sh # Verify features
```

## Labs

| # | Directory | Description |
|---|-----------|-------------|
| 01 | [01-template](01-template/01-template.md) | RHEL9 qcow2 → DataVolume → DataSource → Template |
| 02 | [02-network](02-network/02-network.md) | NNCP Linux Bridge + NAD + VM networking |
| 03 | [03-vm-workload](03-vm-workload/03-vm-workload.md) | VM creation, storage, networking, Live Migration |
| 04 | [04-multitenancy](04-multitenancy/04-multitenancy.md) | Namespaces, Users, RBAC, VMs |
| 05 | [05-network-policy](05-network-policy/05-network-policy.md) | NetworkPolicy — Deny All / Allow Same NS / Allow IP |
| 06 | [06-resource-quota](06-resource-quota/06-resource-quota.md) | ResourceQuota — CPU, Memory, Pod, PVC limits |
| 07 | [07-descheduler](07-descheduler/07-descheduler.md) | VM automatic rescheduling (Descheduler) |
| 08 | [08-liveness-probe](08-liveness-probe/08-liveness-probe.md) | VM Liveness Probe — HTTP, TCP, Exec |
| 09 | [09-alert](09-alert/09-alert.md) | PrometheusRule VM notifications |
| 10 | [10-node-exporter](10-node-exporter/10-node-exporter.md) | Custom metric collection (node_exporter) |
| 11 | [11-coo](11-coo/11-coo.md) | Cluster Observability Operator MonitoringStack |
| 12 | [12-grafana](12-grafana/12-grafana.md) | Grafana Operator + Dashboard |
| 13 | [13-mtv](13-mtv/13-mtv.md) | VMware → OpenShift migration (MTV) |
| 14 | [14-oadp](14-oadp/14-oadp.md) | VM backup/restore (OADP + S3) |
| 15 | [15-node-maintenance](15-node-maintenance/15-node-maintenance.md) | Node maintenance + VM Live Migration |
| 16 | [16-snr](16-snr/16-snr.md) | Self Node Remediation |
| 17 | [17-far](17-far/17-far.md) | Fence Agent Remediation (IPMI/BMC) |
| 18 | [18-add-node](18-add-node/18-add-node.md) | Worker node removal and rejoin |
| 19 | [19-hyperconverged](19-hyperconverged/19-hyperconverged.md) | HyperConverged — CPU Overcommit |
| 20 | [20-logging](20-logging/20-logging.md) | LokiStack audit logging |
| 21 | [21-upgrade](21-upgrade/21-upgrade.md) | Airgap OCP upgrade |

## Preparation (Air-gapped)

| Document | Description |
|----------|-------------|
| [00-prepare/README.md](00-prepare/README.md) | Air-gapped preparation guide |
| [00-prepare/download.sh](00-prepare/download.sh) | Download required files |
| [00-prepare/package.sh](00-prepare/package.sh) | Create distribution tarball |

## Operator Installation Guides

| Operator | Guide |
|----------|-------|
| OpenShift Virtualization | [kubevirt-hyperconverged-operator.md](operators/kubevirt-hyperconverged-operator.md) |
| Kubernetes NMState | [nmstate-operator.md](operators/nmstate-operator.md) |
| MTV | [mtv-operator.md](operators/mtv-operator.md) |
| OADP | [oadp-operator.md](operators/oadp-operator.md) |
| Grafana | [grafana-operator.md](operators/grafana-operator.md) |
| COO | OperatorHub → "Cluster Observability Operator" |
| Kube Descheduler | [descheduler-operator.md](operators/descheduler-operator.md) |
| Node Health Check | [nhc-operator.md](operators/nhc-operator.md) |
| Self Node Remediation | [snr-operator.md](operators/snr-operator.md) |
| Fence Agents Remediation | [far-operator.md](operators/far-operator.md) |
| Node Maintenance | [node-maintenance-operator.md](operators/node-maintenance-operator.md) |
| MTC | [mtc-operator.md](operators/mtc-operator.md) |
| iSCSI Storage | [iscsi-storage.md](operators/iscsi-storage.md) |

## Reference

- [Execution Order](EXECUTION-ORDER.md)
- [Environment Config Example](env.conf.example)
