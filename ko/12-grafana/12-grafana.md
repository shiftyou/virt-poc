# Grafana Operator + OpenShift Prometheus DataSource + Dashboard

Grafana Operator를 통해 Grafana를 배포하고, OpenShift 내장 Prometheus와 연동하여 OpenShift Virtualization 모니터링용 대시보드 두 개를 배포합니다.

---

## 개요

이 랩에서 다루는 내용:

- Grafana Community Operator 설치 (`poc-monitoring` namespace 범위)
- Route 접근이 가능한 Grafana 인스턴스 배포
- OpenShift 내장 Prometheus datasource 연동 (thanos-querier:9091 + Bearer token)
- Dashboard 1: **KubeVirt VM Overall Status** (`poc-vm-overview`) — 인라인 JSON, kubevirt 메트릭
- Dashboard 2: **OpenShift Virtualization Dashboard** (`grafana-dashboard-ocp-v`) — 외부 URL에서 로드

---

## 사전 요구사항

- Grafana Community Operator 설치 완료 (아래 설치 가이드 참조)
- `env.conf`에 `GRAFANA_ADMIN_PASS` 설정 (기본값: `grafana123`)

---

## Grafana Community Operator 설치

OperatorHub(community-operators)에서 Grafana Operator를 `poc-monitoring` namespace 범위로 설치합니다.

```bash
# namespace 생성 (존재하지 않는 경우)
oc new-project poc-monitoring

# Grafana Operator 설치 (namespace 범위)
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: grafana-operator-group
  namespace: poc-monitoring
spec:
  targetNamespaces:
    - poc-monitoring
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: grafana-operator
  namespace: poc-monitoring
spec:
  channel: v5
  name: grafana-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF

# 설치 완료 확인 (Succeeded 상태 대기)
oc get csv -n poc-monitoring | grep grafana
# grafana-operator.v5.x.x   Grafana Operator   5.x.x   Succeeded

# setup 스크립트를 다시 실행하여 GRAFANA_INSTALLED=true 업데이트
./12-grafana.sh
```

---

## Grafana 인스턴스 배포

```bash
source env.conf

oc apply -f - <<EOF
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: poc-grafana
  namespace: poc-monitoring
  labels:
    dashboards: poc-grafana
spec:
  config:
    auth:
      disable_login_form: "false"
    auth.anonymous:
      enabled: "false"
    security:
      admin_user: admin
      admin_password: ${GRAFANA_ADMIN_PASS:-grafana123}
EOF
```

### OpenShift Route 생성

```bash
oc apply -f - <<'EOF'
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: poc-grafana-route
  namespace: poc-monitoring
  labels:
    app: grafana
spec:
  to:
    kind: Service
    name: poc-grafana-service
  port:
    targetPort: grafana
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

# 접속 URL 출력
echo "https://$(oc get route poc-grafana-route -n poc-monitoring \
  -o jsonpath='{.spec.host}')"
```

---

## OpenShift Prometheus DataSource 연동

Grafana는 Bearer token을 사용하여 thanos-querier 엔드포인트를 통해 OpenShift 내장 Prometheus에 연결됩니다.

```bash
# Grafana SA에 cluster-monitoring-view 권한 부여
oc create clusterrolebinding grafana-cluster-monitoring-view \
  --clusterrole=cluster-monitoring-view \
  --serviceaccount=poc-monitoring:poc-grafana-sa 2>/dev/null || true

# Prometheus token 발급
TOKEN=$(oc create token poc-grafana-sa -n poc-monitoring --duration=8760h)

# GrafanaDatasource 생성
oc apply -f - <<EOF
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: prometheus-datasource
  namespace: poc-monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: poc-grafana
  datasource:
    name: Prometheus
    type: prometheus
    access: proxy
    url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
    isDefault: true
    jsonData:
      httpHeaderName1: Authorization
      timeInterval: 5s
      tlsSkipVerify: true
    secureJsonData:
      httpHeaderValue1: Bearer ${TOKEN}
EOF
```

---

## Dashboard 1: KubeVirt VM Overall Status (poc-vm-overview)

VM 상태를 클러스터 전체에 걸쳐 보여주는 인라인 JSON Grafana 대시보드를 배포합니다.

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
- VM 상태 요약 — Running, Paused, Abnormal, Total 수를 stat 패널로 표시
- VM 인벤토리 — 클러스터 전체 VMI를 테이블 뷰로 표시
- CPU, Memory, Network I/O, Storage I/O 시계열 패널
- Namespace 및 VM Name 템플릿 변수를 통한 필터링

---

## Dashboard 2: OpenShift Virtualization Dashboard (grafana-dashboard-ocp-v)

외부 URL에서 커뮤니티 OpenShift Virtualization 대시보드를 배포합니다.

```bash
oc apply -f - <<'EOF'
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: grafana-dashboard-ocp-v
  namespace: poc-monitoring
  labels:
    app: poc-grafana
spec:
  resyncPeriod: 5m
  instanceSelector:
    matchLabels:
      dashboards: poc-grafana
  folder: "Openshift Virtualization"
  url: https://raw.githubusercontent.com/leoaaraujo/articles/master/openshift-virtualization-monitoring/files/ocp-v-dashboard.json
EOF
```

**이 대시보드가 보여주는 내용:**
- OpenShift Virtualization 클러스터 개요
- VM 라이프사이클 메트릭 (생성, 삭제, 마이그레이션 비율)
- 전체 namespace에 걸친 리소스 사용량
- 노드 레벨 VM 밀도 및 리소스 압력
- namespace별로 집계된 Storage 및 Network I/O

대시보드는 URL에서 자동으로 가져오며 Grafana Operator에 의해 동기화됩니다 (`resyncPeriod: 5m`).

---

## Grafana 접속

```bash
# Grafana URL 확인
echo "https://$(oc get route poc-grafana-route -n poc-monitoring \
  -o jsonpath='{.spec.host}')"
```

**로그인 자격 증명:**

```bash
# env.conf의 GRAFANA_ADMIN_PASS 값 (기본값: grafana123)
oc get secret grafana-admin-credentials -n poc-monitoring \
  -o jsonpath='{.data.GF_SECURITY_ADMIN_USER}' | base64 -d && echo
oc get secret grafana-admin-credentials -n poc-monitoring \
  -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' | base64 -d && echo
```

**대시보드 탐색:**

1. Grafana URL에 로그인
2. 좌측 메뉴 → **Dashboards**
3. **KubeVirt VM Overall Status** — `/d/poc-vm-overview`
4. **Openshift Virtualization** 폴더 → ocp-v 대시보드 — `/d/ocp-v`

---

## VM 상태 모니터링 PromQL 참조

Prometheus DataSource가 연동된 상태에서 **Explore** 또는 커스텀 패널에서 다음 PromQL을 사용하세요:

```promql
# VM 실행 상태 (Running VM 수)
sum(kubevirt_vmi_phase_count{phase="Running"})

# VM별 CPU 사용률
rate(kubevirt_vmi_vcpu_seconds_total[5m])

# VM 메모리 사용량
kubevirt_vmi_memory_used_bytes

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

# Live Migration 상태
kubevirt_vmi_migration_phase_transition_time_from_creation_seconds
```

---

## 문제 해결

### Grafana Pod가 시작되지 않는 경우

```bash
oc get pods -n poc-monitoring -l app=poc-grafana
oc describe pod -n poc-monitoring -l app=poc-grafana
```

### DataSource 연결 실패

```bash
# ServiceAccount token 확인
oc get serviceaccount poc-grafana-sa -n poc-monitoring

# ClusterRoleBinding 확인
oc get clusterrolebinding grafana-cluster-monitoring-view

# thanos-querier 접근 가능 여부 확인
oc get service thanos-querier -n openshift-monitoring
```

### 대시보드가 Grafana에 표시되지 않는 경우

```bash
# GrafanaDashboard 동기화 상태 확인
oc get grafanadashboard -n poc-monitoring
oc describe grafanadashboard poc-vm-overview -n poc-monitoring

# 대시보드가 표시되기까지 resyncPeriod (5분)까지 걸릴 수 있음
```

### 전체 상태 확인

```bash
# Grafana Pod 상태
oc get pods -n poc-monitoring -l app=grafana

# Grafana Route 확인
oc get route -n poc-monitoring

# GrafanaDatasource 목록
oc get grafanadatasource -n poc-monitoring

# GrafanaDashboard 목록
oc get grafanadashboard -n poc-monitoring
```

---

## 롤백

```bash
./12-grafana.sh --cleanup
# 또는 수동으로:
oc delete namespace poc-monitoring
oc delete clusterrolebinding grafana-cluster-monitoring-view
```
