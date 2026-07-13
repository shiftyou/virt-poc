# Self Node Remediation (SNR) 랩

이 랩에서는 Node Health Check Operator가 비정상 노드를 감지하고,
Self Node Remediation이 노드 자체를 재시작하여 자동으로 복구하는 과정을 시연합니다.

```
NHC (감지) → SelfNodeRemediationTemplate (복구 실행)

Step 1: 정상 상태
┌───────────────────────────┐     ┌──────────────┐
│  NODE1 (Ready)            │     │  NODE2       │
│  ● poc-snr-vm-1 (Running) │     │  (가용)       │
│  ● poc-snr-vm-2 (Running) │     │              │
└───────────────────────────┘     └──────────────┘

Step 2: NODE1 장애 시뮬레이션 (kubelet 중지)
┌───────────────────────────┐     ┌──────────────┐
│  NODE1 (NotReady)         │     │  NODE2       │
│  ✗ kubelet 중지            │     │  (가용)       │
└───────────────────────────┘     └──────────────┘
         │
         ▼  NHC 감지 (unhealthy 조건 충족)
         ▼  SelfNodeRemediation 생성
         ▼  NODE1 자체 재시작 (watchdog / reboot)

Step 3: 복구 완료
┌───────────────────────────┐     ┌──────────────┐
│  NODE1 (Ready, 재시작 후)    │     │  NODE2       │
│  ● poc-snr-vm-1 (Running) │     │  (가용)       │
│  ● poc-snr-vm-2 (Running) │     │              │
└───────────────────────────┘     └──────────────┘
```

---

## 사전 요구사항

- `01-template` 완료 — `poc` Template 및 DataSource 등록
- Self Node Remediation Operator 설치 완료 (`operators/snr-operator.md` 참조)
- Node Health Check Operator 설치 완료 (`operators/nhc-operator.md` 참조)
- 2개 이상의 worker 노드
- `16-snr.sh` 실행 완료

---

## 구성 개요

| 리소스 | 역할 |
|--------|------|
| SelfNodeRemediationTemplate | SNR 복구 방법 정의 |
| NodeHealthCheck | 노드 상태 감지 + SNR 트리거 조건 |
| poc-snr-vm-1, vm-2 | 복구 대상 VM (NODE1에 배치) |

---

## SNR 동작 원리

```
NHC가 노드를 모니터링
  └─ 조건 충족 (예: Ready=False 300초 이상)
       └─ SelfNodeRemediation CR 생성
            └─ SNR DaemonSet (해당 노드의 Pod)이 감지
                 └─ 노드 자체 재시작 (watchdog 또는 reboot)
                      └─ 재시작 후 Ready 복귀
```

SNR은 **외부 IPMI 없이** 동작합니다. 노드의 watchdog 디바이스 또는 직접 reboot을 사용하여 자체 복구합니다.

---

## SelfNodeRemediationTemplate

```yaml
apiVersion: self-node-remediation.medik8s.io/v1alpha1
kind: SelfNodeRemediationTemplate
metadata:
  name: poc-snr-template
  namespace: openshift-workload-availability
spec:
  template:
    spec:
      remediationStrategy: ResourceDeletion
```

`remediationStrategy`:
- `ResourceDeletion`: 노드의 Pod/VolumeAttachment를 강제 삭제 후 재시작 (기본값)
- `OutOfServiceTaint`: `node.kubernetes.io/out-of-service` taint 추가 → 강제 삭제

---

## NodeHealthCheck 설정

```yaml
apiVersion: remediation.medik8s.io/v1alpha1
kind: NodeHealthCheck
metadata:
  name: poc-snr-nhc
spec:
  remediationTemplate:
    apiVersion: self-node-remediation.medik8s.io/v1alpha1
    kind: SelfNodeRemediationTemplate
    name: poc-snr-template
    namespace: openshift-workload-availability
  selector:
    matchExpressions:
      - key: node-role.kubernetes.io/worker
        operator: Exists
  unhealthyConditions:
    - type: Ready
      status: "False"
      duration: 300s
    - type: Ready
      status: Unknown
      duration: 300s
```

---

## 랩 검증

### 초기 상태 확인

```bash
# NHC 상태 확인
oc get nodehealthcheck poc-snr-nhc

# SNR Template 확인
oc get selfnoderemediationtemplate -n openshift-workload-availability

# VM 배치 확인
oc get vmi -n poc-snr -o wide
```

### 노드 장애 시뮬레이션

```bash
# TEST_NODE에서 kubelet 중지 (노드에서 직접 실행)
oc debug node/${TEST_NODE} -- chroot /host systemctl stop kubelet

# 노드 상태 확인 (NotReady로 변경 확인)
oc get nodes -w
```

### NHC → SNR 트리거 확인

```bash
# NHC 상태 확인 (unhealthy 감지 여부)
oc get nodehealthcheck poc-snr-nhc -o yaml | grep -A 20 status

# SelfNodeRemediation CR 생성 확인 (NHC가 자동 생성)
oc get selfnoderemediation -A

# SNR 이벤트 확인
oc get events -n openshift-workload-availability \
  --sort-by='.lastTimestamp' | grep -i remediat

# NHC 이벤트 확인
oc describe nodehealthcheck poc-snr-nhc | grep -A 20 "Events:"
```

### 복구 후 확인

```bash
# 노드 복구 확인 (Ready 복귀)
oc get nodes

# VM 상태 확인 (재시작 후 Running 복귀)
oc get vmi -n poc-snr -o wide

# SelfNodeRemediation CR 자동 삭제 확인
oc get selfnoderemediation -A
```

---

## 문제 해결

```bash
# NHC Controller 로그
oc logs -n openshift-workload-availability \
  deployment/node-healthcheck-operator-controller-manager --tail=50

# SNR DaemonSet Pod 로그 (해당 노드)
oc logs -n openshift-workload-availability \
  -l app.kubernetes.io/name=self-node-remediation \
  --tail=50

# SNR 상세 정보
oc describe selfnoderemediation -A

# 노드 재시작 이력 확인
oc debug node/${TEST_NODE} -- chroot /host last reboot | head -5
```

---

## 롤백

```bash
# NodeHealthCheck 삭제
oc delete nodehealthcheck poc-snr-nhc

# SelfNodeRemediationTemplate 삭제
oc delete selfnoderemediationtemplate poc-snr-template \
  -n openshift-workload-availability

# VM 및 namespace 삭제
oc delete namespace poc-snr
```
