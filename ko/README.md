# virt-poc (한국어)

OpenShift Virtualization POC — Air-gapped 환경을 위한 자동화 스크립트.

## 빠른 시작

```bash
cd ko
./setup.sh          # 환경 설정 (env.conf 생성)
./poc.sh start     # 전체 Lab 실행 (01-21)
./check.sh # 기능 검증
```

## Lab 목록

| # | 디렉토리 | 설명 |
|---|----------|------|
| 01 | [01-template](01-template/01-template.md) | RHEL9 qcow2 → DataVolume → DataSource → Template 등록 |
| 02 | [02-network](02-network/02-network.md) | NNCP Linux Bridge + NAD + VM 네트워크 구성 |
| 03 | [03-vm-workload](03-vm-workload/03-vm-workload.md) | VM 생성, 스토리지, 네트워크, Live Migration |
| 04 | [04-multitenancy](04-multitenancy/04-multitenancy.md) | Namespace, 사용자, RBAC, VM |
| 05 | [05-network-policy](05-network-policy/05-network-policy.md) | NetworkPolicy — 전체 차단 / 같은 NS 허용 / IP 허용 |
| 06 | [06-resource-quota](06-resource-quota/06-resource-quota.md) | ResourceQuota — CPU, Memory, Pod, PVC 제한 |
| 07 | [07-descheduler](07-descheduler/07-descheduler.md) | VM 자동 재스케줄링 (Descheduler) |
| 08 | [08-liveness-probe](08-liveness-probe/08-liveness-probe.md) | VM Liveness Probe — HTTP, TCP, Exec |
| 09 | [09-alert](09-alert/09-alert.md) | PrometheusRule VM 알림 설정 |
| 10 | [10-node-exporter](10-node-exporter/10-node-exporter.md) | 커스텀 메트릭 수집 (node_exporter) |
| 11 | [11-coo](11-coo/11-coo.md) | Cluster Observability Operator MonitoringStack |
| 12 | [12-grafana](12-grafana/12-grafana.md) | OpenShift 콘솔 내장 대시보드 (Grafana Operator 불필요) |
| 13 | [13-mtv](13-mtv/13-mtv.md) | VMware → OpenShift 마이그레이션 (MTV) |
| 14 | [14-oadp](14-oadp/14-oadp.md) | VM 백업/복원 (OADP + S3) |
| 15 | [15-node-maintenance](15-node-maintenance/15-node-maintenance.md) | 노드 유지보수 + VM Live Migration |
| 16 | [16-snr](16-snr/16-snr.md) | Self Node Remediation (노드 자가 복구) |
| 17 | [17-far](17-far/17-far.md) | Fence Agent Remediation (IPMI/BMC 전원 복구) |
| 18 | [18-add-node](18-add-node/18-add-node.md) | 워커 노드 제거 및 재합류 |
| 19 | [19-hyperconverged](19-hyperconverged/19-hyperconverged.md) | HyperConverged — CPU Overcommit 설정 |
| 20 | [20-logging](20-logging/20-logging.md) | LokiStack 감사 로깅 |
| 21 | [21-upgrade](21-upgrade/21-upgrade.md) | Airgap OCP 업그레이드 |

## 사전 준비 (Air-gapped)

| 문서 | 설명 |
|------|------|
| [AIRGAP.md](../AIRGAP.md) | Air-gapped 환경 준비 가이드 |
| [download.sh](../download.sh) | 필요 파일 다운로드 |
| [package.sh](../package.sh) | 배포 tarball 생성 |

## Operator 설치 가이드

| Operator | 가이드 |
|----------|--------|
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
| iSCSI 스토리지 | [iscsi-storage.md](operators/iscsi-storage.md) |

## 참고 문서

- [실행 순서](EXECUTION-ORDER.md)
- [환경 설정 예시](env.conf.example)
