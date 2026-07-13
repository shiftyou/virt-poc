# Migration Toolkit for Containers (MTC) Operator 설치

## 개요

MTC (Migration Toolkit for Containers)는 OpenShift 클러스터 간에 namespace, Pod,
PersistentVolumeClaim을 마이그레이션하는 Operator입니다.

> **참고:** 동일 클러스터 내에서 VM 디스크의 StorageClass 마이그레이션의 경우, OpenShift Virtualization에
> 내장된 스토리지 마이그레이션 기능(OCP Virt 4.16+)이 있으며 MTC나 오브젝트 스토리지가 필요하지 않습니다.
> `21-storage-migration/21-storage-migration.md`를 참조하세요.

```
소스 클러스터 (또는 동일 클러스터)              대상 클러스터 (또는 동일 클러스터)
  Namespace + PVC                               Namespace + PVC
  (StorageClass A)       →  MTC 마이그레이션 →      (StorageClass B)
```

주요 사용 사례:
- **클러스터 간 마이그레이션**: 이전 클러스터에서 새 클러스터로 워크로드 이동
- **클러스터 내 스토리지 마이그레이션**: 동일 클러스터 내에서 PVC StorageClass 변경 (예: NFS → Ceph RBD)

---

## 사전 요구 사항

- cluster-admin 권한
- S3 호환 오브젝트 스토리지 (Garage, ODF NooBaa 등) -- 복제 저장소로 사용

---

## 설치 방법

### 방법 1: OpenShift Console (Web UI)

1. **Operators > OperatorHub** 메뉴로 이동
2. `Migration Toolkit for Containers` 검색
3. **Migration Toolkit for Containers** 선택
4. `Install` 클릭
5. 설정:
   - Update channel: `release-v1.8` (최신 채널 선택)
   - Installation mode: `All namespaces on the cluster`
   - Installed Namespace: `openshift-migration`
6. `Install` 클릭 후 완료 대기
7. 설치 완료 후, **MigrationController 인스턴스 생성**:
   - Operators > Installed Operators > Migration Toolkit for Containers
   - **MigrationController** 탭 > `Create MigrationController` 클릭
   - 기본값으로 생성

### 방법 2: CLI (YAML)

```bash
# 1. Namespace 생성
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-migration
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# 2. OperatorGroup 생성
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

# 3. Subscription 생성
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

# 4. Operator 설치 완료 대기
oc wait csv -n openshift-migration \
  -l operators.coreos.com/mtc-operator.openshift-migration \
  --for=jsonpath='{.status.phase}'=Succeeded \
  --timeout=5m

# 5. MigrationController 인스턴스 생성
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

## 설치 확인

```bash
# Operator 설치 상태 확인
oc get csv -n openshift-migration | grep mtc

# MigrationController 상태 확인
oc get migrationcontroller -n openshift-migration

# 모든 Pod 상태 확인
oc get pods -n openshift-migration

# MTC UI Route 확인
oc get route migration -n openshift-migration
```

---

## 문제 해결

```bash
# MigrationController 이벤트 확인
oc describe migrationcontroller migration-controller -n openshift-migration

# Operator 로그 확인
oc logs -n openshift-migration deployment/migration-operator

# Controller 로그 확인
oc logs -n openshift-migration deployment/migration-controller

# Velero 로그 확인 (백업/복구 엔진)
oc logs -n openshift-migration deployment/velero
```
