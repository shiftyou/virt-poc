# OADP (OpenShift API for Data Protection) Operator 설치

## 개요

OADP는 OpenShift에서 애플리케이션 및 VM의 백업/복구를 제공하는 Operator입니다.
Velero를 기반으로 동작하며 S3 호환 스토리지(Garage 또는 ODF MCG)를 백업 저장소로 사용합니다.

---

## 사전 요구 사항

- cluster-admin 권한
- S3 호환 스토리지 (Garage 또는 ODF MCG)

---

## 설치 방법

### 방법 1: OpenShift Console (Web UI)

1. **Operators > OperatorHub** 메뉴로 이동
2. `OADP` 또는 `OpenShift API for Data Protection` 검색
3. **OADP Operator** 선택
4. `Install` 클릭
5. 설정:
   - Update channel: `stable-1.4`
   - Installation mode: `A specific namespace on the cluster`
   - Installed Namespace: `openshift-adp` (기본값)
6. `Install` 클릭 후 완료 대기

### 방법 2: CLI (YAML)

```bash
# 1. Namespace 생성
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-adp
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# 2. OperatorGroup 생성
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: redhat-oadp-operator
  namespace: openshift-adp
spec:
  targetNamespaces:
    - openshift-adp
EOF

# 3. Subscription 생성
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: redhat-oadp-operator
  namespace: openshift-adp
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: redhat-oadp-operator
  channel: "stable-1.4"
EOF
```

---

## 설치 확인

```bash
# Operator 설치 상태 확인
oc get csv -n openshift-adp

# OADP Pod 상태 확인
oc get pods -n openshift-adp

# Velero 확인
oc get deployment velero -n openshift-adp
```

---

## DataProtectionApplication (DPA) 구성

설치 후 `12-oadp/12-oadp.sh`를 실행하면 DPA 및 BackupStorageLocation이 자동으로 구성됩니다.

```bash
cd 12-oadp
./12-oadp.sh
```

---

## 문제 해결

```bash
# OADP Operator 로그 확인
oc logs -n openshift-adp deployment/openshift-adp-controller-manager

# Velero 로그 확인
oc logs -n openshift-adp deployment/velero

# BackupStorageLocation 상태 확인
oc get backupstoragelocation -n openshift-adp
```
