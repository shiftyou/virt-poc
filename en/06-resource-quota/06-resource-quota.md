# ApplicationAwareResourceQuota Practice

Standard Kubernetes `ResourceQuota` counts Pod-level resources, so it cannot directly limit VM resources.
OpenShift Virtualization's `ApplicationAwareResourceQuota` (AARQ) properly accounts for VM resource usage.

Apply AARQ to the `poc-resource-quota` namespace
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
- `06-resource-quota.sh` execution complete

---

## Why ApplicationAwareResourceQuota?

| | Standard ResourceQuota | ApplicationAwareResourceQuota |
|---|---|---|
| Resource counting | Pod-level | VM-aware (virt-launcher) |
| VM quota enforcement | Indirect (may not block) | Direct enforcement |
| Requires | Nothing | `enableApplicationAwareQuota: true` in HyperConverged CR |
| API | `v1 / ResourceQuota` | `aaq.kubevirt.io/v1alpha1 / ApplicationAwareResourceQuota` |

---

## Enable ApplicationAwareQuota

```bash
# Enable in HyperConverged CR (one-time, cluster-wide)
oc patch hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  --type=merge \
  -p '{"spec":{"featureGates":{"enableApplicationAwareQuota":true}}}'

# Verify AAQ controller is running
oc get deployment -n openshift-cnv -l app=aaq-controller

# Verify CRD is available
oc get crd applicationawareresourcequotas.aaq.kubevirt.io
```

---

## Applied ApplicationAwareResourceQuota

| Item | requests | limits |
|------|----------|--------|
| CPU | **2000m** | 5 |
| Memory | 4 Gi | 8 Gi |

> Based on `requests.cpu: "2000m"` — VM at 750m each → 2 VMs (1500m) pass, 3 VMs (2250m) exceed

---

## Practice Verification

### Initial state check

```bash
# AARQ status
oc get aarq poc-quota -n poc-resource-quota -o yaml

# Example status section
# status:
#   hard:
#     limits.cpu: "5"
#     limits.memory: 8Gi
#     requests.cpu: 2000m
#     requests.memory: 4Gi
#   used:
#     limits.cpu: "3"
#     limits.memory: 4Gi
#     requests.cpu: 1500m        ← 1500m used after 2 VMs
#     requests.memory: 2Gi
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
#      limited: requests.cpu=2000m
```

### Check virt-launcher Pod resources

```bash
# Actual CPU/Memory usage of running VMs
oc get pod -n poc-resource-quota -l kubevirt.io=virt-launcher \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .spec.containers[*]}  {.name}: cpu={.resources.requests.cpu} mem={.resources.requests.memory}{"\n"}{end}{end}'
```

---

## AARQ Exceeded Test (additional)

```bash
# Check Quota headroom
oc get aarq poc-quota -n poc-resource-quota -o yaml

# Increase Quota limit to allow vm-3 to start
oc patch aarq poc-quota -n poc-resource-quota \
  --type=merge \
  -p '{"spec":{"hard":{"requests.cpu":"4","limits.cpu":"8"}}}'

# Restart vm-3
virtctl start poc-quota-vm-3 -n poc-resource-quota

# Lower Quota again to restore exceeded state
oc patch aarq poc-quota -n poc-resource-quota \
  --type=merge \
  -p '{"spec":{"hard":{"requests.cpu":"2000m","limits.cpu":"5"}}}'
```

---

## ApplicationAwareClusterResourceQuota

For cluster-wide VM quota across multiple namespaces, use `ApplicationAwareClusterResourceQuota`:

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

## Rollback

```bash
# Delete namespace (including VMs, AARQ)
oc delete namespace poc-resource-quota
```
