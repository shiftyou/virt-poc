# Fence Agents Remediation (FAR) 랩

이 랩에서는 Node Health Check Operator가 비정상 노드를 감지하고,
FAR이 IPMI/BMC를 통해 노드를 강제 재시작(fencing)하여 자동으로 복구하는 과정을 시연합니다.

```
NHC (감지) → FenceAgentsRemediationTemplate (IPMI fencing)

Step 1: 정상 상태
┌───────────────────────────┐     ┌──────────────┐
│  NODE1 (Ready)            │     │  NODE2       │
│  ● poc-far-vm-1 (Running) │     │  (가용)       │
│  ● poc-far-vm-2 (Running) │     │              │
└───────────────────────────┘     └──────────────┘

Step 2: NODE1 장애 시뮬레이션 (kubelet 중지)
┌───────────────────────────┐     ┌──────────────┐
│  NODE1 (NotReady)         │     │  NODE2       │
│  ✗ kubelet 중지            │     │  (가용)       │
└───────────────────────────┘     └──────────────┘
         │
         ▼  NHC 감지 (unhealthy 조건 충족)
         ▼  FenceAgentsRemediation 생성
         ▼  IPMI/BMC → 물리 노드 전원 재시작

Step 3: 복구 완료
┌───────────────────────────┐     ┌──────────────┐
│  NODE1 (Ready, 재부팅 후)    │     │  NODE2       │
│  ● poc-far-vm-1 (Running) │     │  (가용)       │
│  ● poc-far-vm-2 (Running) │     │              │
└───────────────────────────┘     └──────────────┘
```

---

## 사전 요구사항

- `01-template` 완료 — `poc` Template 및 DataSource 등록
- Fence Agents Remediation Operator 설치 완료 (`operators/far-operator.md` 참조)
- Node Health Check Operator 설치 완료 (`operators/nhc-operator.md` 참조)
- worker 노드에서 IPMI/BMC 접근 가능
- `env.conf`에 `FENCE_AGENT_IP`, `FENCE_AGENT_USER`, `FENCE_AGENT_PASS` 설정
- `17-far.sh` 실행 완료

---

## 구성 개요

| 리소스 | Namespace | 역할 |
|--------|------------|------|
| Secret `poc-far-credentials` | `openshift-workload-availability` | IPMI `--password` 보안 저장 |
| FenceAgentsRemediationTemplate | `openshift-workload-availability` | IPMI fencing 방법 정의 |
| NodeHealthCheck | cluster 범위 | 노드 상태 감지 + FAR 트리거 조건 |

---

## FAR vs SNR 비교

| 항목 | FAR | SNR |
|------|-----|-----|
| 복구 방법 | IPMI/BMC 전원 제어 | 노드 자체 재시작 |
| 외부 하드웨어 필요 | 필요 (BMC) | 불필요 |
| 복구 신뢰성 | 높음 (하드웨어 레벨) | 중간 (OS 레벨) |
| 적용 환경 | 베어메탈 | 베어메탈 / 가상 |

---

## IPMI 자격 증명 Secret

비밀번호는 Secret으로 별도 관리합니다. IPMI 비밀번호는 `--password` 키에 저장됩니다.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: poc-far-credentials
  namespace: openshift-workload-availability
stringData:
  --password: "<FENCE_AGENT_PASS>"
```

```bash
oc create secret generic poc-far-credentials \
  -n openshift-workload-availability \
  --from-literal=--password=<FENCE_AGENT_PASS>
```

---

## FenceAgentsRemediationTemplate

```yaml
apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
kind: FenceAgentsRemediationTemplate
metadata:
  annotations:
    remediation.medik8s.io/multiple-templates-support: "true"
  name: poc-far-template
  namespace: openshift-workload-availability
spec:
  template:
    spec:
      agent: fence_ipmilan
      nodeparameters:
        --ip:
          <worker-node-fqdn-1>: <bmc-ip-1>
          <worker-node-fqdn-2>: <bmc-ip-2>
          <worker-node-fqdn-3>: <bmc-ip-3>
      remediationStrategy: ResourceDeletion
      retrycount: 5
      retryinterval: 5s
      sharedSecretName: poc-far-credentials
      sharedparameters:
        --action: reboot
        --lanplus: ""
        --username: <FENCE_AGENT_USER>
      timeout: 1m0s
```

- `nodeparameters[--ip]`: 노드 FQDN → BMC IP 매핑 (노드별 BMC IP 지정)
- `sharedSecretName`: `--password`를 포함하는 Secret 이름
- `sharedparameters`: 모든 노드에 공통 적용되는 파라미터 (비밀번호 제외)
- `agent`: IPMI 환경에 따라 `fence_ipmilan`, `fence_idrac`, `fence_ilo` 등 선택

---

## NodeHealthCheck 설정

```yaml
apiVersion: remediation.medik8s.io/v1alpha1
kind: NodeHealthCheck
metadata:
  name: poc-far-nhc
spec:
  remediationTemplate:
    apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
    kind: FenceAgentsRemediationTemplate
    name: poc-far-template
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
oc get nodehealthcheck poc-far-nhc

# FAR Template 확인
oc get fenceagentsremediationtemplate -n openshift-workload-availability

# VM 배치 확인
oc get vmi -n poc-far -o wide

# IPMI 연결 테스트
ipmitool -I lanplus -H ${FENCE_AGENT_IP} \
  -U ${FENCE_AGENT_USER} -P ${FENCE_AGENT_PASS} chassis power status
```

### 노드 장애 시뮬레이션

```bash
# TEST_NODE에서 kubelet 중지 (노드에서 직접 실행)
oc debug node/${TEST_NODE} -- chroot /host systemctl stop kubelet

# 노드 상태 확인 (NotReady로 변경 확인)
oc get nodes -w
```

### NHC → FAR 트리거 확인

```bash
# NHC 상태 확인 (unhealthy 감지 여부)
oc get nodehealthcheck poc-far-nhc -o yaml | grep -A 20 status

# FenceAgentsRemediation CR 생성 확인 (NHC가 자동 생성)
oc get fenceagentsremediation -A

# FAR 이벤트 확인
oc get events -n openshift-workload-availability \
  --sort-by='.lastTimestamp' | grep -i remediat

# IPMI fencing 실행 확인
oc logs -n openshift-workload-availability \
  deployment/fence-agents-remediation-operator-controller-manager --tail=50
```

### 복구 후 확인

```bash
# 노드 복구 확인 (Ready 복귀)
oc get nodes

# VM 상태 확인 (재시작 후 Running 복귀)
oc get vmi -n poc-far -o wide

# FenceAgentsRemediation CR 자동 삭제 확인
oc get fenceagentsremediation -A
```

---

## 문제 해결

```bash
# FAR Operator 로그
oc logs -n openshift-workload-availability \
  deployment/fence-agents-remediation-operator-controller-manager --tail=50

# NHC Controller 로그
oc logs -n openshift-workload-availability \
  deployment/node-healthcheck-operator-controller-manager --tail=50

# FAR CR 상세 정보
oc describe fenceagentsremediation -A

# 직접 IPMI 테스트
ipmitool -I lanplus -H ${FENCE_AGENT_IP} \
  -U ${FENCE_AGENT_USER} -P ${FENCE_AGENT_PASS} chassis power status

# 노드 재부팅 이력 확인
oc debug node/${TEST_NODE} -- chroot /host last reboot | head -5
```

---

## 롤백

```bash
# NodeHealthCheck 삭제
oc delete nodehealthcheck poc-far-nhc

# FenceAgentsRemediationTemplate 삭제
oc delete fenceagentsremediationtemplate poc-far-template \
  -n openshift-workload-availability

# VM 및 namespace 삭제
oc delete namespace poc-far
```
