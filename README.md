# virt-poc

A collection of OpenShift Virtualization POC (Proof of Concept) samples designed for **air-gapped environments**.

This repository provides automated scripts to test all major OpenShift Virtualization features including VM lifecycle, networking, storage (iSCSI), monitoring, backup/restore, and node management.

---

## Language / 언어

This project is available in two languages. Each directory is fully self-contained and can be run independently.

| Language | Directory | Quick Start |
|----------|-----------|-------------|
| **English** | [`en/`](en/) | `cd en && ./setup.sh && ./poc.sh start` |
| **Korean (한국어)** | [`ko/`](ko/) | `cd ko && ./setup.sh && ./poc.sh start` |

---

## Quick Start

```bash
# 1. Clone the repository
git clone https://github.com/shiftyou/virt-poc.git
cd virt-poc

# 2. Choose your language
cd en    # English
# cd ko  # Korean (한국어)

# 3. Configure the environment (creates env.conf)
./setup.sh

# 4. Run all steps in order
./poc.sh start

# 5. Verify all features
./check-features.sh
```

---

## Directory Structure

```
virt-poc/
├── en/                       # English version (fully self-contained)
│   ├── setup.sh              # Environment configuration
│   ├── poc.sh               # Run all labs in order
│   ├── check-features.sh     # Verify all features
│   ├── env.conf.example      # Environment config template
│   ├── utils/                # Shared utilities
│   ├── operators/            # Operator installation guides
│   ├── sample/               # Sample YAML files
│   ├── 01-template/          # VM template registration
│   ├── 02-network/           # NNCP / NAD / Linux Bridge
│   ├── ...
│   └── 21-upgrade/           # Airgap upgrade
│
├── ko/                       # Korean version (fully self-contained)
│   ├── setup.sh
│   ├── poc.sh
│   ├── ...
│   └── 21-upgrade/
│
├── download.sh               # Air-gapped file downloader
├── package.sh                # Air-gapped tarball packager
├── AIRGAP.md                 # Air-gapped preparation guide
├── CLAUDE.md                 # Project conventions
└── README.md                 # This file
```

---

## Labs (01-21)

| # | Lab | Description |
|---|-----|-------------|
| 01 | template | RHEL9 qcow2 → DataVolume → DataSource → Template |
| 02 | network | NNCP Linux Bridge + NAD + VM networking |
| 03 | vm-workload | VM creation, storage, networking, Live Migration |
| 04 | multitenancy | Namespaces, Users, RBAC, VMs |
| 05 | network-policy | NetworkPolicy — Deny All / Allow Same NS / Allow IP |
| 06 | resource-quota | CPU, Memory, Pod, PVC limits |
| 07 | descheduler | VM automatic rescheduling |
| 08 | liveness-probe | HTTP, TCP, Exec Probe |
| 09 | alert | PrometheusRule VM notifications |
| 10 | node-exporter | Custom metric collection |
| 11 | coo | Cluster Observability Operator MonitoringStack |
| 12 | grafana | Grafana Operator + Dashboard |
| 13 | mtv | VMware → OpenShift migration |
| 14 | oadp | VM backup/restore (S3 backend) |
| 15 | node-maintenance | Node maintenance + VM Live Migration |
| 16 | snr | Self Node Remediation |
| 17 | far | Fence Agent Remediation (IPMI/BMC) |
| 18 | add-node | Worker node removal and rejoin |
| 19 | hyperconverged | CPU Overcommit configuration |
| 20 | logging | LokiStack audit logging |
| 21 | upgrade | Airgap OCP upgrade |

---

## Prerequisites

- OpenShift 4.17 or later
- Logged in with `oc` (cluster-admin)
- `virtctl` installed
- Default StorageClass configured

For operator installation guides, see `en/operators/` or `ko/operators/`.

---

## Air-gapped Installation

```bash
# Phase 1: Internet-connected host
./download.sh        # Download required files
./package.sh         # Create tarball

# Phase 2: Air-gapped bastion
tar xzf virt-poc-*.tar.gz
cd virt-poc-*/
./install.sh
cd en                # or cd ko
./setup.sh
./poc.sh start
```

---

## Cleanup

```bash
cd en  # or ko

# Option 1: Fast full cleanup
./poc.sh reset

# Option 2: Gradual cleanup (reverse order)
./poc.sh cleanup
```

---

## License

This project is for POC and testing purposes. Refer to individual component licenses.
