# OADP (OpenShift API for Data Protection) 랩

OADP를 사용하여 VM을 백업하고 복원하는 랩입니다.

```
VM (백업 대상 namespace)
  │  Backup CR 생성
  ▼
OADP (Velero) — openshift-adp namespace
  └─ VM 스냅샷 + PVC 데이터
       │  S3에 저장 (Garage 또는 ODF MCG)
       ▼
  백업 완료

복원:
  Restore CR 생성 → OADP → VM 재생성
```

---

## 사전 요구사항

- OADP Operator 설치 완료 (`operators/oadp-operator.md` 참조) — **`openshift-adp` namespace에 설치**
- S3 백엔드: **Garage** 배포 또는 **ODF Operator** 설치 (아래 Garage 설치 가이드 참조)
- `setup.sh` 실행 완료 (Garage/ODF 자동 감지 후 `env.conf`에 저장)
- `14-oadp.sh` 실행 완료

---

## Garage 설치

Operator 없이 Garage를 경량 S3 호환 오브젝트 스토리지로 배포하는 방법입니다.
ODF 없이 S3 백엔드를 빠르게 구성하고 싶을 때 사용합니다.

### 1. Namespace 및 SCC 설정

```bash
oc new-project poc-garage

# Garage 컨테이너는 임의의 UID로 /data 디렉토리에 쓰기 권한이 필요 — anyuid 부여
oc adm policy add-scc-to-user anyuid -z default -n poc-garage
```

### 2. 리소스 배포

```bash
oc apply -f - <<'EOF'
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: garage-data
  namespace: poc-garage
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
  namespace: poc-garage
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
  namespace: poc-garage
type: Opaque
stringData:
  accessKey: "garageadmin"
  secretKey: "garageadmin"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: garage
  namespace: poc-garage
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
  namespace: poc-garage
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
  namespace: poc-garage
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
  namespace: poc-garage
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

### 3. Garage Layout 구성 및 Bucket 생성

Garage Pod가 실행되면 클러스터 레이아웃을 구성하고 버킷을 생성합니다.

```bash
# Pod 준비 대기
oc wait --for=condition=ready pod -l app=garage -n poc-garage --timeout=300s

# Pod 이름 조회
GARAGE_POD=$(oc get pod -n poc-garage -l app=garage -o jsonpath='{.items[0].metadata.name}')

# 노드 ID 조회
NODE_ID=$(oc exec -n poc-garage $GARAGE_POD -- garage node id | grep "Node ID:" | awk '{print $3}')

# 레이아웃 구성 (단일 노드 설정)
oc exec -n poc-garage $GARAGE_POD -- garage layout assign -z dc1 -c 1 $NODE_ID

# 레이아웃 적용
oc exec -n poc-garage $GARAGE_POD -- garage layout apply --version 1

# 버킷 생성
oc exec -n poc-garage $GARAGE_POD -- garage bucket create velero-backups

# 자격 증명으로 버킷 접근 허용
oc exec -n poc-garage $GARAGE_POD -- garage bucket allow \
  --read --write \
  velero-backups \
  --key garageadmin

# 버킷 확인
oc exec -n poc-garage $GARAGE_POD -- garage bucket list
```

### 4. 기동 확인

```bash
oc get pods -n poc-garage
# NAME                      READY   STATUS    RESTARTS   AGE
# garage-xxxxxxxxx-xxxxx    1/1     Running   0          1m

oc get route -n poc-garage
# NAME          HOST/PORT                            ...
# garage-api    garage-api-poc-garage.apps.cluster.com   ...
```

### 5. 수동 env.conf 설정

`setup.sh`가 Garage를 감지하지 못하는 경우 `env.conf`에 다음 값을 직접 추가합니다.

```bash
GARAGE_INSTALLED=true
GARAGE_ENDPOINT=https://garage-api-poc-garage.apps.<cluster-domain>
GARAGE_ACCESS_KEY=garageadmin
GARAGE_SECRET_KEY=garageadmin
GARAGE_BUCKET=velero-backups
```

이후 `14-oadp.sh`를 실행하면 이 값들로 DPA가 구성됩니다.

---

## 구성 개요

| 항목 | 값 |
|------|-----|
| OADP / DPA namespace | `openshift-adp` (또는 `OADP_NS` 감지 값이 없는 경우) |
| cloud-credentials Secret | `openshift-adp` |
| BackupStorageLocation | `openshift-adp` |
| Backup / Restore | `openshift-adp` |
| S3 백엔드 | Garage 우선, 사용 불가 시 ODF MCG |

```
OBC obc-backups (openshift-adp) — ODF 백엔드 사용 시 자동 생성
  └─ cloud-credentials Secret (openshift-adp)
       └─ DataProtectionApplication poc-dpa (openshift-adp)
            └─ BackupStorageLocation default
                 │
                 ├─ Backup CR   → S3 버킷에 저장
                 └─ Restore CR  → S3 버킷에서 복원
```

---

## 백엔드별 S3 변수

`setup.sh` 실행 시 Garage/ODF를 자동 감지하여 `env.conf`에 저장합니다.
ODF 백엔드의 경우 OBC(ObjectBucketClaim)에서 버킷 이름과 자격 증명을 추가로 가져옵니다.

| 변수 | Garage | ODF (NooBaa MCG) |
|------|-------|-----------------|
| `S3_ENDPOINT` | `GARAGE_ENDPOINT` (env.conf) | `ODF_S3_ENDPOINT` (env.conf) |
| `S3_BUCKET` | `GARAGE_BUCKET` (env.conf) | OBC ConfigMap `BUCKET_NAME` |
| `S3_ACCESS_KEY` | `GARAGE_ACCESS_KEY` (env.conf) | OBC Secret `AWS_ACCESS_KEY_ID` |
| `S3_SECRET_KEY` | `GARAGE_SECRET_KEY` (env.conf) | OBC Secret `AWS_SECRET_ACCESS_KEY` |
| `S3_REGION` | `garage` (고정) | `ODF_S3_REGION` (env.conf, 기본값: `localstorage`) |

---

## ObjectBucketClaim (ODF 백엔드 전용)

`14-oadp.sh`는 ODF 백엔드가 감지되면 OBC를 자동으로 생성합니다.
OBC가 Bound되면 버킷 이름과 버킷별 자격 증명을 읽어 DPA에 등록합니다.

```bash
# OBC 상태 확인
oc get obc obc-backups -n openshift-adp

# OBC ConfigMap에서 버킷 이름 조회
oc get cm obc-backups -n openshift-adp -o jsonpath='{.data.BUCKET_NAME}'

# OBC Secret에서 자격 증명 조회
oc get secret obc-backups -n openshift-adp -o go-template='{{.data.AWS_ACCESS_KEY_ID | base64decode}}'
```

수동으로 생성하려면:

```bash
# NooBaa StorageClass 확인
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

## DataProtectionApplication 설정

`14-oadp.sh`가 이를 자동으로 생성하고 적용합니다. 수동 적용 시 다음을 참조하세요.

```bash
# 1. cloud-credentials Secret 생성 (openshift-adp)
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

# 2. DataProtectionApplication 생성
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

## VolumeSnapshotClass (CSI 스냅샷)

`14-oadp.sh`는 클러스터의 CSI 드라이버를 자동 감지하여 `volumesnapshotclass.yaml`을 생성합니다.
CSI 스냅샷을 사용하는 경우 직접 적용합니다.

```bash
# 생성된 파일 확인 후 적용
oc apply -f volumesnapshotclass.yaml

# CSI 드라이버 목록 확인
oc get csidrivers
```

---

## VM Backup

```bash
# BSL 이름 조회 (OADP가 DPA 이름 기반으로 자동 생성, 예: poc-dpa-1)
BSL=$(oc get backupstoragelocation -n openshift-adp -o jsonpath='{.items[0].metadata.name}')

# 대상 namespace의 VM 백업
oc apply -f - <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: poc-vm-backup
  namespace: openshift-adp
spec:
  includedNamespaces:
    - <백업할 VM namespace>
  storageLocation: ${BSL}
  ttl: 720h0m0s
  snapshotVolumes: true
EOF

# 백업 상태 확인
oc get backup -n openshift-adp

# 백업 상세 정보 확인
oc describe backup poc-vm-backup -n openshift-adp
```

---

## VM Restore

```bash
# 백업에서 복원
oc apply -f - <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: poc-vm-restore
  namespace: openshift-adp
spec:
  backupName: poc-vm-backup
  includedNamespaces:
    - <복원할 VM namespace>
  restorePVs: true
EOF

# 복원 상태 확인
oc get restore -n openshift-adp

# 복원된 VM 확인 (복원 대상 namespace 지정)
oc get vm -n <복원할 VM namespace>
```

---

## BackupStorageLocation 검증

```bash
# BackupStorageLocation 상태 (Available이어야 함)
oc get backupstoragelocation -n openshift-adp

# 상세 정보 확인
oc describe backupstoragelocation -n openshift-adp
```

---

## Schedule — 주기적 Backup

```bash
# 매일 오전 2시 자동 백업
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
      - <백업할 VM namespace>
    storageLocation: default
    ttl: 168h0m0s
    snapshotVolumes: true
EOF

# Schedule 확인
oc get schedule -n openshift-adp
```

---

## 문제 해결

```bash
# Velero Pod 로그
oc logs -n openshift-adp -l app.kubernetes.io/name=velero --tail=50

# NodeAgent 로그 (PVC 백업/복원)
oc logs -n openshift-adp daemonset/node-agent --tail=30

# BackupStorageLocation 상세 정보
oc describe backupstoragelocation -n openshift-adp

# DPA 상태 확인
oc get dpa poc-dpa -n openshift-adp -o yaml

# OBC 상태 확인 (ODF 백엔드)
oc get obc obc-backups -n openshift-adp
oc describe obc obc-backups -n openshift-adp
```

---

## 롤백

```bash
# Schedule 삭제
oc delete schedule poc-daily-backup -n openshift-adp

# DataProtectionApplication 삭제
oc delete dpa poc-dpa -n openshift-adp

# cloud-credentials Secret 삭제
oc delete secret cloud-credentials -n openshift-adp

# OBC 삭제 (ODF 백엔드)
oc delete obc obc-backups -n openshift-adp
```
