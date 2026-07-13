# Cluster Observability Operator (COO) + VM node_exporter

Cluster Observability Operator (COO)를 사용하여 VM node_exporter를 스크래핑하는 namespace 범위 모니터링.

---

## OpenShift Monitoring vs Cluster Observability Operator (COO)

OpenShift에는 두 가지 독립적인 Prometheus 기반 모니터링 스택이 있습니다.

| 항목 | OpenShift Monitoring | COO (MonitoringStack) |
|------|----------------------|----------------------|
| **Operator** | OpenShift 플랫폼에 내장 | 별도 Operator 설치 필요 |
| **범위** | 전체 클러스터 (+ user-workload) | namespace 단위 |
| **API** | `monitoring.coreos.com/v1` | `monitoring.rhobs/v1` |
| **설정** | ConfigMap (`cluster-monitoring-config`) | `MonitoringStack` CR |
| **콘솔 연동** | Console → Observe → Metrics (직접 표시) | 미지원 (port-forward 또는 Grafana) |
| **데이터 격리** | user-workload를 namespace별로 분리 가능 | MonitoringStack별로 완전 격리 |
| **보존 기간** | 클러스터 공통 설정 | MonitoringStack별 독립 설정 |
| **멀티테넌시** | RBAC를 통한 쿼리 권한 분리 | Prometheus 인스턴스 자체를 분리 |
| **주요 사용 사례** | 공통 플랫폼 및 앱 모니터링 | 팀/프로젝트별 독립 모니터링 |

### 어떤 것을 선택할까?

- **OpenShift Monitoring (user-workload)** — 추가 인프라 없이 OpenShift Console에서 바로 확인 가능.
  단일 클러스터, 중앙 집중식 모니터링에 적합.

- **COO MonitoringStack** — namespace별로 Prometheus를 독립 배포.
  팀별 메트릭 격리, 별도 보존 정책, 클러스터 Prometheus 부하 분산이 필요한 경우 적합.

- **두 스택을 동시 사용** (이번 POC 구성) — `monitoring.coreos.com/v1` ServiceMonitor로 OpenShift Console 가시성을 확보하면서,
  동시에 `monitoring.rhobs/v1` ServiceMonitor로 COO Prometheus에도 수집.

```
[VM node_exporter]
      │
      ├─ Service (poc-monitoring-node-exporter)
      │       │
      │       ├─ ServiceMonitor (monitoring.coreos.com/v1)
      │       │       └─ OpenShift user-workload Prometheus
      │       │               └─ Console → Observe → Metrics
      │       │
      │       └─ ServiceMonitor (monitoring.rhobs/v1)
      │               └─ COO Prometheus (poc-monitoring-stack)
      │                       └─ Grafana / port-forward
```

---

## 사전 요구사항

- Cluster Observability Operator 설치 완료 (OperatorHub → "Cluster Observability Operator")
- OpenShift Virtualization 설치 완료 (`env.conf`에 `VIRT_INSTALLED=true`)
- poc Template 등록 완료 (`01-template/01-template.sh` 실행)
- `env.conf`에 `COO_INSTALLED=true` 설정

### Cluster Observability Operator 설치

OperatorHub(Red Hat operators)에서 COO를 설치합니다.

```bash
# 설치 확인
oc get csv --all-namespaces | grep cluster-observability-operator
# cluster-observability-operator.v0.x.x   Cluster Observability Operator   Succeeded
```

---

## 1. poc 템플릿에서 VM 생성

```bash
VM_NAME="poc-coo-vm"
NS="poc-monitoring"

# poc 템플릿에서 VM 생성
oc process -n openshift poc -p NAME="$VM_NAME" > ${VM_NAME}.yaml
oc apply -n "$NS" -f ${VM_NAME}.yaml

# monitor=metrics 레이블을 virt-launcher Pod에 전파
oc patch vm "$VM_NAME" -n "$NS" --type=merge -p '{
  "spec": {
    "template": {
      "metadata": {
        "labels": {
          "monitor": "metrics"
        }
      }
    }
  }
}'

# VM 시작
virtctl start "$VM_NAME" -n "$NS"

# 상태 확인
oc get vmi "$VM_NAME" -n "$NS"
```

VM이 Running 상태가 되면 VM 내부에 node_exporter를 설치합니다.

```bash
# VM 콘솔 접속
virtctl console "$VM_NAME" -n "$NS"

# VM 내부에 node_exporter 설치 (10-node-exporter/node-exporter-install.sh 참조)
```

---

## 2. node-exporter Service 생성

virt-launcher Pod (`monitor=metrics`)를 selector로 지정하여 VM 내부의 node_exporter(9100)에 접근합니다.
masquerade 네트워킹에서 Pod 포트는 VM 포트로 NAT됩니다.

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: poc-monitoring-node-exporter
  namespace: poc-monitoring
  labels:
    app: poc-monitoring-vm
    monitoring.rhobs/stack: poc-monitoring-stack
spec:
  ports:
    - name: metrics
      protocol: TCP
      port: 9100
      targetPort: 9100
  selector:
    monitor: metrics
  type: ClusterIP
EOF
```

Endpoints 확인:

```bash
oc get endpoints poc-monitoring-node-exporter -n poc-monitoring
```

---

## 3. MonitoringStack 배포

`resourceSelector` 레이블(`monitoring.rhobs/stack: poc-monitoring-stack`)을 가진 ServiceMonitor / PrometheusRule / PodMonitor를 자동 수집합니다.

```bash
oc apply -f - <<'EOF'
apiVersion: monitoring.rhobs/v1alpha1
kind: MonitoringStack
metadata:
  name: poc-monitoring-stack
  namespace: poc-monitoring
spec:
  logLevel: info
  retention: 24h
  resourceSelector:
    matchLabels:
      monitoring.rhobs/stack: poc-monitoring-stack
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  prometheusConfig:
    replicas: 1
  alertmanagerConfig:
    enabled: true
EOF
```

배포 확인:

```bash
oc get monitoringstack -n poc-monitoring
oc get pods -n poc-monitoring -l app.kubernetes.io/name=prometheus
oc get pods -n poc-monitoring -l app.kubernetes.io/name=alertmanager
```

---

## 4. ServiceMonitor 생성

### COO용 ServiceMonitor (`monitoring.rhobs/v1`)

`monitoring.rhobs/stack` 레이블을 통해 MonitoringStack의 Prometheus에 연결됩니다.

```bash
oc apply -f - <<'EOF'
apiVersion: monitoring.rhobs/v1
kind: ServiceMonitor
metadata:
  name: poc-vm-node-exporter
  namespace: poc-monitoring
  labels:
    monitoring.rhobs/stack: poc-monitoring-stack
spec:
  selector:
    matchLabels:
      app: poc-monitoring-vm
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
      relabelings:
        - targetLabel: job
          replacement: poc-monitoring-vm
        - sourceLabels: [__meta_kubernetes_endpoint_hostname]
          targetLabel: vmname
EOF
```

### OpenShift Console용 ServiceMonitor (`monitoring.coreos.com/v1`)

OpenShift Console의 **Observe → Metrics** 탭에서 메트릭을 조회하려면
`monitoring.coreos.com/v1` ServiceMonitor와 namespace 레이블이 필요합니다.

```bash
# namespace에 user-workload 모니터링 레이블 추가
oc label namespace poc-monitoring openshift.io/cluster-monitoring=true --overwrite

oc apply -f - <<'EOF'
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: poc-vm-node-exporter-console
  namespace: poc-monitoring
  labels:
    app: poc-monitoring-vm
spec:
  selector:
    matchLabels:
      app: poc-monitoring-vm
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
      relabelings:
        - targetLabel: job
          replacement: poc-monitoring-vm
        - sourceLabels: [__meta_kubernetes_endpoint_hostname]
          targetLabel: vmname
EOF
```

ServiceMonitor 목록 확인:

```bash
# COO용
oc get servicemonitor.monitoring.rhobs -n poc-monitoring

# OpenShift Console용
oc get servicemonitor.monitoring.coreos.com -n poc-monitoring
```

---

## 5. PrometheusRule (VM 알림 규칙)

```bash
oc apply -f - <<'EOF'
apiVersion: monitoring.rhobs/v1
kind: PrometheusRule
metadata:
  name: poc-vm-alerts
  namespace: poc-monitoring
  labels:
    monitoring.rhobs/stack: poc-monitoring-stack
spec:
  groups:
    - name: vm.rules
      interval: 30s
      rules:
        - alert: VMNotRunning
          expr: kubevirt_vmi_phase_count{phase!="Running"} > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "VM is not in Running state"
            description: "VM {{ $labels.name }} state: {{ $labels.phase }}"
        - alert: VMHighMemoryUsage
          expr: >
            (kubevirt_vmi_memory_resident_bytes /
             (kubevirt_vmi_memory_resident_bytes + kubevirt_vmi_memory_available_bytes)) > 0.9
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "VM memory usage exceeds 90%"
            description: "VM {{ $labels.name }} has high memory usage."
EOF
```

---

## 6. COO 메트릭 조회

COO MonitoringStack의 Prometheus는 클러스터 내부 서비스로 OpenShift Console에 직접 통합되지 않습니다.
대신 두 가지 경로로 메트릭을 조회합니다.

> **핵심 원리**
> - OpenShift Console은 `monitoring.coreos.com/v1` ServiceMonitor → **user-workload Prometheus** 경로만 표시
> - COO Prometheus (`monitoring.rhobs/v1`)는 Console 외부에서 Grafana 또는 port-forward로 접근
> - 이 POC는 동일한 Service에 두 종류의 ServiceMonitor를 모두 연결하여 **양쪽에서 동시 수집**

```
[poc-monitoring-node-exporter Service]
         │
         ├─ monitoring.coreos.com/v1 ServiceMonitor
         │        └─ user-workload Prometheus (OpenShift 내장)
         │                 └─ Console → Observe → Metrics ✔ (Project: poc-monitoring)
         │
         └─ monitoring.rhobs/v1 ServiceMonitor
                  └─ COO Prometheus (prometheus-operated)
                           ├─ Grafana → COO-Prometheus DataSource ✔
                           └─ port-forward → http://localhost:9090 ✔
```

---

### 방법 1 — OpenShift Console (Observe → Metrics)

COO Prometheus가 아닌 **user-workload Prometheus**를 통해 콘솔에서 동일한 메트릭을 조회합니다.

**조회 단계:**

1. OpenShift Console 접속
2. 상단 **Project** 드롭다운 → `poc-monitoring` 선택
3. 좌측 메뉴 → **Observe → Metrics**
4. PromQL 입력란에 쿼리를 입력하고 **Run queries** 클릭:

```promql
# VM 가용 메모리
node_memory_MemAvailable_bytes{job="poc-monitoring-vm"}

# VM CPU 사용률
rate(node_cpu_seconds_total{job="poc-monitoring-vm",mode!="idle"}[5m])

# VM 디스크 읽기 속도
rate(node_disk_read_bytes_total{job="poc-monitoring-vm"}[5m])
```

**알림 규칙 확인:**

- **Observe → Alerting** → `poc-monitoring` 프로젝트
- `VMNotRunning`, `VMHighMemoryUsage` 알림 상태 확인

**사전 조건 확인:**

```bash
# namespace 레이블 확인
oc get namespace poc-monitoring --show-labels | grep cluster-monitoring

# ServiceMonitor 등록 확인
oc get servicemonitor.monitoring.coreos.com poc-vm-node-exporter-console -n poc-monitoring

# Endpoints 활성 확인 (VM 내부에 node_exporter가 실행 중이어야 함)
oc get endpoints poc-monitoring-node-exporter -n poc-monitoring
```

> **메트릭이 보이지 않을 때**
> - Endpoints가 비어 있으면 VM 내부에 node_exporter가 실행되지 않은 것 → `10-node-exporter/node-exporter-install.sh` 실행
> - user-workload-monitoring이 비활성화된 경우:
>   ```bash
>   oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml | grep enableUserWorkload
>   # enableUserWorkload: true가 없으면 활성화 필요
>   ```

---

### 방법 2 — Grafana (COO Prometheus DataSource)

COO Prometheus에 직접 연결된 DataSource를 통해 Grafana에서 조회합니다.
`coo-prometheus-datasource`는 `11-coo.sh` 실행 시 자동 등록됩니다 (Grafana가 설치된 경우).

**DataSource 등록 확인:**

```bash
oc get grafanadatasource coo-prometheus-datasource -n poc-monitoring
```

**등록이 필요한 경우 수동 생성:**

```bash
oc apply -f - <<'EOF'
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: coo-prometheus-datasource
  namespace: poc-monitoring
spec:
  instanceSelector:
    matchLabels:
      dashboards: poc-grafana
  datasource:
    name: COO-Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus-operated.poc-monitoring.svc.cluster.local:9090
    isDefault: false
    jsonData:
      timeInterval: 5s
EOF
```

**Grafana 접속 및 조회 단계:**

```bash
# Grafana Route 확인
oc get route -n poc-monitoring -l app=grafana -o jsonpath='{.items[0].spec.host}'
```

1. `https://<grafana-route>` 접속 → `admin` / `grafana123` (또는 env.conf 값)
2. 좌측 메뉴 → **Explore**
3. 상단 DataSource 드롭다운 → **COO-Prometheus** 선택
4. **Metrics browser**에서 PromQL을 입력하거나 직접 입력:

```promql
# node_exporter 메트릭 (COO Prometheus 수집)
node_memory_MemAvailable_bytes{job="poc-monitoring-vm"}
rate(node_cpu_seconds_total{job="poc-monitoring-vm",mode!="idle"}[5m])
```

> **DataSource 연결 실패 시**
> COO Prometheus Pod가 아직 시작 중일 수 있습니다.
> ```bash
> oc get pods -n poc-monitoring -l app.kubernetes.io/name=prometheus
> # STATUS가 Running이어야 Grafana에서 정상 조회 가능
> ```

**참고 — Port-forward를 통한 COO Prometheus 직접 접근:**

```bash
oc port-forward svc/prometheus-operated 9090:9090 -n poc-monitoring
# 브라우저: http://localhost:9090
# Targets 탭 → poc-vm-node-exporter ServiceMonitor 스크래핑 대상 확인
# Alerts 탭 → VMNotRunning, VMHighMemoryUsage 알림 상태 확인
```

---

## 상태 확인

```bash
# MonitoringStack
oc get monitoringstack -n poc-monitoring

# 배포된 모든 Pod
oc get pods -n poc-monitoring

# ServiceMonitor (COO)
oc get servicemonitor.monitoring.rhobs -n poc-monitoring

# ServiceMonitor (console)
oc get servicemonitor.monitoring.coreos.com -n poc-monitoring

# PrometheusRule
oc get prometheusrule -n poc-monitoring

# VM 상태
oc get vmi poc-coo-vm -n poc-monitoring
```

---

## 롤백

```bash
./11-coo.sh --cleanup
# 또는 수동으로:
oc delete namespace poc-monitoring
oc delete clusterrolebinding grafana-cluster-monitoring-view
```
