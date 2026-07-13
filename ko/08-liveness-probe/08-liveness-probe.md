# VM Liveness Probe 실습

VM에 KubeVirt의 Liveness / Readiness Probe를 설정하여
VM 내부 HTTP 서버 응답 기반의 자동 재시작 및 트래픽 차단을 실습합니다.

```
VM (poc-liveness-vm)
  │
  ├─ livenessProbe  — httpGet :80  → 실패 시 VM 자동 재시작
  └─ readinessProbe — httpGet :80  → 실패 시 Service 트래픽 차단
         │
         └─ virt-probe (KubeVirt 내부 에이전트)
              └─ VMI 내부 IP로 직접 HTTP 요청
```

---

## KubeVirt Probe 동작 방식

Kubernetes Pod Probe와 달리, KubeVirt VM Probe는 **virt-probe** 프로세스를 사용하여
VMI (VirtualMachineInstance) 내부 IP에 직접 연결합니다.

| 항목 | Pod Probe | KubeVirt VM Probe |
|------|-----------|-------------------|
| 실행 주체 | kubelet | virt-probe (KubeVirt) |
| 대상 | container port | VMI 내부 IP:port |
| 지원 유형 | HTTP / TCP / Exec | HTTP / TCP / Exec |
| Liveness 실패 시 | container 재시작 | VM 재시작 (VirtualMachine CR) |
| Readiness 실패 시 | Service endpoints에서 제외 | Service endpoints에서 제외 |

> **참고:** poc golden image에는 httpd (port 80)가 사전 설치되어 있습니다.
> Probe는 port 80을 대상으로 httpd 상태를 확인합니다.

---

## 사전 요구사항

- `01-template` 완료 -- poc Template 및 DataSource 등록됨
- `08-liveness-probe.sh` 실행 완료

```bash
oc get template poc -n openshift
oc get namespace poc-liveness-probe
```

---

## Probe 설정

```yaml
spec:
  template:
    spec:
      readinessProbe:
        httpGet:
          port: 80
        initialDelaySeconds: 120   # VM 부팅 대기
        periodSeconds: 20
        timeoutSeconds: 10
        failureThreshold: 3
        successThreshold: 3
      livenessProbe:
        httpGet:
          port: 80
        initialDelaySeconds: 120
        periodSeconds: 20
        timeoutSeconds: 10
        failureThreshold: 3        # 3회 연속 실패 → VM 재시작
```

### 파라미터 설명

| 파라미터 | 값 | 설명 |
|---------|-----|------|
| `initialDelaySeconds` | 120 | VM 부팅 후 첫 Probe까지 대기 시간 |
| `periodSeconds` | 20 | Probe 실행 주기 |
| `timeoutSeconds` | 10 | 응답 타임아웃 |
| `failureThreshold` | 3 | 연속 실패 횟수 초과 시 조치 수행 |
| `successThreshold` | 3 | (Readiness) 연속 성공 횟수 초과 시 Ready 상태로 전환 |

---

## 실습 단계

### 1. VM 시작 및 콘솔 접속

```bash
# VM 상태 확인
oc get vm,vmi -n poc-liveness-probe

# 콘솔 접속
virtctl console poc-liveness-vm -n poc-liveness-probe
```

### 2. VM 내부에서 HTTP 서버 실행

poc golden image에는 **httpd (port 80)**가 사전 설치되어 있습니다.
Probe가 port 80을 확인하므로 httpd가 실행 중이어야 합니다.

```bash
# VM 내부에서 httpd 실행 확인 (cloud-user로 로그인 후)
systemctl status httpd

# httpd가 실행 중이 아닌 경우 시작
sudo systemctl start httpd
```

서버 확인:
```bash
curl http://localhost:80
```

### 3. Probe 상태 확인

VM 외부 (OCP 노드)에서:

```bash
# VMI 조건 확인 (ReadyIsFalse / AgentConnected 등)
oc get vmi poc-liveness-vm -n poc-liveness-probe \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.status}{"\n"}{end}'

# Probe 설정 확인
oc get vmi poc-liveness-vm -n poc-liveness-probe \
  -o jsonpath='{.spec.livenessProbe}'

# 이벤트 확인
oc describe vmi poc-liveness-vm -n poc-liveness-probe | grep -A 5 Events
```

---

## Liveness Probe 실패 시뮬레이션

### HTTP 서버 중지 → VM 자동 재시작 확인

```bash
# 1. VM 콘솔에서 HTTP 서버 중지
virtctl console poc-liveness-vm -n poc-liveness-probe
# VM 내부에서:
kill $(pgrep -f "http.server")

# 2. 외부에서 VM 상태 모니터링 (failureThreshold * periodSeconds = 60초 후 재시작)
oc get vmi poc-liveness-vm -n poc-liveness-probe -w

# 3. VM 재시작 이벤트 확인
oc get events -n poc-liveness-probe \
  --sort-by='.lastTimestamp' | tail -10
```

예상 결과:
```
NAME               AGE   PHASE     IP           NODENAME
poc-liveness-vm    2m    Running   10.128.x.x   worker-0
poc-liveness-vm    3m    Failed    <none>        worker-0   ← Probe 실패
poc-liveness-vm    3m    Running   10.128.x.x   worker-0   ← 자동 재시작됨
```

---

## Readiness Probe 실패 시뮬레이션

```bash
# 1. HTTP 서버 중지 (위와 동일)

# 2. VMI Ready 상태 변경 확인
oc get vmi poc-liveness-vm -n poc-liveness-probe \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# → False (Readiness 실패 시 Service 트래픽 차단)

# 3. HTTP 서버 재시작 후 Ready 복구 확인
# VM 내부에서:
sudo systemctl start httpd
```

---

## TCP Probe 예제

HTTP 대신 TCP port 연결만 확인하는 방식:

```bash
oc patch vm poc-liveness-vm -n poc-liveness-probe --type=merge -p '{
  "spec": {
    "template": {
      "spec": {
        "livenessProbe": {
          "tcpSocket": {
            "port": 22
          },
          "initialDelaySeconds": 120,
          "periodSeconds": 20,
          "failureThreshold": 3
        }
      }
    }
  }
}'
```

> SSH (port 22)가 응답하는 동안 VM은 정상으로 간주됩니다.

---

## Exec Probe 예제

VM 내부에서 명령 실행 결과로 상태를 판단하는 방식:

```bash
oc patch vm poc-liveness-vm -n poc-liveness-probe --type=merge -p '{
  "spec": {
    "template": {
      "spec": {
        "livenessProbe": {
          "exec": {
            "command": ["cat", "/tmp/healthy"]
          },
          "initialDelaySeconds": 120,
          "periodSeconds": 20,
          "failureThreshold": 3
        }
      }
    }
  }
}'
```

VM 내부에서:
```bash
# 정상 상태 표시
touch /tmp/healthy

# 실패 시뮬레이션
rm /tmp/healthy
```

---

## Probe 제거

```bash
oc patch vm poc-liveness-vm -n poc-liveness-probe --type=merge -p '{
  "spec": {
    "template": {
      "spec": {
        "livenessProbe": null,
        "readinessProbe": null
      }
    }
  }
}'
```

---

## 롤백

```bash
# VM 중지 및 삭제
virtctl stop poc-liveness-vm -n poc-liveness-probe
oc delete vm poc-liveness-vm -n poc-liveness-probe

# namespace 삭제
oc delete namespace poc-liveness-probe
```

---

## 참고 자료

- [KubeVirt Liveness and Readiness Probes](https://kubevirt.io/user-guide/virtual_machines/liveness_and_readiness_probes/)
- [OpenShift Virtualization — VM Health Checks](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/virtualization/monitoring-vms#virt-about-readiness-liveness-probes_virt-monitoring-vm-health)
