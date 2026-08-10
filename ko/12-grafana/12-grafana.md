# OpenShift 콘솔 내장 모니터링 대시보드 (Grafana Operator 불필요)

Grafana Operator, Grafana 인스턴스, Route 없이 OpenShift Virtualization 커스텀 대시보드를 OpenShift 웹 콘솔의 내장 **Observe → Dashboards** 화면에 직접 등록합니다.

---

## 개요

OpenShift 웹 콘솔은 `openshift-config-managed` Namespace에 `console.openshift.io/dashboard: "true"` 라벨이 붙은 `ConfigMap`을 발견하면 Grafana 없이도 자체적으로 커스텀 모니터링 대시보드를 렌더링합니다. `.json`으로 끝나는 `data` 키에는 예전 Grafana 6.x 스타일 대시보드 정의(`rows`/`panels`/`span`)를 담고, 콘솔은 내장 대시보드와 동일한 데이터소스인 클러스터 내장 **Thanos Querier**를 통해 모든 PromQL 쿼리를 실행합니다.

이 섹션에서 다루는 내용 (`12-grafana.sh` 1/4–2/4 단계):

- `openshift-config-managed`에 쓰기 권한이 있는지 사전 점검
- Dashboard 1: **KubeVirt VM Overall Status** (`poc-vm-overview`) — VM 상태 요약, VM별 CPU/Memory/Network/Storage
- Dashboard 2: **OpenShift Virtualization Cluster Overview** (`poc-ocpv-overview`) — 노드별 VM 분포, Phase 분포, Live Migration 상태

**[Grafana Operator 사용](#grafana-operator-사용) 대비 트레이드오프:**

- 데이터소스는 항상 클러스터 자체 Thanos Querier로 고정되어 있어, 외부/커스텀 Prometheus를 이 대시보드에 연결할 수 없습니다.
- 콘솔 대시보드 렌더러가 이해하는 패널 타입(`row`, `graph`, `singlestat`)만 지원됩니다 — 최신 Grafana 패널(`timeseries`, `stat`, `table`)보다 좁고 오래된 스키마입니다.
- 공식 문서가 충분하지 않은 콘솔 확장 포인트로, 완전히 제품화된 API가 아니어서 OpenShift 버전에 따라 ConfigMap 스키마가 바뀔 수 있습니다.
- `openshift-config-managed`에 쓰려면 cluster-admin 권한이 필요합니다.

완전한 Grafana 패널 기능, Alerting, 클러스터 외부를 가리키는 데이터소스가 필요하다면 아래 [Grafana Operator 사용](#grafana-operator-사용)을 참고하세요. Grafana 생태계의 성숙도보다 Red Hat 구독 지원 여부가 더 중요하다면 [Cluster Observability Operator (COO) 및 Red Hat build of Perses 활용](#cluster-observability-operator-coo-및-red-hat-build-of-perses-활용-가장-추천)을 대신 참고하세요 — 아래에서 설치하는 Grafana Operator는 **Community** Operator로, Red Hat 구독 지원 대상이 아닙니다.

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
# 이 섹션의 콘솔 ConfigMap을 제거하며, 존재한다면 아래 "Grafana Operator
# 사용" 섹션의 Operator 기반 리소스도 함께 제거합니다

# 또는 수동으로:
oc delete configmap poc-vm-overview-dashboard -n openshift-config-managed
oc delete configmap poc-ocpv-overview-dashboard -n openshift-config-managed
```

---

# Grafana Operator 사용

위의 콘솔 ConfigMap 방식 대신(또는 함께) [Grafana Operator](../operators/grafana-operator.md)가 관리하는 `GrafanaDashboard` 커스텀 리소스로 동일한 두 대시보드를 배포합니다. 최신 Grafana 패널 타입(`timeseries`, `stat`), Grafana Alerting, 또는 OpenShift 콘솔 밖에서도 볼 수 있는 대시보드가 필요할 때 이 방식을 사용하세요.

## 사전 요구사항

- Grafana Operator가 설치되어 있어야 함 — [operators/grafana-operator.md](../operators/grafana-operator.md) 참조. `dashboards: poc-grafana` 레이블을 가진 `Grafana` 인스턴스를 미리 만들어 둘 필요는 **없습니다** — 찾지 못하면 `12-grafana.sh`가 자동으로 하나 생성합니다(namespace `poc-grafana`).
- `env.conf`에 `GRAFANA_INSTALLED=true` (12-grafana.sh 실행 시 설치된 CSV로부터 자동 감지됨)

---

## 동작 원리

`12-grafana.sh`는 이를 3/4 단계로 실행하며, Grafana Operator 자체가 없을 때만 자동으로 생략합니다:

1. `dashboards: poc-grafana` 레이블을 가진 `Grafana` 인스턴스가 아직 없으면 새로 생성합니다 — namespace `poc-grafana`, `admin` / `env.conf`의 `GRAFANA_ADMIN_PASSWORD`(기본값 `grafana123`), edge 종료 Route 구성. [operators/grafana-operator.md](../operators/grafana-operator.md)에 문서화된 것과 동일한 구성이며, 스크립트가 없을 때만 대신 적용해 줍니다.
2. Grafana가 클러스터 내장 Thanos Querier에 인증할 수 있도록 전용 `ServiceAccount`(`poc-grafana-view`)와 `cluster-monitoring-view`에 대한 `ClusterRoleBinding`을 생성합니다.
3. 해당 ServiceAccount에서 발급한 Bearer 토큰을 사용하여 `https://thanos-querier.openshift-monitoring.svc.cluster.local:9091`을 가리키는 `GrafanaDatasource`(`thanos-querier-datasource`)를 등록합니다.
4. 위 Dashboard 1/2와 동일한 PromQL 쿼리를 사용하되 최신 Grafana 패널 스키마(`stat`, `timeseries`)로 작성된 두 개의 `GrafanaDashboard` 리소스(`poc-vm-overview-operator`, `poc-ocpv-overview-operator`)를 생성합니다.

모든 리소스는 `Grafana` 인스턴스가 위치한 namespace에 생성됩니다 — 방금 새로 만든 인스턴스이거나, 이미 다른 곳에 `dashboards: poc-grafana` 레이블로 존재하던 인스턴스일 수 있습니다(어느 쪽이든 관례상 `poc-grafana`).

> ServiceAccount 토큰은 `oc create token --duration=8760h`(1년)로 발급됩니다. 토큰은 클러스터의 `service-account-max-token-expiration` 설정에 따라 제한되며, 클러스터가 더 짧은 제한을 강제하거나 토큰이 만료된 경우 `12-grafana.sh`를 다시 실행하여 재발급하면 됩니다.

---

## 배포

```bash
./12-grafana.sh
# Grafana Operator가 감지되면 3/4 단계가 자동으로 실행됩니다 — poc-grafana
# 인스턴스가 아직 없으면 함께 생성합니다
```

---

## 접속

```bash
oc get route poc-grafana-route -n <grafana-namespace> -o jsonpath='{.spec.host}'
```

로그인(`admin` / `Grafana` CR에 설정한 비밀번호) 후 → **Dashboards** → **KubeVirt VM Overall Status (Operator)** / **OpenShift Virtualization Cluster Overview (Operator)**.

---

## 문제 해결

### Grafana에서 데이터소스가 "Unauthorized"로 표시되는 경우

```bash
# Bearer 토큰이 만료되었을 수 있습니다 — 스크립트를 다시 실행해 재발급하세요
./12-grafana.sh
```

### GrafanaDashboard/GrafanaDatasource가 동기화되지 않는 경우

```bash
oc get grafanadashboard,grafanadatasource -n <grafana-namespace>
oc describe grafanadashboard poc-vm-overview-operator -n <grafana-namespace>
# dashboard/datasource가 Grafana 인스턴스와 다른 namespace에 있다면
# Grafana CR에 해당 namespace를 포함하는 namespaceSelector가 필요합니다 —
# operators/grafana-operator.md 참조.
```

---

## 롤백

```bash
./12-grafana.sh --cleanup
# 이 Operator 기반 리소스를 제거하며, 존재한다면 위 "OpenShift 콘솔 내장
# 모니터링 대시보드" 섹션의 콘솔 ConfigMap도 함께 제거합니다

# 또는 수동으로:
oc delete grafanadashboard poc-vm-overview-operator poc-ocpv-overview-operator -n <grafana-namespace>
oc delete grafanadatasource thanos-querier-datasource -n <grafana-namespace>
oc delete serviceaccount poc-grafana-view -n <grafana-namespace>
oc delete clusterrolebinding grafana-cluster-monitoring-view
```

`--cleanup`과 위 수동 명령 모두 `Grafana` 인스턴스 자체(및 그 namespace)는 삭제하지 않습니다 — 다른 랩([11-coo](../11-coo/11-coo.md) 등)도 여기에 datasource/dashboard를 함께 등록할 수 있는 공용 리소스로 취급하기 때문입니다. 완전히 정리하려면 명시적으로 삭제하세요:

```bash
oc delete grafana poc-grafana -n <grafana-namespace>
oc delete project <grafana-namespace>   # 이 namespace를 다른 용도로 쓰지 않을 때만
```

---

# Cluster Observability Operator (COO) 및 Red Hat build of Perses 활용 (가장 추천)

위에서 설치한 Grafana Operator는 **Community** Operator입니다 — Red Hat 구독 지원 대상이 아닙니다. Red Hat이 공식 지원하는 커스텀 대시보드 대안은 **Cluster Observability Operator (COO)** — 이 자체가 Red Hat이 제공하는 Operator입니다 — 와 그 `Monitoring` `UIPlugin`이 활성화하는 **Red Hat build of Perses**입니다. 이는 CNCF Perses 프로젝트를 Red Hat이 유지보수하는 다운스트림 빌드로, OpenShift 콘솔의 **Observe → Dashboards (Perses)** 안에서 대시보드를 네이티브로 렌더링하며, 별도의 Grafana 사용자 DB 대신 Kubernetes 네이티브 RBAC를 사용합니다.

설치, 데이터소스 등록, 대시보드 배포(위에서 정의한 `poc-vm-overview` / `poc-ocpv-overview` 대시보드를 COO 내장 Grafana-import 도구로 그대로 가져오는 방법 포함), RBAC, 롤백 절차는 **[operators/perses-coo.md](../operators/perses-coo.md)**에 전체 문서화되어 있습니다.

**사전 요구사항:**

- OpenShift 4.15+ 및 Cluster Observability Operator 1.5+, **Red Hat 카탈로그**(`source: redhat-operators`)에서 설치됨 — [11-coo](../11-coo/11-coo.md)에서 사용하는 것과 동일한 COO 인스턴스

**접속 (operators/perses-coo.md에 따라 구성한 이후):**

Administrator perspective → **Observe → Dashboards (Perses)** → 드롭다운에서 대시보드 선택.
