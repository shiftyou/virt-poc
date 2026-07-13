# ResourceQuota Practice

Apply ResourceQuota to the `poc-resource-quota` namespace
to verify that 2 VMs pass, and the 3rd VM is rejected for exceeding the CPU quota.

```
Initial state (within Quota)
┌────────────────────────────────────────────────┐
│  poc-resource-quota                            │
│                                                │
│  ● poc-quota-vm-1  (cpu request: 750m) ✅      │
│  ● poc-quota-vm-2  (cpu request: 750m) ✅      │
│                                                │
│  requests.cpu used: 1500m / 2000m              │
└────────────────────────────────────────────────┘

3rd VM creation attempt → Quota exceeded
┌────────────────────────────────────────────────┐
│  poc-resource-quota                            │
│                                                │
│  ● poc-quota-vm-1  (750m) ✅                   │
│  ● poc-quota-vm-2  (750m) ✅                   │
│  ✗ poc-quota-vm-3  (750m) → 2250m > 2000m     │
│                             virt-launcher denied│
└────────────────────────────────────────────────┘
```

---

## Prerequisites

- cluster-admin or namespace admin permissions
- `01-template` complete — poc Template registered
- `05-resource-quota.sh` execution complete

---

## Applied ResourceQuota

| Item | requests | limits |
|------|----------|--------|
| CPU | **2 core** | 4 core |
| Memory | 4 Gi | 8 Gi |
| Pod count | — | 10 |
| PVC count | — | 10 |
| Storage | 100 Gi | — |
| Service | — | 10 |
| LoadBalancer | — | 2 |
| NodePort | — | 0 |
| ConfigMap | — | 20 |
| Secret | — | 20 |

> Based on `requests.cpu: "2"` (2000m) — VM at 750m each → 2 VMs (1500m) pass, 3 VMs (2250m) exceed

---

## Practice Verification

### Initial state check

```bash
# ResourceQuota status
oc describe resourcequota poc-quota -n poc-resource-quota

# Example output
# Resource                  Used    Hard
# --------                  ----    ----
# limits.cpu                3000m   4
# limits.memory             4Gi     8Gi
# requests.cpu              1500m   2       ← 1500m used after 2 VMs
# requests.memory           2Gi     4Gi
# pods                      2       10
```

### VM status check

```bash
# VM list
oc get vm -n poc-resource-quota

# NAME             AGE   STATUS    READY
# poc-quota-vm-1   ...   Running   True
# poc-quota-vm-2   ...   Running   True
# poc-quota-vm-3   ...   Stopped   False   ← virt-launcher Pod cannot start

# virt-launcher Pod status
oc get pod -n poc-resource-quota -l kubevirt.io=virt-launcher
```

### Check Quota exceeded events

```bash
# Quota exceeded events
oc get events -n poc-resource-quota --field-selector reason=FailedCreate \
  --sort-by='.lastTimestamp'

# Example output
# ...  FailedCreate  ...  pods "virt-launcher-poc-quota-vm-3-..."
#      is forbidden: exceeded quota: poc-quota,
#      requested: requests.cpu=750m, used: requests.cpu=1500m,
#      limited: requests.cpu=2
```

### Check virt-launcher Pod resources

```bash
# Actual CPU/Memory usage of running VMs
oc get pod -n poc-resource-quota -l kubevirt.io=virt-launcher \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.containers[*]}  {.name}: cpu={.resources.requests.cpu} mem={.resources.requests.memory}{"\n"}{end}{end}'
```

---

## ResourceQuota Exceeded Test (additional)

```bash
# Check Quota headroom
oc describe resourcequota poc-quota -n poc-resource-quota

# Increase Quota limit to allow vm-3 to start
oc patch resourcequota poc-quota -n poc-resource-quota \
  --type=merge \
  -p '{"spec":{"hard":{"requests.cpu":"4","limits.cpu":"8"}}}'

# Restart vm-3
virtctl start poc-quota-vm-3 -n poc-resource-quota

# Lower Quota again to restore exceeded state
oc patch resourcequota poc-quota -n poc-resource-quota \
  --type=merge \
  -p '{"spec":{"hard":{"requests.cpu":"2","limits.cpu":"4"}}}'
```

---

## Using LimitRange Together (recommended)

Setting up LimitRange together with ResourceQuota automatically applies
default values to Pods that don't specify requests/limits.

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

# Check LimitRange
oc get limitrange -n poc-resource-quota
oc describe limitrange poc-limitrange -n poc-resource-quota
```

---

## Rollback

```bash
# Delete namespace (including VMs, Quota, LimitRange)
oc delete namespace poc-resource-quota
```
