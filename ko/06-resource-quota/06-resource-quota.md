# ResourceQuota 실습

`poc-resource-quota` namespace에 ResourceQuota를 적용하여
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

## 적용된 ResourceQuota

| 항목 | requests | limits |
|------|----------|--------|
| CPU | **2 core** | 4 core |
| Memory | 4 Gi | 8 Gi |
| Pod 수 | — | 10 |
| PVC 수 | — | 10 |
| Storage | 100 Gi | — |
| Service | — | 10 |
| LoadBalancer | — | 2 |
| NodePort | — | 0 |
| ConfigMap | — | 20 |
| Secret | — | 20 |

> `requests.cpu: "2"` (2000m) 기준 — VM당 750m일 때 → VM 2개 (1500m) 통과, VM 3개 (2250m) 초과

---

## 실습 검증

### 초기 상태 확인

```bash
# ResourceQuota 상태
oc describe resourcequota poc-quota -n poc-resource-quota

# 출력 예시
# Resource                  Used    Hard
# --------                  ----    ----
# limits.cpu                3000m   4
# limits.memory             4Gi     8Gi
# requests.cpu              1500m   2       ← VM 2개 이후 1500m 사용
# requests.memory           2Gi     4Gi
# pods                      2       10
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
#      limited: requests.cpu=2
```

### virt-launcher Pod 리소스 확인

```bash
# 실행 중인 VM의 실제 CPU/Memory 사용량
oc get pod -n poc-resource-quota -l kubevirt.io=virt-launcher \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.containers[*]}  {.name}: cpu={.resources.requests.cpu} mem={.resources.requests.memory}{"\n"}{end}{end}'
```

---

## ResourceQuota 초과 테스트 (추가)

```bash
# Quota 여유분 확인
oc describe resourcequota poc-quota -n poc-resource-quota

# vm-3를 시작할 수 있도록 Quota 제한 증가
oc patch resourcequota poc-quota -n poc-resource-quota \
  --type=merge \
  -p '{"spec":{"hard":{"requests.cpu":"4","limits.cpu":"8"}}}'

# vm-3 재시작
virtctl start poc-quota-vm-3 -n poc-resource-quota

# 초과 상태를 복원하기 위해 Quota 다시 낮추기
oc patch resourcequota poc-quota -n poc-resource-quota \
  --type=merge \
  -p '{"spec":{"hard":{"requests.cpu":"2","limits.cpu":"4"}}}'
```

---

## LimitRange 함께 사용하기 (권장)

ResourceQuota와 함께 LimitRange를 설정하면
requests/limits를 지정하지 않은 Pod에 기본값이 자동으로 적용됩니다.

```bash
oc apply -f - <<'EOF'
apiVersion: v1
kind: LimitRange
metadata:
  name: poc-limitrange
  namespace: poc-resource-quota
spec:
  limits:
    - type: Container
      default:
        cpu: 500m
        memory: 512Mi
      defaultRequest:
        cpu: 250m
        memory: 256Mi
      max:
        cpu: "2"
        memory: 4Gi
      min:
        cpu: 50m
        memory: 64Mi
    - type: PersistentVolumeClaim
      max:
        storage: 50Gi
      min:
        storage: 1Gi
EOF

# LimitRange 확인
oc get limitrange -n poc-resource-quota
oc describe limitrange poc-limitrange -n poc-resource-quota
```

---

## 롤백

```bash
# namespace 삭제 (VM, Quota, LimitRange 포함)
oc delete namespace poc-resource-quota
```
