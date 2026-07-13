# 리소스 인벤토리 — 각 Lab이 생성하는 리소스 목록

이 문서는 각 Lab 스크립트 실행 후 생성되는 **네임스페이스, VM, 주요 리소스**를 정리합니다.

---

## 요약 표

| Lab | 네임스페이스 | VM 수 | 주요 리소스 |
|-----|-------------|-------|------------|
| 00-prepare | — | — | (로컬 파일만) |
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
| 18-add-node | — | — | (운영 절차 — cordon/drain/rejoin) |
| 19-hyperconverged | — | — | (읽기 전용 — HyperConverged 정보) |
| 20-logging | — | — | LokiStack, ClusterLogForwarder, OBC, Secret |
| 21-upgrade | — | — | (문서만) |

**합계:** 네임스페이스 17개, VM 약 23개

---

## 상세 내역

### 00-prepare — Air-gapped 사전 준비

- **네임스페이스:** 없음
- **VM:** 없음
- **리소스:** 로컬 파일 다운로드 및 tarball 생성만 수행

---

### 01-template — 골든 이미지 및 템플릿

- **네임스페이스:** 없음 (기존 `openshift`, `openshift-virtualization-os-images` 사용)
- **VM:** 없음 (다른 Lab에서 사용할 Template 생성)
- **리소스:**

| 종류 | 이름 | 네임스페이스 |
|------|------|-------------|
| DataVolume | `poc-golden` | `openshift-virtualization-os-images` |
| DataSource | `poc-golden` | `openshift-virtualization-os-images` |
| Template | `poc` | `openshift` |
| ConsoleYAMLSample | `poc-datasource` | — |

---

### 02-network — NNCP + NAD + VM 네트워킹

- **네임스페이스:** `poc-network`
- **VM:**

| VM 이름 | 네임스페이스 | 보조 NIC IP |
|---------|-------------|------------|
| `poc-network-vm-1` | `poc-network` | `192.168.100.21/24` |
| `poc-network-vm-2` | `poc-network` | `192.168.100.22/24` |

- **리소스:**

| 종류 | 이름 | 네임스페이스 |
|------|------|-------------|
| NNCP | `br1-nncp` (설정 가능) | 클러스터 범위 |
| NAD | `poc-bridge-nad` 또는 `poc-bridge-vlan-nad` | `poc-network` (+ 기타 `poc-*` NS) |
| NMState | `nmstate` | 클러스터 범위 |
| ConsoleYAMLSample | NNCP/NAD 샘플 | — |

---

### 03-vm-workload — VM 생성 및 Live Migration

- **네임스페이스:** `poc-vm`
- **VM:**

| VM 이름 | 네임스페이스 | 보조 NIC IP |
|---------|-------------|------------|
| `poc-vm` | `poc-vm` | `192.168.100.31/24` |

- **리소스:**

| 종류 | 이름 | 네임스페이스 |
|------|------|-------------|
| NAD | `poc-bridge-nad` | `poc-vm` |
| ConsoleYAMLSample | `poc-virtualmachine` | — |

---

### 04-multitenancy — 네임스페이스 격리 및 RBAC

- **네임스페이스:** `poc-multitenancy-1`, `poc-multitenancy-2`
- **VM:**

| VM 이름 | 네임스페이스 |
|---------|-------------|
| `poc-mt-vm-1` | `poc-multitenancy-1` |
| `poc-mt-vm-2` | `poc-multitenancy-2` |

- **리소스:**

| 종류 | 이름 | 네임스페이스 |
|------|------|-------------|
| Secret | `htpasswd-secret` | `openshift-config` |
| OAuth IDP | `poc-htpasswd` | 클러스터 범위 |
| Users | `user1`, `user2`, `user3`, `user4` | — |
| RoleBinding | user1→NS1 admin, user2→NS1 view | `poc-multitenancy-1` |
| RoleBinding | user3→NS2 admin, user4→NS2 view | `poc-multitenancy-2` |
| RoleBinding | user1,user3→view | `openshift-virtualization-os-images` |

---

### 05-network-policy — NetworkPolicy

- **네임스페이스:** `poc-network-policy-1`, `poc-network-policy-2`
- **VM:**

| VM 이름 | 네임스페이스 |
|---------|-------------|
| `poc-vm-1` | `poc-network-policy-1` |
| `poc-vm-2` | `poc-network-policy-2` |

- **리소스:**

| 종류 | 이름 | 네임스페이스 |
|------|------|-------------|
| NetworkPolicy | `deny-all` | NS1, NS2 |
| NetworkPolicy | `allow-same-network` | NS1, NS2 |
| NetworkPolicy | `allow-access-from-project1` | NS2만 |
| ConsoleYAMLSample | 3개 샘플 | — |

---

### 06-resource-quota — ResourceQuota

- **네임스페이스:** `poc-resource-quota`
- **VM:**

| VM 이름 | 네임스페이스 | 비고 |
|---------|-------------|------|
| `poc-quota-vm-1` | `poc-resource-quota` | 정상 생성 및 시작 |
| `poc-quota-vm-2` | `poc-resource-quota` | 정상 생성 및 시작 |
| `poc-quota-vm-3` | `poc-resource-quota` | 쿼터에 의해 거부 예상 |

- **리소스:**

| 종류 | 이름 | 네임스페이스 |
|------|------|-------------|
| ResourceQuota | `poc-quota` | `poc-resource-quota` |
| ConsoleYAMLSample | `poc-resource-quota` | — |

쿼터 제한: pods=10, requests.cpu=2, requests.memory=4Gi

---

### 07-descheduler — VM 재스케줄링

- **네임스페이스:** `poc-descheduler`
- **VM:**

| VM 이름 | 네임스페이스 | 비고 |
|---------|-------------|------|
| `poc-descheduler-vm-1` | `poc-descheduler` | 디스케줄러 대상 |
| `poc-descheduler-vm-2` | `poc-descheduler` | 디스케줄러 대상 |
| `poc-descheduler-vm-3` | `poc-descheduler` | 디스케줄러 대상 |
| `poc-descheduler-vm-fixed` | `poc-descheduler` | 노드 고정, 제외 |
| `poc-descheduler-vm-trigger` | — | YAML 생성만, 미적용 |

- **리소스:**

| 종류 | 이름 | 네임스페이스 |
|------|------|-------------|
| KubeDescheduler | `cluster` | `openshift-kube-descheduler-operator` |
| ConsoleYAMLSample | `poc-kubedescheduler` | — |

---

### 08-liveness-probe — VM 헬스 체크

- **네임스페이스:** `poc-liveness-probe`
- **VM:**

| VM 이름 | 네임스페이스 | 프로브 |
|---------|-------------|--------|
| `poc-liveness-vm` | `poc-liveness-probe` | HTTP liveness + readiness (포트 80) |

- **리소스:**

| 종류 | 이름 | 네임스페이스 |
|------|------|-------------|
| ConsoleYAMLSample | `poc-liveness-vm` | — |

---

### 09-alert — PrometheusRule 알림

- **네임스페이스:** `poc-alert`
- **VM:**

| VM 이름 | 네임스페이스 |
|---------|-------------|
| `poc-alert-vm` | `poc-alert` |

- **리소스:**

| 종류 | 이름 | 네임스페이스 |
|------|------|-------------|
| ConfigMap | `cluster-monitoring-config` | `openshift-monitoring` |
| PrometheusRule | `poc-vm-alerts` | `poc-alert` |
| ConsoleYAMLSample | `poc-prometheusrule-vm-alerts` | — |

알림 규칙: VMStoppedByName, VMStopped, VMStuckPending, VMStuckStarting, VMLiveMigrationFailed, VMLowMemory

---

### 10-node-exporter — 커스텀 메트릭

- **네임스페이스:** `poc-node-exporter`
- **VM:**

| VM 이름 | 네임스페이스 | 레이블 |
|---------|-------------|--------|
| `poc-node-exporter-vm` | `poc-node-exporter` | `monitor=metrics` |

- **리소스:**

| 종류 | 이름 | 네임스페이스 |
|------|------|-------------|
| Service | `node-exporter-service` | `poc-node-exporter` |
| ServiceMonitor | `node-exporter-monitor` | `poc-node-exporter` |
| ConsoleYAMLSample | `poc-servicemonitor-node-exporter` | — |

네임스페이스 레이블: `openshift.io/cluster-monitoring=true`

---

### 11-coo — Cluster Observability Operator

- **네임스페이스:** `poc-monitoring`
- **VM:**

| VM 이름 | 네임스페이스 | 레이블 |
|---------|-------------|--------|
| `poc-coo-vm` | `poc-monitoring` | `monitor=metrics` |

- **리소스:**

| 종류 | 이름 | 네임스페이스 |
|------|------|-------------|
| Service | `poc-monitoring-node-exporter` | `poc-monitoring` |
| ServiceMonitor | `poc-vm-node-exporter-console` | `poc-monitoring` |
| MonitoringStack | `poc-monitoring-stack` | `poc-monitoring` |
| ServiceMonitor | `poc-vm-node-exporter` | `poc-monitoring` |
| PrometheusRule | `poc-vm-alerts` | `poc-monitoring` |
| GrafanaDashboard | `poc-vm-node-exporter` | `poc-monitoring` (Grafana 설치 시) |
| GrafanaDatasource | `coo-prometheus-datasource` | `poc-monitoring` (Grafana 설치 시) |

실행 중인 VMI가 있는 각 네임스페이스에 추가로 Service + ServiceMonitor 생성.

---

### 12-grafana — Grafana 대시보드

- **네임스페이스:** `poc-monitoring` (11-coo와 공유)
- **VM:** 없음
- **리소스:**

| 종류 | 이름 | 네임스페이스 |
|------|------|-------------|
| Grafana | `poc-grafana` | `poc-monitoring` |
| Route | `poc-grafana-route` | `poc-monitoring` |
| ClusterRoleBinding | `grafana-cluster-monitoring-view` | 클러스터 범위 |
| GrafanaDatasource | `prometheus-datasource` | `poc-monitoring` |
| GrafanaDashboard | `poc-vm-overview` | `poc-monitoring` |
| GrafanaDashboard | `grafana-dashboard-ocp-v` | `poc-monitoring` |

---

### 13-mtv — VMware 마이그레이션

- **네임스페이스:** `poc-mtv`
- **VM:** 없음 (마이그레이션 전 체크리스트만 표시)
- **리소스:** 없음

---

### 14-oadp — VM 백업/복원

- **네임스페이스:** `poc-oadp`
- **VM:**

| VM 이름 | 네임스페이스 |
|---------|-------------|
| `poc-oadp-vm` | `poc-oadp` |

- **리소스:**

| 종류 | 이름 | 네임스페이스 |
|------|------|-------------|
| ObjectBucketClaim | `obc-backups` | `openshift-adp` (ODF만) |
| Secret | `cloud-credentials` | `openshift-adp` |
| DataProtectionApplication | `poc-dpa` | `openshift-adp` |
| Backup | `poc-oadp-backup` | `openshift-adp` |
| VolumeSnapshotClass | `poc-volumesnapshotclass` | 클러스터 범위 (YAML만) |
| ConsoleYAMLSample | 3개 샘플 | — |

Restore YAML은 생성되지만 적용되지 않음.

---

### 15-node-maintenance — 노드 유지보수 + Live Migration

- **네임스페이스:** `poc-maintenance`
- **VM:**

| VM 이름 | 네임스페이스 | evictionStrategy |
|---------|-------------|-----------------|
| `poc-maintenance-vm-1` | `poc-maintenance` | LiveMigrate |
| `poc-maintenance-vm-2` | `poc-maintenance` | LiveMigrate |

- **리소스:**

| 종류 | 이름 | 네임스페이스 |
|------|------|-------------|
| NodeMaintenance | `maintenance-${NODE1}` | 클러스터 범위 (YAML만) |
| ConsoleYAMLSample | `poc-nodemaintenance` | — |

VirtualMachineInstanceMigration YAML 파일도 생성됨.

---

### 16-snr — Self Node Remediation

- **네임스페이스:** `poc-snr`
- **VM:**

| VM 이름 | 네임스페이스 | 비고 |
|---------|-------------|------|
| `poc-snr-vm-1` | `poc-snr` | 테스트 노드 고정, LiveMigrate |
| `poc-snr-vm-2` | `poc-snr` | 테스트 노드 고정, LiveMigrate |

- **리소스:**

| 종류 | 이름 | 네임스페이스 |
|------|------|-------------|
| SelfNodeRemediationTemplate | `poc-snr-template` | `openshift-workload-availability` |
| NodeHealthCheck | `poc-snr-nhc` | 클러스터 범위 |
| ConsoleYAMLSample | `poc-nodehealthcheck-snr` | — |

NHC 트리거: Ready=False 또는 Unknown 300초 지속 시

---

### 17-far — Fence Agent Remediation

- **네임스페이스:** `poc-far`
- **VM:** 없음
- **리소스:**

| 종류 | 이름 | 네임스페이스 |
|------|------|-------------|
| Secret | `poc-far-credentials` | `openshift-workload-availability` |
| FenceAgentsRemediationTemplate | `poc-far-template` | `openshift-workload-availability` |
| NodeHealthCheck | `poc-far-nhc` | 클러스터 범위 |
| ConsoleYAMLSample | 2개 샘플 | — |

---

### 18-add-node — 워커 노드 제거 및 재합류

- **네임스페이스:** 없음
- **VM:** 없음
- **리소스:** 없음 (대화형 운영 절차: cordon → drain → 노드 삭제 → kubelet 재시작 → CSR 승인)

---

### 19-hyperconverged — CPU Overcommit 설정

- **네임스페이스:** 없음
- **VM:** 없음
- **리소스:** 없음 (읽기 전용 — 현재 HyperConverged CR 설정 표시 및 패치 예시 제공)

---

### 20-logging — LokiStack 감사 로깅

- **네임스페이스:** 없음 (기존 `openshift-logging` 사용)
- **VM:** 없음
- **리소스:**

| 종류 | 이름 | 네임스페이스 |
|------|------|-------------|
| APIServer | `cluster` (패치) | 클러스터 범위 |
| ObjectBucketClaim | `obc-loki` | `openshift-logging` (ODF만) |
| Secret | `logging-loki-s3` | `openshift-logging` |
| LokiStack | `logging-loki` | `openshift-logging` |
| ClusterLogForwarder | `instance` | `openshift-logging` |
| ClusterLogging | `instance` | `openshift-logging` (v5만) |
| ServiceAccount | `collector` | `openshift-logging` (v6만) |
| UIPlugin | `logging` | 클러스터 범위 (v6만) |

---

### 21-upgrade — Airgap OCP 업그레이드

- 문서만 제공 (`21-upgrade.md`), 셸 스크립트 없음.

---

## 전체 생성 네임스페이스 (알파벳순)

| 네임스페이스 | 생성 Lab |
|-------------|----------|
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

## 전체 생성 VM (네임스페이스별)

| 네임스페이스 | VM 이름 | Lab |
|-------------|---------|-----|
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
