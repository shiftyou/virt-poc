# Kube Descheduler Operator 설치

## 개요

Kube Descheduler Operator는 클러스터 전체에 걸쳐 불균등하게 배치된 Pod를
재스케줄링하여 Pod 분배를 최적화하는 Operator입니다.

VM(VirtualMachineInstance)도 Pod처럼 관리되므로, VM의 노드 분배 최적화에도
사용됩니다.

---

## 사전 요구 사항

- cluster-admin 권한

---

## 설치 방법

### 방법 1: OpenShift Console (Web UI)

1. **Operators > OperatorHub** 메뉴로 이동
2. `Kube Descheduler` 검색
3. **Kube Descheduler Operator** 선택
4. `Install` 클릭
5. 설정:
   - Update channel: `stable`
   - Installation mode: `All namespaces on the cluster`
   - Installed Namespace: `openshift-kube-descheduler-operator`
6. `Install` 클릭

### 방법 2: CLI (YAML)

```bash
# 1. Namespace 생성
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-kube-descheduler-operator
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# 2. OperatorGroup 생성
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kube-descheduler
  namespace: openshift-kube-descheduler-operator
spec:
  targetNamespaces:
    - openshift-kube-descheduler-operator
EOF

# 3. Subscription 생성
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: cluster-kube-descheduler-operator
  namespace: openshift-kube-descheduler-operator
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: cluster-kube-descheduler-operator
  channel: "stable"
EOF
```

---

## 설치 확인

```bash
# CSV 상태 확인
oc get csv -n openshift-kube-descheduler-operator

# Descheduler Pod 상태 확인
oc get pods -n openshift-kube-descheduler-operator
```

---

## Descheduler 구성

설치 후 `01-environment/descheduler/` 디렉토리의 가이드를 참조하세요.

```bash
cd 01-environment/descheduler
./apply.sh
```

---

## 문제 해결

```bash
# Descheduler Operator 로그 확인
oc logs -n openshift-kube-descheduler-operator deployment/descheduler-operator

# KubeDescheduler CR 상태 확인
oc get kubedescheduler -n openshift-kube-descheduler-operator -o yaml

# Descheduler 이벤트 확인
oc get events -n openshift-kube-descheduler-operator --sort-by='.lastTimestamp'
```
