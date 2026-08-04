# OpenShift 콘솔 내장 모니터링 대시보드 (Grafana Operator 불필요)

Grafana Operator, Grafana 인스턴스, Route 없이 OpenShift Virtualization 커스텀 대시보드를 OpenShift 웹 콘솔의 내장 **Observe → Dashboards** 화면에 직접 등록합니다.

---

## 개요

OpenShift 웹 콘솔은 `openshift-config-managed` Namespace에 `console.openshift.io/dashboard: "true"` 라벨이 붙은 `ConfigMap`을 발견하면 Grafana 없이도 자체적으로 커스텀 모니터링 대시보드를 렌더링합니다. `.json`으로 끝나는 `data` 키에는 예전 Grafana 6.x 스타일 대시보드 정의(`rows`/`panels`/`span`)를 담고, 콘솔은 내장 대시보드와 동일한 데이터소스인 클러스터 내장 **Thanos Querier**를 통해 모든 PromQL 쿼리를 실행합니다.

이 랩에서 다루는 내용:

- `openshift-config-managed`에 쓰기 권한이 있는지 사전 점검
- Dashboard 1: **KubeVirt VM Overall Status** (`poc-vm-overview`) — VM 상태 요약, VM별 CPU/Memory/Network/Storage
- Dashboard 2: **OpenShift Virtualization Cluster Overview** (`poc-ocpv-overview`) — 노드별 VM 분포, Phase 분포, Live Migration 상태

**Grafana Operator 방식 대비 트레이드오프:**

- 데이터소스는 항상 클러스터 자체 Thanos Querier로 고정되어 있어, 외부/커스텀 Prometheus를 이 대시보드에 연결할 수 없습니다.
- 콘솔 대시보드 렌더러가 이해하는 패널 타입(`row`, `graph`, `singlestat`)만 지원됩니다 — 최신 Grafana 패널(`timeseries`, `stat`, `table`)보다 좁고 오래된 스키마입니다.
- 공식 문서가 충분하지 않은 콘솔 확장 포인트로, 완전히 제품화된 API가 아니어서 OpenShift 버전에 따라 ConfigMap 스키마가 바뀔 수 있습니다.
- `openshift-config-managed`에 쓰려면 cluster-admin 권한이 필요합니다.

완전한 Grafana 패널 기능, Alerting, 클러스터 외부를 가리키는 데이터소스가 필요하다면 대신 Grafana Operator 방식을 사용하세요 (Grafana 데이터소스를 등록하는 예시는 [11-coo](../11-coo/11-coo.md) 5/5단계 참조).

---

## 사전 요구사항

- cluster-admin 권한 (`oc auth can-i create configmap -n openshift-config-managed`가 `yes`를 반환해야 함)
- Operator 설치 불필요

---

## 동작 원리

```bash
oc auth can-i create configmap -n openshift-config-managed
```

아래 형태의 ConfigMap은 콘솔이 자동으로 인식합니다 — 재시작이나 동기화 대기 시간 없이 다음 페이지 로드 시 바로 반영됩니다:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: <임의의 이름>
  namespace: openshift-config-managed
  labels:
    console.openshift.io/dashboard: "true"
data:
  <임의의 이름>.json: |
    { ... Grafana 6.x 스타일 대시보드 JSON ... }
```

---

## Dashboard 1: KubeVirt VM Overall Status (poc-vm-overview)

**이 대시보드에서 사용하는 주요 PromQL 쿼리:**

```promql
# 실행 중인 VM 수
sum(kubevirt_vmi_phase_count{phase=~"Running|running"}) or vector(0)

# 일시 중지된 VM 수
sum(kubevirt_vmi_phase_count{phase=~"Paused|paused"}) or vector(0)

# 비정상 VMI (Pending/Failed)
sum(kubevirt_vmi_phase_count{phase!~"Running|running|Paused|paused"}) or vector(0)

# 전체 활성 VMI
count(kubevirt_vmi_info) or vector(0)

# VM별 CPU 사용률 (vCPU 초/s)
rate(kubevirt_vmi_cpu_usage_seconds_total{namespace=~"$namespace", name=~"$vm"}[5m])

# 메모리 사용량 (resident bytes)
kubevirt_vmi_memory_resident_bytes{namespace=~"$namespace", name=~"$vm"}

# 메모리 사용률 (%)
kubevirt_vmi_memory_resident_bytes / (kubevirt_vmi_memory_resident_bytes + kubevirt_vmi_memory_available_bytes)

# Network RX/TX
rate(kubevirt_vmi_network_receive_bytes_total{namespace=~"$namespace", name=~"$vm"}[5m])
rate(kubevirt_vmi_network_transmit_bytes_total{namespace=~"$namespace", name=~"$vm"}[5m])

# Storage 읽기/쓰기
rate(kubevirt_vmi_storage_read_traffic_bytes_total{namespace=~"$namespace", name=~"$vm"}[5m])
rate(kubevirt_vmi_storage_write_traffic_bytes_total{namespace=~"$namespace", name=~"$vm"}[5m])
```

**대시보드 기능:**
- VM 상태 요약 — Running, Paused, Abnormal, Total 수를 singlestat 패널로 표시
- CPU, Memory, Network I/O, Storage I/O 시계열 패널
- Namespace 및 VM Name 템플릿 변수를 통한 필터링

**수동 적용:**

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
    { ... 전체 JSON은 12-grafana.sh 참조 ... }
EOF
```

---

## Dashboard 2: OpenShift Virtualization Cluster Overview (poc-ocpv-overview)

**이 대시보드에서 사용하는 주요 PromQL 쿼리:**

```promql
# 노드별 VM 수
count(kubevirt_vmi_info) by (node)

# Phase별 VMI 수 (클러스터 전체)
sum(kubevirt_vmi_phase_count) by (phase)

# 현재 진행 중인 Live Migration (Pending / Scheduling / Running)
sum(kubevirt_vmi_migrations_in_pending_phase) or vector(0)
sum(kubevirt_vmi_migrations_in_scheduling_phase) or vector(0)
sum(kubevirt_vmi_migrations_in_running_phase) or vector(0)

# 실패한 Live Migration (누적 카운터)
sum(kubevirt_vmi_migrations_failed) or vector(0)
```

**대시보드 기능:**
- 노드별 VM 분포 (누적 그래프)
- 클러스터 전체 VMI Phase 분포
- Live Migration 상태 singlestat (Pending / Scheduling / Running / Failed)

---

## 대시보드 접속

1. 모니터링 조회 권한이 있는 사용자로 OpenShift 웹 콘솔에 로그인
2. **Administrator** perspective로 전환
3. **Observe → Dashboards**
4. 대시보드 드롭다운에서 선택:
   - **KubeVirt VM Overall Status**
   - **OpenShift Virtualization Cluster Overview**

---

## VM 상태 모니터링 PromQL 참조

별도의 datasource 설정 없이, **Observe → Metrics**에서 다음 PromQL을 바로 사용하세요:

```promql
# VM 실행 상태 (Running VM 수)
sum(kubevirt_vmi_phase_count{phase="Running"})

# VM별 CPU 사용률
rate(kubevirt_vmi_cpu_usage_seconds_total[5m])

# VM 메모리 사용량
kubevirt_vmi_memory_resident_bytes

# VM 가용 메모리
kubevirt_vmi_memory_available_bytes

# VM 네트워크 수신
rate(kubevirt_vmi_network_receive_bytes_total[5m])

# VM 네트워크 송신
rate(kubevirt_vmi_network_transmit_bytes_total[5m])

# VM 디스크 읽기
rate(kubevirt_vmi_storage_read_traffic_bytes_total[5m])

# VM 디스크 쓰기
rate(kubevirt_vmi_storage_write_traffic_bytes_total[5m])

# 진행 중인 Live Migration
sum(kubevirt_vmi_migrations_in_running_phase)
```

---

## 문제 해결

### ConfigMap 생성 시 권한 거부

```bash
oc auth can-i create configmap -n openshift-config-managed
# "yes"가 반환되어야 합니다 — cluster-admin(또는 동등한 권한) 필요
```

### 대시보드가 콘솔에 표시되지 않는 경우

```bash
# ConfigMap이 올바른 라벨과 함께 존재하는지 확인
oc get configmap -n openshift-config-managed -l console.openshift.io/dashboard=true

# JSON 키가 .json으로 끝나고 올바르게 파싱되는지 확인
oc get configmap poc-vm-overview-dashboard -n openshift-config-managed \
  -o jsonpath='{.data.poc-vm-overview\.json}' | python3 -m json.tool > /dev/null && echo OK
```

ConfigMap과 라벨이 올바른데도 대시보드가 보이지 않는다면 콘솔 탭을 강력 새로고침하세요 — 대시보드 목록은 페이지 세션당 한 번만 로드됩니다.

### 패널에 데이터가 표시되지 않는 경우

```bash
# Thanos Querier에 KubeVirt 메트릭이 존재하는지 확인
oc exec -n openshift-monitoring sts/thanos-querier -c thanos-query -- \
  wget -qO- --header "Authorization: Bearer $(oc whoami -t)" \
  'https://localhost:9091/api/v1/query?query=kubevirt_vmi_info' --no-check-certificate
```

---

## 롤백

```bash
./12-grafana.sh --cleanup
# 또는 수동으로:
oc delete configmap poc-vm-overview-dashboard -n openshift-config-managed
oc delete configmap poc-ocpv-overview-dashboard -n openshift-config-managed
```
