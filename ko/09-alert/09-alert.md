# VM Alert 실습

OpenShift Monitoring (Prometheus)을 사용하여 VM 상태에 대한 alert 규칙을 구성합니다.

```
Prometheus (OpenShift Monitoring)
  └─ PrometheusRule (Alert 규칙)
       └─ kubevirt_vmi_phase_count 및 기타 VM 메트릭 모니터링
            └─ AlertManager → 알림 발송 (Email/Slack/PagerDuty)
```

---

## 사전 요구사항

- OpenShift Monitoring 활성화 (기본 포함)
- 사용자 정의 프로젝트 모니터링 활성화 (사용자 namespace에서 alert 사용 시)
- `09-alert.sh` 실행 완료

---

## VM 생성 (Alert 테스트용)

`09-alert.sh`를 실행하면 poc template에서 `poc-alert-vm`이 자동으로 생성됩니다.
생성된 VM을 사용하여 각 alert 조건을 직접 발생시키고 동작을 확인합니다.

```bash
# VM 상태 확인
oc get vm,vmi -n poc-alert

# VM 콘솔 접속
virtctl console poc-alert-vm -n poc-alert
```

---

## 사용자 정의 프로젝트 모니터링 활성화

사용자 namespace(예: poc-alert)에 PrometheusRule을 적용하려면 필요합니다.

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
```

---

## 주요 VM 메트릭

| 메트릭 | 설명 |
|--------|------|
| `kubevirt_vmi_phase_count` | phase별 VMI 수 — phase 값 (소문자): `pending` / `scheduling` / `scheduled` / `running` / `succeeded` |
| `kubevirt_vmi_vcpu_seconds_total` | vCPU 사용 시간 |
| `kubevirt_vmi_network_traffic_bytes_total` | VM 네트워크 트래픽 |
| `kubevirt_vmi_storage_iops_total` | VM 스토리지 IOPS |
| `kubevirt_vmi_memory_available_bytes` | VM 가용 메모리 |
| `kubevirt_vmi_migration_data_processed_bytes` | Migration 처리 데이터 |

---

## PrometheusRule 예시 — VM Alert

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: poc-vm-alerts
  namespace: poc-alert
  labels:
    role: alert-rules
    openshift.io/prometheus-rule-evaluation-scope: leaf-prometheus
spec:
  groups:
    - name: poc-vm-availability
      interval: 30s
      rules:

        # VM이 중지된 경우 (succeeded = 정상 종료)
        # kubevirt_vmi_phase_count label phase 값은 소문자: pending/scheduling/scheduled/running/succeeded
        # failed / unknown은 이 환경에서 메트릭에 나타나지 않으므로 succeeded로 감지
        - alert: VMStopped
          expr: |
            kubevirt_vmi_phase_count{phase="succeeded"} > 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "VM이 중지됨"
            description: "namespace {{ $labels.namespace }}에서 {{ $value }}개의 VM이 succeeded(중지) 상태로 감지되었습니다."

        # VM이 5분 이상 pending 상태에서 대기
        - alert: VMStuckPending
          expr: |
            kubevirt_vmi_phase_count{phase="pending"} > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "VM이 pending 상태에서 대기 중"
            description: "namespace {{ $labels.namespace }}에 {{ $value }}개의 VM이 pending 상태로 존재합니다."

        # VM이 10분 이상 scheduling/scheduled phase에서 멈춤
        - alert: VMStuckStarting
          expr: |
            kubevirt_vmi_phase_count{phase=~"scheduling|scheduled"} > 0
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "VM이 시작 중 멈춤"
            description: "namespace {{ $labels.namespace }}에서 VM이 {{ $labels.phase }} 상태로 10분 이상 지속되고 있습니다."

        # Live Migration 실패
        - alert: VMLiveMigrationFailed
          expr: |
            increase(kubevirt_vmi_migration_phase_transition_time_seconds_count{phase="Failed"}[10m]) > 0
          labels:
            severity: warning
          annotations:
            summary: "VM Live Migration 실패"
            description: "VM {{ $labels.vmi }}의 Live Migration이 실패했습니다."

    - name: poc-vm-resources
      interval: 60s
      rules:

        # VM 메모리 부족 (가용 메모리 100MiB 미만)
        - alert: VMLowMemory
          expr: |
            kubevirt_vmi_memory_available_bytes < 100 * 1024 * 1024
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "VM 메모리 부족"
            description: "VM {{ $labels.name }} (namespace: {{ $labels.namespace }})의 가용 메모리가 {{ $value | humanize }}입니다."
```

---

## Alert 트리거 방법

각 alert 조건을 실제로 발생시켜 동작을 확인합니다.

---

### 1. VMStopped — VM을 중지하여 Succeeded 상태로 트리거

> 실제 KubeVirt phase 값: `Pending` / `Scheduling` / `Scheduled` / `Running` / `Succeeded`
> `Failed` / `Unknown`은 메트릭에 나타나지 않으므로 **Succeeded (정상 종료)**로 중지 상태를 감지합니다.

`virtctl stop`으로 VM을 중지하면 VMI phase가 **Succeeded**로 전환됩니다.
`for: 2m` 조건이 충족되면 alert가 발생합니다.

```bash
# 1) VM 중지
virtctl stop poc-alert-vm -n poc-alert

# 2) VMI phase 확인 (Succeeded)
oc get vmi -n poc-alert

# 3) 2분 후: Console → Observe → Alerting에서 VMStopped 확인
```

**복구:**

```bash
virtctl start poc-alert-vm -n poc-alert
```

---

### 2. VMStuckPending — VM을 Pending 상태로 트리거

리소스(CPU/메모리) 요청을 클러스터 용량보다 크게 설정하면 VMI가 **Pending** 상태를 유지합니다.
`for: 5m` 조건이 충족되면 alert가 발생합니다.

```bash
# 1) 과도한 메모리 요청으로 패치 (예: 9999Gi)
oc patch vm poc-alert-vm -n poc-alert --type=merge -p \
  '{"spec":{"template":{"spec":{"domain":{"resources":{"requests":{"memory":"9999Gi"}}}}}}}'

# 2) VM 재시작 → VMI가 Pending 상태 유지
virtctl restart poc-alert-vm -n poc-alert

# 3) VMI 상태 확인 (Pending 확인)
oc get vmi -n poc-alert

# 4) 5분 후: Console → Observe → Alerting에서 VMStuckPending 확인
```

**복구:**

```bash
oc patch vm poc-alert-vm -n poc-alert --type=merge -p \
  '{"spec":{"template":{"spec":{"domain":{"resources":{"requests":{"memory":"2Gi"}}}}}}}'
virtctl start poc-alert-vm -n poc-alert
```

---

### 3. VMStuckStarting — VM을 Scheduling/Scheduled 상태에서 멈추도록 트리거

`nodeSelector`로 존재하지 않는 노드를 지정하면 VMI가 스케줄러에 의해 배치되지 못하고
**Scheduling** 또는 **Scheduled** 상태에서 멈추게 됩니다.
`for: 10m` 조건이 충족되면 alert가 발생합니다.

```bash
# 1) 존재하지 않는 노드를 지정하도록 패치
oc patch vm poc-alert-vm -n poc-alert --type=merge -p \
  '{"spec":{"template":{"spec":{"nodeSelector":{"kubernetes.io/hostname":"nonexistent-node"}}}}}'

# 2) VM 재시작
virtctl restart poc-alert-vm -n poc-alert

# 3) VMI phase 확인 (Scheduling 또는 Scheduled)
oc get vmi -n poc-alert

# 4) 10분 후: Console → Observe → Alerting에서 VMStuckStarting 확인
```

**복구:**

```bash
oc patch vm poc-alert-vm -n poc-alert --type=json \
  -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'
virtctl start poc-alert-vm -n poc-alert
```

---

### 5. VMLiveMigrationFailed — Live Migration 실패 트리거

사용 가능한 대상 노드가 없거나 리소스가 부족한 상태에서 Migration을 시도합니다.

```bash
# 1) VM이 Running 상태인지 확인
oc get vmi poc-alert-vm -n poc-alert

# 2) 모든 worker 노드에 taint 추가 (migration 대상 없음)
for node in $(oc get nodes -l node-role.kubernetes.io/worker -o name); do
  oc adm taint node "${node#node/}" migration-test=blocked:NoSchedule --overwrite
done

# 3) Live Migration 시작 → Failed로 전환
virtctl migrate poc-alert-vm -n poc-alert

# 4) Migration 상태 확인
oc get vmim -n poc-alert

# 5) 10분 이내: Console → Observe → Alerting에서 VMLiveMigrationFailed 확인
```

**복구:**

```bash
for node in $(oc get nodes -l node-role.kubernetes.io/worker -o name); do
  oc adm taint node "${node#node/}" migration-test=blocked:NoSchedule-
done
```

---

### 6. VMLowMemory — VM 메모리 부족 트리거

VM 내부에서 `stress` 도구를 사용하여 메모리를 소진합니다.
`kubevirt_vmi_memory_available_bytes < 100MiB`가 `for: 5m` 동안 지속되면 alert가 발생합니다.

```bash
# 1) VM 콘솔 접속
virtctl console poc-alert-vm -n poc-alert

# 2) VM 내부에서 stress 설치 및 실행 (RHEL/CentOS)
sudo dnf install -y stress-ng
# VM 할당 메모리 - 100MiB 이상 점유 (예: 1.8Gi VM의 경우 1700m)
stress-ng --vm 1 --vm-bytes 1700m --timeout 600s &

# 3) 가용 메모리 확인
free -m

# 4) 5분 후: Console → Observe → Alerting에서 VMLowMemory 확인
```

**복구 (VM 내부):**

```bash
# stress-ng 종료
kill %1
# 또는
killall stress-ng
```

---

## Alert 상태 확인 방법

Alert는 3단계로 전환됩니다: **Inactive → Pending → Firing**.

| 상태 | 의미 |
|------|------|
| Inactive | 조건 미충족 (정상) |
| Pending | 조건 충족, `for:` 기간 대기 중 |
| Firing | `for:` 조건을 통과하여 지속됨 → 실제 알림 발송 |

---

### 방법 1. OpenShift Console (가장 빠름)

```
OpenShift Console
  → Observe
    → Alerting
      → Alert Rules   ← PrometheusRule 등록 확인 (Inactive/Pending/Firing)
      → Alerts        ← 현재 Firing 중인 alert 목록
```

- **Alert Rules** 탭: `poc-vm-alerts` 규칙과 각 alert의 현재 상태 확인
- **Alerts** 탭: Firing 상태의 alert만 표시

> 사용자 정의 프로젝트 모니터링 활성화 후 Pod가 시작되기까지 1-2분 소요됩니다.
> Console에서 보이지 않으면 잠시 후 새로고침하세요.

---

### 방법 2. CLI — Prometheus API 직접 쿼리

User Workload Monitoring Prometheus에 직접 API 요청을 보내 alert 상태를 조회합니다.

```bash
# 현재 모든 alert 상태 조회 (Pending/Firing 포함)
oc exec -n openshift-user-workload-monitoring \
  prometheus-user-workload-0 -- \
  curl -s http://localhost:9090/api/v1/alerts \
  | python3 -m json.tool

# 특정 alert만 필터링
oc exec -n openshift-user-workload-monitoring \
  prometheus-user-workload-0 -- \
  curl -s http://localhost:9090/api/v1/alerts \
  | python3 -c "
import sys, json
data = json.load(sys.stdin)
for a in data['data']['alerts']:
    if 'VM' in a['labels'].get('alertname',''):
        print(a['labels']['alertname'], '->', a['state'])
        print('  labels:', a['labels'])
        print('  annotations:', a['annotations'])
"
```

출력 예시:
```
VMNotRunning -> firing
  labels: {'alertname': 'VMNotRunning', 'namespace': 'poc-alert', 'phase': 'Failed', 'severity': 'critical'}
  annotations: {'description': '1 VM(s) in Failed state detected in namespace poc-alert.', ...}
```

---

### 방법 3. CLI — PrometheusRule 로딩 확인

Prometheus가 실제로 PrometheusRule을 로딩했는지 확인합니다.

```bash
# rule이 로딩되었는지 확인 — 출력이 없으면 로딩 실패
oc exec -n openshift-user-workload-monitoring \
  prometheus-user-workload-0 -- \
  curl -s http://localhost:9090/api/v1/rules \
  | python3 -m json.tool | grep -A2 '"name": "VMNotRunning"'

# PrometheusRule 리소스 확인
oc get prometheusrule -n poc-alert
oc describe prometheusrule poc-vm-alerts -n poc-alert
```

#### Label, RBAC, namespace label 요구사항

| 항목 | 필수 여부 | 설명 |
|------|-----------|------|
| Namespace label | 불필요 | PrometheusRule은 namespace label 없이 자동 감지됨. `openshift.io/cluster-monitoring` label은 ServiceMonitor 전용 |
| PrometheusRule label | **조건부** | `prometheus-user-workload`의 `ruleSelector`가 특정 label을 요구하는 경우에만 필요 |
| `monitoring-edit` RBAC | 불필요 | cluster-admin으로 실행 시 해당 없음. 일반 사용자가 PrometheusRule을 직접 생성/수정할 때만 필요 |
| `monitoring-rules-edit` RBAC | 불필요 | 위와 동일 |

**가장 흔한 원인 — `ruleSelector` 불일치**

`prometheus-user-workload`에 `ruleSelector`가 설정된 경우, PrometheusRule이 해당 조건에 맞는 label을 가져야 로딩됩니다.

```bash
# ruleSelector / ruleNamespaceSelector 확인
oc get prometheus -n openshift-user-workload-monitoring user-workload \
  -o jsonpath='{.spec.ruleSelector}' && echo ""
oc get prometheus -n openshift-user-workload-monitoring user-workload \
  -o jsonpath='{.spec.ruleNamespaceSelector}' && echo ""
```

- 출력이 `{}` 또는 빈 값 → **모든 PrometheusRule 자동 감지** (label 불필요)
- `matchLabels`가 있는 경우 → PrometheusRule에 해당 label 필요

출력 예시:
```json
{"matchExpressions":[
  {"key":"openshift.io/user-monitoring","operator":"NotIn","values":["false"]},
  {"key":"openshift.io/prometheus-rule-evaluation-scope","operator":"In","values":["leaf-prometheus"]}
]}
```
→ PrometheusRule에 `openshift.io/prometheus-rule-evaluation-scope: leaf-prometheus` label이 **반드시** 있어야 함.
→ `openshift.io/user-monitoring` label은 없어도 조건 통과 (NotIn 조건)

**이미 배포된 PrometheusRule에 label 추가 (즉시 적용):**

```bash
oc label prometheusrule poc-vm-alerts -n poc-alert \
  openshift.io/prometheus-rule-evaluation-scope=leaf-prometheus

# 30초~1분 후 로딩 확인
oc exec -n openshift-user-workload-monitoring \
  prometheus-user-workload-0 -- \
  curl -s http://localhost:9090/api/v1/rules \
  | python3 -m json.tool | grep '"name"'
```

---

#### 출력이 없는 경우 — 단계별 진단

**Step 1: PrometheusRule 리소스 존재 확인**

```bash
oc get prometheusrule -n poc-alert
```

없는 경우 `09-alert.sh`를 다시 실행하거나 수동으로 적용합니다.

---

**Step 2: 모든 User Workload Monitoring Pod가 Running 상태인지 확인**

```bash
oc get pods -n openshift-user-workload-monitoring
```

`prometheus-user-workload-0`, `prometheus-operator-*` 등이 Running이어야 합니다.
Pod가 없으면 `enableUserWorkload: true` ConfigMap이 적용되지 않은 것입니다.

```bash
oc get configmap cluster-monitoring-config -n openshift-monitoring \
  -o jsonpath='{.data.config\.yaml}'
```

---

**Step 3: Prometheus 로그에서 rule 로딩 오류 확인**

```bash
oc logs -n openshift-user-workload-monitoring prometheus-user-workload-0 \
  -c prometheus --tail=50 | grep -i "rule\|error\|poc-alert"
```

`error loading rules` 또는 `parse error` 메시지가 있으면 PrometheusRule의 YAML 구문 오류입니다.

---

**Step 4: 전체 rule 목록 출력 및 그룹 이름으로 확인**

```bash
oc exec -n openshift-user-workload-monitoring \
  prometheus-user-workload-0 -- \
  curl -s http://localhost:9090/api/v1/rules \
  | python3 -m json.tool | grep '"name"'
```

`poc-vm-availability` 또는 `poc-vm-resources` 그룹이 나타나면 로딩된 것입니다.
그룹이 나타나지 않으면 Prometheus가 해당 namespace를 아직 스캔하지 않은 것입니다 —
**1-2분 후 재시도**하거나 Pod를 재시작합니다.

```bash
# Prometheus 재시작 (최후의 수단)
oc delete pod prometheus-user-workload-0 -n openshift-user-workload-monitoring
```

---

### 방법 4. CLI — AlertManager 수신 확인

AlertManager가 alert를 수신했는지 확인합니다 (Firing 단계에서만 전달됨).

```bash
# AlertManager Pod 확인
oc get pods -n openshift-monitoring | grep alertmanager

# AlertManager API를 통해 현재 활성 alert 조회
oc exec -n openshift-monitoring alertmanager-main-0 -- \
  curl -s http://localhost:9093/api/v2/alerts \
  | python3 -m json.tool | grep -A5 "alertname"
```

---

### 방법 5. Port-forward를 통한 Prometheus/AlertManager UI 직접 접근

```bash
# Prometheus UI (port forwarding)
oc port-forward -n openshift-user-workload-monitoring \
  prometheus-user-workload-0 9090:9090 &
# 브라우저: http://localhost:9090/alerts

# AlertManager UI (port forwarding)
oc port-forward -n openshift-monitoring \
  alertmanager-main-0 9093:9093 &
# 브라우저: http://localhost:9093
```

Prometheus UI → **Alerts** 메뉴에서 각 alert의 Pending/Firing 상태와 남은 `for:` 시간을 실시간으로 확인할 수 있습니다.

---

## AlertManager Receiver 설정 (Slack 예시)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-main
  namespace: openshift-monitoring
stringData:
  alertmanager.yaml: |
    global:
      slack_api_url: 'https://hooks.slack.com/services/YOUR/SLACK/WEBHOOK'
    route:
      receiver: slack-notifications
      group_by: ['alertname', 'namespace']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 1h
    receivers:
      - name: slack-notifications
        slack_configs:
          - channel: '#ocp-alerts'
            title: '[{{ .Status | toUpper }}] {{ .CommonAnnotations.summary }}'
            text: '{{ .CommonAnnotations.description }}'
            send_resolved: true
```

---

## 문제 해결

| 증상 | 확인 명령어 | 원인 |
|------|-------------|------|
| Console에 Alert Rules가 없음 | `oc get prometheusrule -n poc-alert` | PrometheusRule 미배포 |
| rules API에 그룹이 없음 | `oc get pods -n openshift-user-workload-monitoring` | User Workload Monitoring 미활성화 |
| 그룹은 있지만 alert 없음 | Prometheus 로그 확인 | PrometheusRule YAML 구문 오류 |
| Alert가 Pending에서 Firing으로 전환되지 않음 | `oc exec alertmanager-main-0 -- curl .../api/v2/alerts` | AlertManager 설정 오류 |

```bash
# 1. PrometheusRule 리소스 및 구문 확인
oc get prometheusrule -n poc-alert
oc describe prometheusrule poc-vm-alerts -n poc-alert

# 2. User Workload Monitoring Pod 상태 확인
oc get pods -n openshift-user-workload-monitoring

# 3. enableUserWorkload 설정 확인
oc get configmap cluster-monitoring-config -n openshift-monitoring \
  -o jsonpath='{.data.config\.yaml}'

# 4. Prometheus 로그에서 rule 로딩 오류 확인
oc logs -n openshift-user-workload-monitoring prometheus-user-workload-0 \
  -c prometheus --tail=50 | grep -i "rule\|error\|poc"

# 5. 로딩된 rule 그룹 전체 목록 확인
oc exec -n openshift-user-workload-monitoring prometheus-user-workload-0 -- \
  curl -s http://localhost:9090/api/v1/rules \
  | python3 -m json.tool | grep '"name"'

# 6. AlertManager 상태 확인
oc get pods -n openshift-monitoring | grep alertmanager
```

---

## 롤백

```bash
oc delete prometheusrule poc-vm-alerts -n poc-alert
oc delete namespace poc-alert
```
