# OADP (OpenShift API for Data Protection) Lab

This is a lab for backing up and restoring VMs using OADP.

```
VM (backup target namespace)
  │  Create Backup CR
  ▼
OADP (Velero) — openshift-adp namespace
  └─ VM snapshot + PVC data
       │  Store in S3 (Garage or ODF MCG)
       ▼
  Backup complete

Restore:
  Create Restore CR → OADP → Recreate VM
```

---

## Prerequisites

- OADP Operator installed (`operators/oadp-operator.md` for reference) — **installed in `openshift-adp` namespace**
- S3 backend: Deploy **Garage** or install **ODF Operator** (see Garage installation guide below)
- `setup.sh` execution completed (auto-detects Garage/ODF and saves to `env.conf`)
- `14-oadp.sh` execution completed

---

## Garage Installation

A method to deploy Garage as a lightweight S3-compatible object storage without an Operator.
Use this when you want to quickly set up an S3 backend without ODF.

### 1. Namespace and SCC Setup

```bash
oc new-project garage

# Garage container needs write access to /data directory with arbitrary UID — grant anyuid
oc adm policy add-scc-to-user anyuid -z default -n garage
```

### 2. Deploy Resources

```bash
oc apply -f - <<'EOF'
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: garage-data
  namespace: garage
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: garage-meta
  namespace: garage
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Secret
metadata:
  name: garage-credentials
  namespace: garage
type: Opaque
stringData:
  accessKey: "garageadmin"
  secretKey: "garageadmin"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: garage
  namespace: garage
spec:
  replicas: 1
  selector:
    matchLabels:
      app: garage
  template:
    metadata:
      labels:
        app: garage
    spec:
      containers:
        - name: garage
          image: dxflrs/garage:v1.0.1
          env:
            - name: GARAGE_RPC_SECRET
              value: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
          ports:
            - containerPort: 3900
              name: s3-api
            - containerPort: 3902
              name: web
          volumeMounts:
            - name: data
              mountPath: /data
            - name: meta
              mountPath: /meta
            - name: config
              mountPath: /etc/garage.toml
              subPath: garage.toml
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: garage-data
        - name: meta
          persistentVolumeClaim:
            claimName: garage-meta
        - name: config
          configMap:
            name: garage-config
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: garage-config
  namespace: garage
data:
  garage.toml: |
    metadata_dir = "/meta"
    data_dir = "/data"
    
    replication_factor = 1
    
    rpc_bind_addr = "[::]:3901"
    rpc_public_addr = "127.0.0.1:3901"
    rpc_secret = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
    
    [s3_api]
    s3_region = "garage"
    api_bind_addr = "[::]:3900"
    root_domain = ".s3.garage.localhost"
    
    [s3_web]
    bind_addr = "[::]:3902"
    root_domain = ".web.garage.localhost"
---
apiVersion: v1
kind: Service
metadata:
  name: garage
  namespace: garage
spec:
  selector:
    app: garage
  ports:
    - name: s3-api
      port: 3900
      targetPort: 3900
    - name: web
      port: 3902
      targetPort: 3902
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: garage-api
  namespace: garage
spec:
  to:
    kind: Service
    name: garage
  port:
    targetPort: s3-api
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
```

### 3. Configure Garage Layout and Create Bucket

Once Garage pod is running, configure the cluster layout and create a bucket.

```bash
# Wait for pod to be ready
oc wait --for=condition=ready pod -l app=garage -n garage --timeout=300s

# Get pod name
GARAGE_POD=$(oc get pod -n garage -l app=garage -o jsonpath='{.items[0].metadata.name}')

# Get node ID
NODE_ID=$(oc exec -n garage $GARAGE_POD -- garage node id | grep "Node ID:" | awk '{print $3}')

# Configure layout (single-node setup)
oc exec -n garage $GARAGE_POD -- garage layout assign -z dc1 -c 1 $NODE_ID

# Apply layout
oc exec -n garage $GARAGE_POD -- garage layout apply --version 1

# Create bucket
oc exec -n garage $GARAGE_POD -- garage bucket create velero-backups

# Allow bucket access with credentials
oc exec -n garage $GARAGE_POD -- garage bucket allow \
  --read --write \
  velero-backups \
  --key garageadmin

# Verify bucket
oc exec -n garage $GARAGE_POD -- garage bucket list
```

### 4. Verify Startup

```bash
oc get pods -n garage
# NAME                      READY   STATUS    RESTARTS   AGE
# garage-xxxxxxxxx-xxxxx    1/1     Running   0          1m

oc get route -n garage
# NAME          HOST/PORT                            ...
# garage-api    garage-api-garage.apps.cluster.com   ...
```

### 5. Manual env.conf Settings

If `setup.sh` fails to detect Garage, add the following values directly to `env.conf`.

```bash
GARAGE_INSTALLED=true
GARAGE_ENDPOINT=https://garage-api-garage.apps.<cluster-domain>
GARAGE_ACCESS_KEY=garageadmin
GARAGE_SECRET_KEY=garageadmin
GARAGE_BUCKET=velero-backups
```

After that, run `14-oadp.sh` to configure DPA with these values.

---

## Configuration Overview

| Item | Value |
|------|-----|
| OADP / DPA namespace | `openshift-adp` (or `OADP_NS` detected value if not found) |
| cloud-credentials Secret | `openshift-adp` |
| BackupStorageLocation | `openshift-adp` |
| Backup / Restore | `openshift-adp` |
| S3 backend | Garage preferred, ODF MCG if not available |

```
OBC obc-backups (openshift-adp) — auto-created when ODF backend is used
  └─ cloud-credentials Secret (openshift-adp)
       └─ DataProtectionApplication poc-dpa (openshift-adp)
            └─ BackupStorageLocation default
                 │
                 ├─ Backup CR   → Store in S3 bucket
                 └─ Restore CR  → Restore from S3 bucket
```

---

## S3 Variables by Backend

When `setup.sh` runs, it auto-detects Garage/ODF and saves to `env.conf`.
For ODF backend, bucket name and credentials are additionally obtained from OBC (ObjectBucketClaim).

| Variable | Garage | ODF (NooBaa MCG) |
|------|-------|-----------------|
| `S3_ENDPOINT` | `GARAGE_ENDPOINT` (env.conf) | `ODF_S3_ENDPOINT` (env.conf) |
| `S3_BUCKET` | `GARAGE_BUCKET` (env.conf) | OBC ConfigMap `BUCKET_NAME` |
| `S3_ACCESS_KEY` | `GARAGE_ACCESS_KEY` (env.conf) | OBC Secret `AWS_ACCESS_KEY_ID` |
| `S3_SECRET_KEY` | `GARAGE_SECRET_KEY` (env.conf) | OBC Secret `AWS_SECRET_ACCESS_KEY` |
| `S3_REGION` | `garage` (fixed) | `ODF_S3_REGION` (env.conf, default: `localstorage`) |

---

## ObjectBucketClaim (ODF backend only)

`14-oadp.sh` automatically creates an OBC when ODF backend is detected.
Once the OBC is Bound, it reads the bucket name and per-bucket credentials to register with DPA.

```bash
# Check OBC status
oc get obc obc-backups -n openshift-adp

# Get bucket name from OBC ConfigMap
oc get cm obc-backups -n openshift-adp -o jsonpath='{.data.BUCKET_NAME}'

# Get credentials from OBC Secret
oc get secret obc-backups -n openshift-adp -o go-template='{{.data.AWS_ACCESS_KEY_ID | base64decode}}'
```

To create manually:

```bash
# Check NooBaa StorageClass
oc get storageclass | grep noobaa

oc apply -f - <<EOF
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: obc-backups
  namespace: openshift-adp
spec:
  generateBucketName: backups
  storageClassName: openshift-storage.noobaa.io
EOF
```

---

## DataProtectionApplication Settings

`14-oadp.sh` automatically creates and applies this. Refer to the following for manual application.

```bash
# 1. Create cloud-credentials Secret (openshift-adp)
oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloud-credentials
  namespace: openshift-adp
stringData:
  cloud: |
    [default]
    aws_access_key_id=${S3_ACCESS_KEY}
    aws_secret_access_key=${S3_SECRET_KEY}
EOF

# 2. Create DataProtectionApplication
oc apply -f - <<EOF
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: poc-dpa
  namespace: openshift-adp
spec:
  configuration:
    nodeAgent:
      enable: true
      uploaderType: restic
    velero:
      defaultPlugins:
        - aws
        - openshift
        - kubevirt
        - csi
      disableFsBackup: false
  logFormat: text
  backupLocations:
    - velero:
        provider: aws
        default: true
        objectStorage:
          bucket: ${S3_BUCKET}
          prefix: oadp
        config:
          profile: default
          region: ${S3_REGION}
          s3ForcePathStyle: "true"
          s3Url: ${S3_ENDPOINT}
          checksumAlgorithm: ""
        credential:
          key: cloud
          name: cloud-credentials
EOF
```

---

## VolumeSnapshotClass (CSI snapshot)

`14-oadp.sh` auto-detects the cluster's CSI driver and generates `volumesnapshotclass.yaml`.
Apply directly if using CSI snapshots.

```bash
# Review generated file and apply
oc apply -f volumesnapshotclass.yaml

# Check list of CSI drivers
oc get csidrivers
```

---

## VM Backup

```bash
# Get BSL name (OADP auto-creates based on DPA name, e.g.: poc-dpa-1)
BSL=$(oc get backupstoragelocation -n openshift-adp -o jsonpath='{.items[0].metadata.name}')

# Backup VMs in the target namespace
oc apply -f - <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: poc-vm-backup
  namespace: openshift-adp
spec:
  includedNamespaces:
    - <VM namespace to backup>
  storageLocation: ${BSL}
  ttl: 720h0m0s
  snapshotVolumes: true
EOF

# Check backup status
oc get backup -n openshift-adp

# Check backup details
oc describe backup poc-vm-backup -n openshift-adp
```

---

## VM Restore

```bash
# Restore from backup
oc apply -f - <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: poc-vm-restore
  namespace: openshift-adp
spec:
  backupName: poc-vm-backup
  includedNamespaces:
    - <VM namespace to restore>
  restorePVs: true
EOF

# Check restore status
oc get restore -n openshift-adp

# Check restored VMs (specify the restore target namespace)
oc get vm -n <VM namespace to restore>
```

---

## BackupStorageLocation Verification

```bash
# BackupStorageLocation status (must be Available)
oc get backupstoragelocation -n openshift-adp

# Check details
oc describe backupstoragelocation -n openshift-adp
```

---

## Schedule — Periodic Backup

```bash
# Automatic backup every day at 2 AM
oc apply -f - <<EOF
apiVersion: velero.io/v1
kind: Schedule
metadata:
  name: poc-daily-backup
  namespace: openshift-adp
spec:
  schedule: "0 2 * * *"
  template:
    includedNamespaces:
      - <VM namespace to backup>
    storageLocation: default
    ttl: 168h0m0s
    snapshotVolumes: true
EOF

# Check Schedule
oc get schedule -n openshift-adp
```

---

## Troubleshooting

```bash
# Velero Pod logs
oc logs -n openshift-adp -l app.kubernetes.io/name=velero --tail=50

# NodeAgent logs (PVC backup/restore)
oc logs -n openshift-adp daemonset/node-agent --tail=30

# BackupStorageLocation details
oc describe backupstoragelocation -n openshift-adp

# Check DPA status
oc get dpa poc-dpa -n openshift-adp -o yaml

# Check OBC status (ODF backend)
oc get obc obc-backups -n openshift-adp
oc describe obc obc-backups -n openshift-adp
```

---

## Rollback

```bash
# Delete Schedule
oc delete schedule poc-daily-backup -n openshift-adp

# Delete DataProtectionApplication
oc delete dpa poc-dpa -n openshift-adp

# Delete cloud-credentials Secret
oc delete secret cloud-credentials -n openshift-adp

# Delete OBC (ODF backend)
oc delete obc obc-backups -n openshift-adp
```
