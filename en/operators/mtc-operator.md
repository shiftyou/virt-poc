# Migration Toolkit for Containers (MTC) Operator Installation

## Overview

MTC (Migration Toolkit for Containers) is an Operator that migrates namespaces, Pods, and PersistentVolumeClaims
between OpenShift clusters.

> **Note:** For VM disk StorageClass migration within the same cluster, OpenShift Virtualization has a built-in
> storage migration feature (OCP Virt 4.16+) that does not require MTC or object storage.
> See `21-storage-migration/21-storage-migration.md`.

```
Source Cluster (or same cluster)              Destination Cluster (or same cluster)
  Namespace + PVCs                               Namespace + PVCs
  (StorageClass A)       →  MTC migration →      (StorageClass B)
```

Main use cases:
- **Inter-cluster migration**: Move workloads from an old cluster to a new cluster
- **Intra-cluster storage migration**: Change PVC StorageClass within the same cluster (e.g., NFS → Ceph RBD)

---

## Prerequisites

- cluster-admin privileges
- S3-compatible object storage (Garage, ODF NooBaa, etc.) — used as replication repository

---

## Installation Methods

### Method 1: OpenShift Console (Web UI)

1. Navigate to **Operators > OperatorHub** menu
2. Search for `Migration Toolkit for Containers`
3. Select **Migration Toolkit for Containers**
4. Click `Install`
5. Settings:
   - Update channel: `release-v1.8` (select latest channel)
   - Installation mode: `All namespaces on the cluster`
   - Installed Namespace: `openshift-migration`
6. Click `Install` and wait for completion
7. After installation, **Create MigrationController instance**:
   - Operators > Installed Operators > Migration Toolkit for Containers
   - **MigrationController** tab > Click `Create MigrationController`
   - Create with default values

### Method 2: CLI (YAML)

```bash
# 1. Create Namespace
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-migration
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# 2. Create OperatorGroup
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: migration
  namespace: openshift-migration
spec:
  targetNamespaces:
    - openshift-migration
EOF

# 3. Create Subscription
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: mtc-operator
  namespace: openshift-migration
spec:
  channel: release-v1.8
  name: mtc-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# 4. Wait for Operator installation to complete
oc wait csv -n openshift-migration \
  -l operators.coreos.com/mtc-operator.openshift-migration \
  --for=jsonpath='{.status.phase}'=Succeeded \
  --timeout=5m

# 5. Create MigrationController instance
oc apply -f - <<'EOF'
apiVersion: migration.openshift.io/v1alpha1
kind: MigrationController
metadata:
  name: migration-controller
  namespace: openshift-migration
spec:
  azure_resource_group: ""
  cluster_name: host
  mig_ui_affinity: {}
  mig_ui_node_selector: {}
  mig_ui_replicas: 1
  mig_ui_tolerations: []
  migration_log_reader: true
  olm_managed: true
  restic_timeout: 1h
  version: latest
EOF
```

---

## Verify Installation

```bash
# Check Operator installation status
oc get csv -n openshift-migration | grep mtc

# Check MigrationController status
oc get migrationcontroller -n openshift-migration

# Check all Pod statuses
oc get pods -n openshift-migration

# Check MTC UI Route
oc get route migration -n openshift-migration
```

---

## Troubleshooting

```bash
# Check MigrationController events
oc describe migrationcontroller migration-controller -n openshift-migration

# Check Operator logs
oc logs -n openshift-migration deployment/migration-operator

# Check controller logs
oc logs -n openshift-migration deployment/migration-controller

# Check Velero logs (backup/restore engine)
oc logs -n openshift-migration deployment/velero
```
