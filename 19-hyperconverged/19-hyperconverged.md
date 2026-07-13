# HyperConverged Configuration Lab

Change cluster-wide OpenShift Virtualization settings through the HyperConverged CR.

---

## HyperConverged CR Overview

```bash
# Check HyperConverged CR
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o yaml
```

---

## 1. CPU Overcommit (vCPU:pCPU Ratio) Change

The default value is `10:1`. Adjust according to workload characteristics.

```
CPU Overcommit = Number of vCPUs / Number of pCPUs
Default: 10 (1 pCPU per 10 vCPUs)
```

### Check Current Setting

```bash
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.resourceRequirements.vmiCPUAllocationRatio}{"\n"}'
```

### Change Overcommit Ratio

```bash
# Example: 4:1 (allow 4 vCPUs per pCPU)
oc patch hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv \
  --type=merge \
  -p '{"spec":{"resourceRequirements":{"vmiCPUAllocationRatio":4}}}'
```

| Ratio | Description | Suitable Environment |
|------|------|------------|
| `1` | No overcommit (1:1) | CPU-intensive workloads |
| `4` | 4:1 | Balanced environment |
| `10` | 10:1 (default) | General POC / mixed workloads |

> **Caution**: Higher overcommit may cause VM performance degradation during CPU contention

---

## 2. Memory Overcommit

Memory overcommit is configured with `spec.higherWorkloadDensity`.

```bash
# Enable Memory Overcommit (using Swap)
oc patch hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv \
  --type=merge \
  -p '{"spec":{"higherWorkloadDensity":{"memoryOvercommitPercentage":150}}}'
```

| Value | Meaning |
|----|------|
| `100` | No overcommit (default) |
| `150` | Allow VM memory 1.5x physical memory |

---

## 3. Live Migration Configuration

```bash
# Configure Live Migration concurrent count and bandwidth
oc patch hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv \
  --type=merge \
  -p '{
    "spec": {
      "liveMigrationConfig": {
        "parallelMigrationsPerCluster": 5,
        "parallelOutboundMigrationsPerNode": 2,
        "bandwidthPerMigration": "64Mi",
        "completionTimeoutPerGiB": 800,
        "progressTimeout": 150
      }
    }
  }'
```

| Item | Default | Description |
|------|--------|------|
| `parallelMigrationsPerCluster` | 5 | Concurrent migrations across the entire cluster |
| `parallelOutboundMigrationsPerNode` | 2 | Concurrent outbound migrations per node |
| `bandwidthPerMigration` | 0 (unlimited) | Network bandwidth limit per migration |
| `completionTimeoutPerGiB` | 800 | Completion timeout per GiB (seconds) |
| `progressTimeout` | 150 | Timeout when no progress (seconds) |

---

## 4. Feature Gates

```bash
# Check current Feature Gates
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.featureGates}'

# Enable GPU Passthrough
oc patch hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv \
  --type=merge \
  -p '{"spec":{"featureGates":{"deployKubeSecondaryDNS":true}}}'
```

---

## 5. Mediating Device (GPU / SR-IOV)

```bash
# Configure Mediated Device (e.g., GPU vGPU)
oc patch hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv \
  --type=merge \
  -p '{
    "spec": {
      "mediatedDevicesConfiguration": {
        "mediatedDevicesTypes": ["nvidia-231"]
      },
      "permittedHostDevices": {
        "mediatedDevices": [
          {
            "mdevNameSelector": "GRID T4-4Q",
            "resourceName": "nvidia.com/GRID_T4-4Q"
          }
        ]
      }
    }
  }'
```

---

## 6. StorageClass Default Configuration

```bash
source env.conf

# Specify default StorageClass dedicated to Virtualization
oc patch hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv \
  --type=merge \
  -p "{
    \"spec\": {
      \"storageImport\": {
        \"insecureRegistries\": []
      }
    }
  }"

# Configure default StorageClass for DataImportCron
oc patch hco kubevirt-hyperconverged \
  -n openshift-cnv \
  --type=merge \
  -p "{\"spec\":{\"dataImportCronTemplates\":[]}}"
```

---

## Verify and Apply Changes

```bash
# Check HyperConverged status
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv

# Check changes in real-time
oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv \
  -o jsonpath='{.spec.resourceRequirements}{"\n"}'

# Verify reflected in KubeVirt CR (HyperConverged → KubeVirt auto-propagation)
oc get kubevirt kubevirt -n openshift-cnv \
  -o jsonpath='{.spec.configuration.developerConfiguration}{"\n"}'
```

---

## Rollback

```bash
# Restore CPU Overcommit to default value
oc patch hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv \
  --type=merge \
  -p '{"spec":{"resourceRequirements":{"vmiCPUAllocationRatio":10}}}'

# Reset Live Migration configuration
oc patch hyperconverged kubevirt-hyperconverged \
  -n openshift-cnv \
  --type=json \
  -p '[{"op":"remove","path":"/spec/liveMigrationConfig"}]' 2>/dev/null || true
```
