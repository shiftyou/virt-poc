# virt-poc

A collection of OpenShift Virtualization POC (Proof of Concept) samples designed for **air-gapped environments**.

This repository provides automated scripts to test all major OpenShift Virtualization features including VM lifecycle, networking, storage (iSCSI), monitoring, backup/restore, and node management.

---

## 🎯 Purpose

- **Comprehensive testing** of OpenShift Virtualization features
- **Air-gapped ready** - all files can be downloaded and packaged offline
- **Automated deployment** - minimal manual intervention required
- **Full feature coverage** - from basic VMs to advanced HA and DR scenarios

---

## 📦 Quick Start (Internet-connected)

```bash
# 1. Clone the repository
git clone https://github.com/shiftyou/virt-poc.git
cd virt-poc

# 2. Configure the environment (creates env.conf)
./setup.sh

# 3. Run all steps in order
./make.sh

# 4. Verify all features
./check-features.sh
```

> 📘 **상세 실행 순서는 [EXECUTION-ORDER.md](EXECUTION-ORDER.md) 참조**

---

## 📋 실행 플로우

```
┌─────────────────────────────────────────────────────────────┐
│          인터넷 연결 환경                                    │
├─────────────────────────────────────────────────────────────┤
│  1. git clone                                               │
│  2. oc login (cluster-admin)                                │
│  3. Operator 설치 (Console 또는 CLI)                        │
│  4. ./setup.sh         → env.conf 생성                      │
│  5. ./make.sh          → 전체 Lab 실행 (01-21)              │
│  6. ./check-features.sh → 기능 검증                         │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│          Air-gapped 환경                                     │
├─────────────────────────────────────────────────────────────┤
│  Phase 1: 인터넷 연결 PC                                    │
│    1. git clone                                             │
│    2. cd 00-prepare                                         │
│    3. ./download.sh    → 필요 파일 다운로드                 │
│    4. ./package.sh     → tarball 생성                       │
│    5. USB/전송         → Bastion으로 이동                   │
│                                                             │
│  Phase 2: Air-gapped Bastion                                │
│    1. tar xzf          → 패키지 추출                        │
│    2. oc login                                              │
│    3. cd 00-prepare && ./install.sh  → 환경 준비            │
│    4. cd .. && ./setup.sh            → env.conf 생성        │
│    5. ./make.sh                      → 전체 Lab 실행        │
│    6. ./check-features.sh            → 기능 검증            │
└─────────────────────────────────────────────────────────────┘
```

---

## 🔒 Air-gapped Installation

For disconnected/air-gapped environments, follow these steps:

### Phase 1: Preparation (Internet-connected)

```bash
# 1. Clone repository
git clone https://github.com/shiftyou/virt-poc.git
cd virt-poc

# 2. Download required files
cd 00-prepare
./download.sh

# 3. Create distribution package
./package.sh
# Creates: virt-poc-YYYYMMDD-HHMMSS.tar.gz

# 4. Transfer to bastion host
scp virt-poc-*.tar.gz bastion.airgap.local:/tmp/
```

### Phase 2: Installation (Air-gapped)

```bash
# 1. Extract package
cd /tmp
tar xzf virt-poc-*.tar.gz
cd virt-poc-*/

# 2. Login to OpenShift
oc login https://api.cluster.example.com:6443

# 3. Run installation script
cd 00-prepare
./install.sh

# 4. Configure environment
cd ..
./setup.sh

# 5. Run all labs
./make.sh

# 6. Verify features
./check-features.sh
```

See [00-prepare/README.md](00-prepare/README.md) for detailed air-gapped installation guide.

---

## ✅ Feature Verification

Run the automated feature check script to verify all components:

```bash
./check-features.sh

# Verbose mode for detailed output
./check-features.sh --verbose
```

This script checks:
- ✓ All operators installed and configured
- ✓ VMs running and migratable
- ✓ Network policies and quotas
- ✓ Monitoring and alerting
- ✓ Backup/restore capability
- ✓ Storage configuration (including iSCSI)
- ✓ Node management and remediation

---

## 📋 Prerequisites

### Cluster Requirements

- OpenShift 4.17 or later
- Logged into the cluster with `oc` command (cluster-admin privileges)
- `virtctl` installed — Console > `?` > **Command line tools**

### Storage Requirements

- Default StorageClass configured
- **For iSCSI**: See [operators/iscsi-storage.md](operators/iscsi-storage.md)
- **For Garage S3**: Deployed automatically in labs (air-gapped ready)

### Network Requirements

- Worker nodes with secondary NIC for VM networking (optional but recommended)
- Network connectivity for iSCSI storage (if using iSCSI)

---

## Pre-requisites: Operator Installation

`setup.sh` automatically checks whether operators are installed when run.
For uninstalled operators, refer to the guides under `operators/` to install them.

| Operator | Guide | Required |
|-----------|--------|----------|
| OpenShift Virtualization | [kubevirt-hyperconverged-operator.md](operators/kubevirt-hyperconverged-operator.md) | Required |
| Migration Toolkit for Virtualization (MTV) | [mtv-operator.md](operators/mtv-operator.md) | When using VM migration |
| Kubernetes NMState | [nmstate-operator.md](operators/nmstate-operator.md) | Required when using NNCP/NAD |
| OADP | [oadp-operator.md](operators/oadp-operator.md) | When using backup/restore |
| Fence Agents Remediation | [far-operator.md](operators/far-operator.md) | When using node failure recovery |
| Self Node Remediation | [snr-operator.md](operators/snr-operator.md) | When using node auto-recovery |
| Kube Descheduler | [descheduler-operator.md](operators/descheduler-operator.md) | When using VM rescheduling |
| Node Health Check | [nhc-operator.md](operators/nhc-operator.md) | When using node health checks |
| Node Maintenance | [node-maintenance-operator.md](operators/node-maintenance-operator.md) | When using node maintenance |
| Grafana | [grafana-operator.md](operators/grafana-operator.md) | When using monitoring dashboards |
| Cluster Observability Operator (COO) | OperatorHub → "Cluster Observability Operator" | When using namespace-scoped monitoring |
| OpenShift Logging | OperatorHub → "Red Hat OpenShift Logging" | When collecting audit logs |
| Loki Operator | OperatorHub → "Loki Operator" | When using log storage (LokiStack) |

### Storage Configuration

| Storage Type | Guide | Use Case |
|-------------|-------|----------|
| **iSCSI** | [iscsi-storage.md](operators/iscsi-storage.md) | Block storage for VM disks |
| **Garage S3** | [14-oadp/14-oadp.md](14-oadp/14-oadp.md) | Object storage for backups/logging |

---

## Environment Setup Steps

| Order | Directory | Description |
|---------|---------------------------|------|
| 01 | [01-template](01-template/01-template.md) | RHEL9 qcow2 → DataVolume → DataSource → Template registration |
| 02 | [02-network](02-network/02-network.md) | NNCP Linux Bridge creation + NAD registration + VM with NAD secondary network using poc template |
| 03 | [03-vm-workload](03-vm-workload/03-vm-workload.md) | Namespace + NAD preparation, VM creation, storage, networking, Static IP, Live Migration |
| 04 | [04-multitenancy](04-multitenancy/04-multitenancy.md) | Multi-tenancy — 2 namespaces, 4 users, RBAC (admin/view), 1 VM each |
| 05 | [05-network-policy](05-network-policy/05-network-policy.md) | NetworkPolicy lab — Deny All / Allow Same NS / Allow IP |
| 06 | [06-resource-quota](06-resource-quota/06-resource-quota.md) | ResourceQuota lab — CPU, Memory, Pod, PVC limits |
| 07 | [07-descheduler](07-descheduler/07-descheduler.md) | Descheduler lab — Concentrate 3 VMs on TEST_NODE via Live Migration, then trigger overload with trigger VM → automatic rescheduling |
| 08 | [08-liveness-probe](08-liveness-probe/08-liveness-probe.md) | VM Liveness/Readiness Probe lab — HTTP (port 1500), TCP, Exec Probe configuration and automatic restart on failure |
| 09 | [09-alert](09-alert/09-alert.md) | VM Alert lab — VM status notifications via PrometheusRule (VMNotRunning, VMStuckPending, VMLowMemory) |
| 10 | [10-node-exporter](10-node-exporter/10-node-exporter.md) | Node Exporter lab — Create poc template VM + node-exporter Service + ServiceMonitor registration |
| 11 | [11-coo](11-coo/11-coo.md) | COO MonitoringStack lab — Cluster Observability Operator, Prometheus, Grafana monitoring |
| 12 | [12-grafana](12-grafana/12-grafana.md) | Grafana lab — Grafana Operator, dashboard configuration |
| 13 | [13-mtv](13-mtv/13-mtv.md) | MTV lab — VMware to OpenShift migration (Hot-plug disabled, CBT, Windows quick-start checklist) |
| 14 | [14-oadp](14-oadp/14-oadp.md) | OADP lab — VM backup/restore (Garage S3 backend, DataProtectionApplication, Schedule) |
| 15 | [15-node-maintenance](15-node-maintenance/15-node-maintenance.md) | Node Maintenance lab — Node cordon+drain via NodeMaintenance creation → VM automatic Live Migration → uncordon after maintenance |
| 16 | [16-snr](16-snr/16-snr.md) | SNR lab — NHC detects unhealthy node → SelfNodeRemediation performs node self-restart (no IPMI required) |
| 17 | [17-far](17-far/17-far.md) | FAR lab — NHC detects unhealthy node → FenceAgentsRemediation performs IPMI/BMC power restart |
| 18 | [18-add-node](18-add-node/18-add-node.md) | Worker node removal and rejoin — stop kubelet, delete node object, approve CSR, verify rejoin |
| 19 | [19-hyperconverged](19-hyperconverged/19-hyperconverged.md) | HyperConverged configuration — CPU Overcommit ratio, Live Migration settings, Feature Gates |
| 20 | [20-logging](20-logging/20-logging.md) | Audit Logging lab — APIServer Audit Policy configuration, ClusterLogging, LokiStack, ClusterLogForwarder setup |
| 21 | [21-upgrade](21-upgrade/21-upgrade.md) | Airgap OCP 4.20→4.21 upgrade — oc-mirror, IDMS, OSUS, ClusterVersion configuration |

> The numeric order is the execution order.

---

## 🚀 Usage Tips

### Run Specific Labs

```bash
# Run individual lab
cd 03-vm-workload
./03-vm-workload.sh

# Run multiple labs in sequence
cd 01-template && ./01-template.sh
cd ../02-network && ./02-network.sh
cd ../03-vm-workload && ./03-vm-workload.sh
```

### Skip Optional Labs

Edit `make.sh` to comment out optional labs:

```bash
# Skip MTV migration lab
# run_lab 13 mtv
```

### Re-run Failed Labs

```bash
# Check what failed
./check-features.sh

# Fix and re-run specific lab
cd 14-oadp
./14-oadp.sh
```

### Clean Up Environment

```bash
# Option 1: Fast full cleanup (recommended)
./make.sh clean
# or
make clean
# - Deletes all poc-* namespaces at once (fast)
# - Removes generated YAML and temp files
# - Optionally removes downloads and tarballs

# Option 2: Safe gradual cleanup
./make.sh cleanup
# - Runs each lab's --cleanup in reverse order (21→01)
# - Respects dependencies
# - Slower but safer
```

> 📘 **차이점 상세 가이드**: [CLEAN-vs-CLEANUP.md](CLEAN-vs-CLEANUP.md) 참조

---

## 📂 Directory Structure

```
virt-poc/
├── 00-prepare/           # Air-gapped preparation scripts
│   ├── download.sh       # Download required files
│   ├── package.sh        # Create distribution tarball
│   └── README.md         # Air-gapped guide
├── operators/          # Operator installation guides
│   ├── iscsi-storage.md  # iSCSI storage configuration
│   └── ...
├── 01-21/                # Lab directories (numbered)
├── setup.sh              # Environment configuration
├── make.sh               # Run all labs in order
├── check-features.sh     # Verify all features
└── env.conf              # Generated environment config
```

---

## 🔧 Troubleshooting

### Common Issues

1. **RHEL9 image not found**
   - Download manually from Red Hat portal
   - See `00-prepare/downloads/images/README.txt`

2. **Garage container fails to start**
   - Check: `oc logs -n garage <pod>`
   - Verify image loaded: `podman images | grep garage`

3. **NNCP not applied**
   - Check worker nodes: `oc get nodes`
   - Verify NMState: `oc get nmstate`
   - Check NNCE status: `oc get nnce`

4. **iSCSI connection fails**
   - Verify initiator: `iscsiadm -m session`
   - Check network: `ping <iscsi-target-ip>`
   - See [operators/iscsi-storage.md](operators/iscsi-storage.md)

### Get Help

```bash
# Check cluster status
oc get co

# Check virtualization status
oc get hco -n openshift-cnv

# Run feature verification
./check-features.sh --verbose

# Check logs
oc logs -n openshift-cnv <virt-operator-pod>
```

---

## 🎯 Test Coverage

This POC covers all major OpenShift Virtualization features:

### Core Features ✓
- VM lifecycle management (create, start, stop, delete)
- Live migration
- VM templates and cloning
- Container disks and DataVolumes

### Networking ✓
- Secondary networks (Linux Bridge, OVN)
- VLAN configuration
- Network policies
- Multi-NIC VMs

### Storage ✓
- Block storage (iSCSI, local)
- Object storage (Garage S3)
- PVC management
- Dynamic provisioning

### High Availability ✓
- Live migration
- Node maintenance
- Automatic remediation (SNR, FAR)
- VM rescheduling (Descheduler)

### Monitoring ✓
- VM metrics collection
- Prometheus integration
- Grafana dashboards
- Alert rules

### Backup & Recovery ✓
- OADP integration
- VM backup/restore
- Schedule-based backups
- S3 storage backend

### Multi-tenancy ✓
- Namespace isolation
- RBAC configuration
- Resource quotas
- Network segmentation

---

## 📚 Reference Documentation

- [OpenShift Virtualization Official Documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/virtualization/index)
- [KubeVirt Documentation](https://kubevirt.io/user-guide/)
- [Air-gapped Installation Guide](00-prepare/README.md)
- [iSCSI Storage Configuration](operators/iscsi-storage.md)

---

## 📝 License

This project is for POC and testing purposes. Refer to individual component licenses:
- OpenShift Virtualization: Red Hat subscription required
- Garage: Apache License 2.0
- Other components: See respective documentation

---

## 🤝 Contributing

This is a POC sample repository. For issues or improvements:
1. Test in your environment
2. Document any changes
3. Share feedback

---

## ⚠️ Disclaimer

This repository is designed for **testing and POC purposes** in air-gapped environments. 
- Not intended for production use without proper review
- Always test in non-production environments first
- Follow your organization's security and compliance policies
