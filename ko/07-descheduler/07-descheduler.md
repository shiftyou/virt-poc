# Descheduler 실습

KubeDescheduler가 노드 부하를 감지하여 VM을 자동으로 재배치하는 실습입니다.

```
단계 1: nodeSelector 없이 임의의 노드에 VM 3개 시작
┌──────────────────┐     ┌──────────────────────────────┐
│  NODE1           │     │  NODE2, ...                  │
│                  │     │                              │
│  (비어 있음)      │     │  ● vm-1   (배포됨)            │
│                  │     │  ● vm-2   (배포됨)            │
│                  │     │  ● vm-fixed (배포됨)          │
└──────────────────┘     └──────────────────────────────┘

단계 2: VM 3개를 모두 NODE1으로 Live Migrate (nodeSelector 일시 적용)
┌─────────────────────────────────┐     ┌──────────────┐
│  NODE1 (TEST_NODE)              │     │  NODE2, ...  │
│                                 │     │              │
│  ● vm-1        (250m CPU)       │     │  (가용)       │
│  ● vm-2        (250m CPU)       │     │              │
│  ● vm-fixed    (250m CPU) [evict=false] │     │      │
│                                 │     │              │
│  Migration 완료 → nodeSelector 제거     │             │
└─────────────────────────────────┘     └──────────────┘

단계 3: NODE1에 trigger VM 배포 → CPU 70% 초과
┌─────────────────────────────────┐     ┌──────────────┐
│  NODE1                          │     │  NODE2, ...  │
│                                 │     │              │
│  ● vm-1        (250m CPU)       │     │  (가용)       │
│  ● vm-2        (250m CPU)       │     │              │
│  ● vm-fixed    (250m CPU) [evict=false] │     │      │
│  ● vm-trigger  (계산된 CPU)      │     │              │
│                                 │     │              │
│  CPU 사용량 > 70%  ← 임계값 초과   │                  │
└─────────────────────────────────┘     └──────────────┘

단계 4: Descheduler 동작 (60초 이내)
┌─────────────────────────────────┐     ┌──────────────────────┐
│  NODE1                          │     │  NODE2, ...          │
│                                 │     │                      │
│  ● vm-fixed   (annotation 보호)  │     │  ● vm-1  (Migration) │
│  ● vm-trigger (최신 → 유지)      │     │  ● vm-2  (Migration) │
└─────────────────────────────────┘     └──────────────────────┘
```

---

## 사전 요구사항

- `01-template` 완료 -- poc Template 및 DataSource 등록됨
- Kube Descheduler Operator 설치 완료 (`operators/descheduler-operator.md` 참조)
- 2개 이상의 worker 노드 (VM 재배치를 위한 대상 노드 필요)
- `07-descheduler.sh` 실행 완료

---

## 구성 개요

| VM | 노드 고정 | CPU request | Descheduler 대상 | 사유 |
|----|-----------|-------------|-----------------|------|
| poc-descheduler-vm-1 | NODE1 | 250m | ✅ 대상 | annotation 없음 |
| poc-descheduler-vm-2 | NODE1 | 250m | ✅ 대상 | annotation 없음 |
| poc-descheduler-vm-fixed | NODE1 | 250m | ❌ 제외 | `descheduler.alpha.kubernetes.io/evict: "false"` |
| poc-descheduler-vm-trigger | NODE1 | 계산된 값 | ✅ 잠재적 대상 | 마지막에 배포됨 |

---

## KubeDescheduler 설정

```yaml
apiVersion: operator.openshift.io/v1
kind: KubeDescheduler
metadata:
  name: cluster
  namespace: openshift-kube-descheduler-operator
spec:
  managementState: Managed
  deschedulingIntervalSeconds: 60
  profiles:
    - LifecycleAndUtilization
  profileCustomizations:
    devLowNodeUtilizationThresholds: High
    namespaces:
      included:
        - poc-descheduler
```

### High 임계값 의미

| 구분 | CPU | Memory | Pods |
|------|-----|--------|------|
| **underutilized** (Migration 대상지) | < 40% | < 40% | < 40% |
| **overutilized** (Migration 원본) | > 70% | > 70% | > 70% |

NODE1의 CPU request 합계가 Allocatable의 **70%**를 초과하면 overutilized로 판단되어 vm-1, vm-2의 Live Migration이 발생합니다.

---

## Annotation -- vm-fixed 보호 원리

```yaml
# VM spec.template.metadata.annotations
descheduler.alpha.kubernetes.io/evict: "false"
```

위 annotation을 VM의 Pod template에 추가하면 해당 Pod가 Descheduler 퇴거 대상에서 제외됩니다.

```bash
# 07-descheduler.sh에서 적용되는 Patch
oc patch vm poc-descheduler-vm-fixed -n poc-descheduler --type=merge -p '{
  "spec": {
    "template": {
      "metadata": {
        "annotations": {
          "descheduler.alpha.kubernetes.io/evict": "false"
        }
      }
    }
  }
}'
```

`descheduler.alpha.kubernetes.io/evict: "false"` → Descheduler가 vm-fixed의 virt-launcher Pod를 퇴거 대상에서 제외 → NODE1에 유지

---

## 실습 검증

### 초기 상태 확인

```bash
# 모든 VM이 NODE1에 배치되었는지 확인
oc get vmi -n poc-descheduler -o wide

# NODE1 CPU request 현황
NODE1=$(oc get node -l node-role.kubernetes.io/worker \
  -o jsonpath='{.items[0].metadata.name}')

oc get pods --all-namespaces \
  --field-selector="spec.nodeName=${NODE1}" \
  -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.containers[0].resources.requests.cpu}{"\n"}{end}'

# 노드별 리소스 현황
oc describe node $NODE1 | grep -A 10 "Allocated resources"
```

### Descheduler 동작 확인 (60초 대기)

```bash
# VM 노드 변경 실시간 모니터링
oc get vmi -n poc-descheduler -o wide --watch

# Descheduler 이벤트 확인
oc get events -n poc-descheduler \
  --field-selector reason=Evicted \
  --sort-by='.lastTimestamp'

# Descheduler 로그 확인
oc logs -n openshift-kube-descheduler-operator \
  deployment/descheduler --tail=50
```

### 예상 결과 확인

```bash
# vm-1, vm-2가 다른 노드로 이동했는지 확인
oc get vmi -n poc-descheduler -o \
  custom-columns=NAME:.metadata.name,NODE:.status.nodeName,PHASE:.status.phase

# NAME                          NODE      PHASE
# poc-descheduler-vm-1          worker-1  Running   ← 이동됨
# poc-descheduler-vm-2          worker-2  Running   ← 이동됨
# poc-descheduler-vm-fixed      worker-0  Running   ← 유지됨 (PDB)
# poc-descheduler-vm-trigger    worker-0  Running   ← 유지됨

# PDB 상태 확인
oc get pdb -n poc-descheduler
```

### Migration 이력 확인

```bash
# VirtualMachineInstanceMigration 기록
oc get vmim -n poc-descheduler

# Migration 상세 정보
oc describe vmim -n poc-descheduler
```

---

## Descheduler 설정 확인 및 조정

```bash
# 현재 KubeDescheduler 설정 확인
oc get kubedescheduler cluster \
  -n openshift-kube-descheduler-operator -o yaml

# 주기 조정 (빠른 테스트를 위해: 30초)
oc patch kubedescheduler cluster \
  -n openshift-kube-descheduler-operator \
  --type=merge \
  -p '{"spec":{"deschedulingIntervalSeconds":30}}'

# Descheduler Pod 재시작
oc rollout restart deployment/descheduler \
  -n openshift-kube-descheduler-operator
```

---

## 문제 해결

```bash
# Descheduler가 동작하지 않을 때
oc logs -n openshift-kube-descheduler-operator \
  deployment/descheduler | grep -E "evict|migrate|error|LowNode"

# VM evictionStrategy 확인
oc get vm -n poc-descheduler -o \
  jsonpath='{range .items[*]}{.metadata.name}: {.spec.template.spec.evictionStrategy}{"\n"}{end}'
# → 모두 LiveMigrate여야 함

# PDB 상태 확인 (vm-fixed만 있어야 함)
oc get pdb -n poc-descheduler

# 노드 taint 확인 (Migration 실패 원인)
oc get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
```

---

## 롤백

```bash
# KubeDescheduler 설정 초기화 (namespace 제한 제거)
oc patch kubedescheduler cluster \
  -n openshift-kube-descheduler-operator \
  --type=merge \
  -p '{"spec":{"profileCustomizations":{"namespaces":null}}}'

# VM 및 namespace 삭제
oc delete namespace poc-descheduler
```

---

## DevKubeVirtRelieveAndMigrate Profile

`DevKubeVirtRelieveAndMigrate` profile을 사용하면, Descheduler가 PSI(Pressure Stall Information) 기반으로 노드 압력을 감지하여 VM을 자동으로 Migration합니다.
이 profile을 사용하려면 worker 노드에 커널 파라미터 `psi=1`이 활성화되어 있어야 합니다.

먼저 다음 MachineConfig를 적용합니다:

```bash
oc apply -f - <<'EOF'
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-openshift-machineconfig-worker-psi-karg
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  kernelArguments:
  - psi=1
EOF
```

> **참고**: MachineConfig가 적용되면 Machine Config Operator가 worker 노드를 순차적으로 재시작합니다 (drain → reboot → uncordon).
> 모든 worker 노드 재시작이 완료된 후 Descheduler를 설정하십시오 (`oc get mcp worker` 상태가 `UPDATED=True`로 표시되어야 합니다).

```bash
# MachineConfigPool 상태 확인 (UPDATED=True가 될 때까지 대기)
oc get mcp worker -w

# KubeDescheduler에 DevKubeVirtRelieveAndMigrate profile 적용
oc patch kubedescheduler cluster \
  -n openshift-kube-descheduler-operator \
  --type=merge \
  -p '{"spec":{"profiles":["DevKubeVirtRelieveAndMigrate"]}}'
```
