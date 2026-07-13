# Node Maintenance 랩

이 랩에서는 Node Maintenance Operator를 사용하여 worker 노드를 안전하게 유지보수 모드로 전환하고,
VM이 Live Migration을 통해 다른 노드로 자동 마이그레이션되는 과정을 시연합니다.

```
Step 1: VM이 유지보수 대상 노드에서 실행 중
┌──────────────────────────────────┐     ┌──────────────┐
│  NODE1 (유지보수 대상)              │     │  NODE2       │
│                                  │     │              │
│  ● poc-maintenance-vm-1 (Running) │     │  (가용)       │
│  ● poc-maintenance-vm-2 (Running) │     │              │
└──────────────────────────────────┘     └──────────────┘

Step 2: NodeMaintenance 생성 → cordon + drain 시작
┌──────────────────────────────────┐     ┌──────────────────────────────────┐
│  NODE1 (SchedulingDisabled)      │     │  NODE2                           │
│                                  │     │                                  │
│  ● poc-maintenance-vm-1          │ ──▶ │  ● poc-maintenance-vm-1 (Migration) │
│  ● poc-maintenance-vm-2          │ ──▶ │  ● poc-maintenance-vm-2 (Migration) │
└──────────────────────────────────┘     └──────────────────────────────────┘

Step 3: 유지보수 완료 → NodeMaintenance 삭제 → uncordon
┌──────────────────────────────────┐     ┌──────────────────────────────────┐
│  NODE1 (Ready)                   │     │  NODE2                           │
│                                  │     │                                  │
│  (비어 있음)                       │     │  ● poc-maintenance-vm-1 (Running) │
│                                  │     │  ● poc-maintenance-vm-2 (Running) │
└──────────────────────────────────┘     └──────────────────────────────────┘
```

---

## 사전 요구사항

- `01-template` 완료 — `poc` Template 및 DataSource 등록
- Node Maintenance Operator 설치 완료 (`operators/node-maintenance-operator.md` 참조)
- 2개 이상의 worker 노드
- `15-node-maintenance.sh` 실행 완료

---

## 구성 개요

| VM | evictionStrategy | 설명 |
|----|-----------------|------|
| poc-maintenance-vm-1 | LiveMigrate | 유지보수 시 자동 Migration 대상 |
| poc-maintenance-vm-2 | LiveMigrate | 유지보수 시 자동 Migration 대상 |

---

## NodeMaintenance 동작 원리

```yaml
apiVersion: nodemaintenance.medik8s.io/v1beta1
kind: NodeMaintenance
metadata:
  name: maintenance-<node-name>
spec:
  nodeName: <node-name>
  reason: "Hardware inspection"
```

NodeMaintenance 오브젝트가 생성되면:

1. **Cordon** — 노드를 `SchedulingDisabled` 상태로 변경 (새로운 Pod 스케줄링 차단)
2. **Drain** — 노드에서 Pod를 순서대로 퇴거
3. **VM Live Migration** — `evictionStrategy: LiveMigrate`가 설정된 VM은 자동으로 다른 노드로 마이그레이션

---

## 랩 절차

### 1. VM 배치 확인

```bash
# 유지보수 대상 노드 확인
TEST_NODE=$(oc get node -l node-role.kubernetes.io/worker \
  -o jsonpath='{.items[0].metadata.name}')
echo "대상 노드: ${TEST_NODE}"

# VM 배치 확인
oc get vmi -n poc-maintenance -o wide
```

### 2. NodeMaintenance 시작

```bash
TEST_NODE=$(oc get node -l node-role.kubernetes.io/worker \
  -o jsonpath='{.items[0].metadata.name}')

cat <<EOF | oc apply -f -
apiVersion: nodemaintenance.medik8s.io/v1beta1
kind: NodeMaintenance
metadata:
  name: maintenance-${TEST_NODE}
spec:
  nodeName: ${TEST_NODE}
  reason: "POC maintenance lab"
EOF
```

### 3. 유지보수 진행 확인

```bash
# NodeMaintenance 상태 확인
oc get nodemaintenance
oc describe nodemaintenance maintenance-${TEST_NODE}

# 노드 상태 확인 (SchedulingDisabled)
oc get node ${TEST_NODE}

# VM Migration 진행 상황 실시간 모니터링
oc get vmi -n poc-maintenance -o wide --watch
```

### 4. Migration 완료 확인

```bash
# VM이 다른 노드로 이동했는지 확인
oc get vmi -n poc-maintenance \
  -o custom-columns=NAME:.metadata.name,NODE:.status.nodeName,PHASE:.status.phase

# Migration 이력 확인
oc get vmim -n poc-maintenance
```

### 5. 유지보수 종료 (uncordon)

```bash
# NodeMaintenance 삭제 → 노드 복구
oc delete nodemaintenance maintenance-${TEST_NODE}

# 노드 Ready 상태 확인
oc get node ${TEST_NODE}
```

---

## 상태 확인 명령어

```bash
# NodeMaintenance 전체 목록
oc get nodemaintenance

# 노드 상태 (Cordon 상태)
oc get nodes

# VM Migration 기록
oc get vmim -n poc-maintenance

# Migration 상세 정보
oc describe vmim -n poc-maintenance

# 이벤트 확인
oc get events -n poc-maintenance \
  --sort-by='.lastTimestamp' | tail -20
```

---

## 문제 해결

```bash
# VM이 마이그레이션되지 않을 때 — evictionStrategy 확인
oc get vm -n poc-maintenance \
  -o jsonpath='{range .items[*]}{.metadata.name}: {.spec.template.spec.evictionStrategy}{"\n"}{end}'
# → 모두 LiveMigrate여야 함

# drain이 멈출 때 — PodDisruptionBudget 확인
oc get pdb -A

# Node Maintenance Operator 로그
oc logs -n openshift-operators \
  deployment/node-maintenance-operator -f

# 강제 uncordon (긴급 복구)
oc adm uncordon ${TEST_NODE}
```

---

## 롤백

```bash
# NodeMaintenance 삭제 (유지보수 종료)
oc delete nodemaintenance --all

# VM 및 namespace 삭제
oc delete namespace poc-maintenance
```
