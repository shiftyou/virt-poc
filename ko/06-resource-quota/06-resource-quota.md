# ApplicationAwareResourceQuota 실습

표준 Kubernetes `ResourceQuota`는 Pod 수준의 리소스를 계산하므로 VM 리소스를 직접 제한할 수 없습니다.
OpenShift Virtualization의 `ApplicationAwareResourceQuota`(AARQ)를 사용하면 VM 리소스를 정확하게 계산합니다.

`poc-resource-quota` namespace에 AARQ를 적용하여
VM 2개는 통과하고, 3번째 VM은 CPU 할당량 초과로 거부되는 것을 검증합니다.

```
초기 상태 (Quota 범위 내)
┌────────────────────────────────────────────────┐
│  poc-resource-quota                            │
│                                                │
│  ● poc-quota-vm-1  (cpu request: 750m) ✅      │
│  ● poc-quota-vm-2  (cpu request: 750m) ✅      │
│                                                │
│  requests.cpu used: 1500m / 2000m              │
└────────────────────────────────────────────────┘

3번째 VM 생성 시도 → Quota 초과
┌────────────────────────────────────────────────┐
│  poc-resource-quota                            │
│                                                │
│  ● poc-quota-vm-1  (750m) ✅                   │
│  ● poc-quota-vm-2  (750m) ✅                   │
│  ✗ poc-quota-vm-3  (750m) → 2250m > 2000m     │
│                             virt-launcher 거부  │
└────────────────────────────────────────────────┘
```

---

## 사전 요구사항

- cluster-admin 또는 namespace admin 권한
- `01-template` 완료 — poc Template 등록 완료
- `06-resource-quota.sh` 실행 완료

---

## 왜 ApplicationAwareResourceQuota인가?

| | 표준 ResourceQuota | ApplicationAwareResourceQuota |
|---|---|---|
| 리소스 계산 | Pod 수준 | VM 인식 (virt-launcher) |
| VM 쿼터 적용 | 간접적 (차단 안 될 수 있음) | 직접 적용 |
| 필요 조건 | 없음 | HyperConverged CR에 `enableApplicationAwareQuota: true` |
| API | `v1 / ResourceQuota` | `aaq.kubevirt.io/v1alpha1 / ApplicationAwareResourceQuota` |

---

## ApplicationAwareQuota 활성화

```bash
# HyperConverged CR에서 활성화 (1회, 클러스터 전체 적용)
oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  --type=merge \
  -p '{"spec":{"featureGates":{"enableApplicationAwareQuota":true}}}'

# AAQ 컨트롤러 실행 확인
oc get deployment -n openshift-cnv -l app=aaq-controller

# CRD 사용 가능 확인
oc get crd applicationawareresourcequotas.aaq.kubevirt.io
```

---

## 적용된 ApplicationAwareResourceQuota

| 항목 | requests | limits |
|------|----------|--------|
| CPU | **2000m** | 5 |
| Memory | 4 Gi | 8 Gi |

> `requests.cpu: "2000m"` 기준 — VM당 750m일 때 → VM 2개 (1500m) 통과, VM 3개 (2250m) 초과

---

## 실습 검증

### 초기 상태 확인

```bash
# AARQ 상태
oc get aarq poc-quota -n poc-resource-quota -o yaml

# status 섹션 예시
# status:
#   hard:
#     limits.cpu: "5"
#     limits.memory: 8Gi
#     requests.cpu: 2000m
#     requests.memory: 4Gi
#   used:
#     limits.cpu: "3"
#     limits.memory: 4Gi
#     requests.cpu: 1500m        ← VM 2개 이후 1500m 사용
#     requests.memory: 2Gi
```

### VM 상태 확인

```bash
# VM 목록
oc get vm -n poc-resource-quota

# NAME             AGE   STATUS    READY
# poc-quota-vm-1   ...   Running   True
# poc-quota-vm-2   ...   Running   True
# poc-quota-vm-3   ...   Stopped   False   ← virt-launcher Pod 시작 불가

# virt-launcher Pod 상태
oc get pod -n poc-resource-quota -l kubevirt.io=virt-launcher
```

### Quota 초과 이벤트 확인

```bash
# Quota 초과 이벤트
oc get events -n poc-resource-quota --field-selector reason=FailedCreate \
  --sort-by='.lastTimestamp'

# 출력 예시
# ...  FailedCreate  ...  pods "virt-launcher-poc-quota-vm-3-..."
#      is forbidden: exceeded quota: poc-quota,
#      requested: requests.cpu=750m, used: requests.cpu=1500m,
#      limited: requests.cpu=2000m
```

### virt-launcher Pod 리소스 확인

```bash
# 실행 중인 VM의 실제 CPU/Memory 사용량
oc get pod -n poc-resource-quota -l kubevirt.io=virt-launcher \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.containers[*]}  {.name}: cpu={.resources.requests.cpu} mem={.resources.requests.memory}{"\n"}{end}{end}'
```

---

## AARQ 초과 테스트 (추가)

```bash
# Quota 여유분 확인
oc get aarq poc-quota -n poc-resource-quota -o yaml

# vm-3를 시작할 수 있도록 Quota 제한 증가
oc patch aarq poc-quota -n poc-resource-quota \
  --type=merge \
  -p '{"spec":{"hard":{"requests.cpu":"4","limits.cpu":"8"}}}'

# vm-3 재시작
virtctl start poc-quota-vm-3 -n poc-resource-quota

# 초과 상태를 복원하기 위해 Quota 다시 낮추기
oc patch aarq poc-quota -n poc-resource-quota \
  --type=merge \
  -p '{"spec":{"hard":{"requests.cpu":"2000m","limits.cpu":"5"}}}'
```

---

## ApplicationAwareClusterResourceQuota

여러 namespace에 걸쳐 클러스터 전체 VM 쿼터를 적용하려면 `ApplicationAwareClusterResourceQuota`를 사용합니다:

```bash
oc apply -f - <<'EOF'
apiVersion: aaq.kubevirt.io/v1alpha1
kind: ApplicationAwareClusterResourceQuota
metadata:
  name: cluster-vm-quota
spec:
  quota:
    hard:
      requests.cpu: "16"
      requests.memory: 32Gi
  selector:
    labels:
      matchLabels:
        vm-quota: "enabled"
EOF
```

---

## 롤백

```bash
# namespace 삭제 (VM, AARQ 포함)
oc delete namespace poc-resource-quota
```
