# Node Maintenance Operator (NMO) 설치

## 개요

Node Maintenance Operator (NMO)는 노드를 안전하게 유지보수 모드로 전환하는 Operator입니다.
노드에 `cordon` + `drain` 처리를 수행하여 워크로드를 다른 노드로 이동시킨 후 유지보수 작업을 진행합니다.
OpenShift Virtualization 환경에서는 VM 라이브 마이그레이션과 연동하여 무중단 유지보수를 지원합니다.

---

## 사전 요구 사항

- cluster-admin 권한

---

## 설치 방법

### 방법 1: OpenShift Console (Web UI)

1. **Operators > OperatorHub** 메뉴로 이동
2. `Node Maintenance` 검색
3. **Node Maintenance Operator** 선택
4. `Install` 클릭
5. 설정:
   - Installation mode: `All namespaces on the cluster`
   - Installed Namespace: `openshift-operators`
6. `Install` 클릭

### 방법 2: CLI (YAML)

```bash
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-operators
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: node-maintenance-operator
  namespace: openshift-operators
spec:
  channel: stable
  name: node-maintenance-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

### 설치 확인

```bash
oc get csv -n openshift-operators | grep node-maintenance
```

---

## 사용법

### 노드 유지보수 시작

```bash
cat <<'EOF' | oc apply -f -
apiVersion: nodemaintenance.medik8s.io/v1beta1
kind: NodeMaintenance
metadata:
  name: maintenance-worker-0
spec:
  nodeName: worker-0
  reason: "하드웨어 점검"
EOF
```

### 유지보수 상태 확인

```bash
oc get nodemaintenance
oc describe nodemaintenance maintenance-worker-0
```

### 유지보수 종료

```bash
oc delete nodemaintenance maintenance-worker-0
```
