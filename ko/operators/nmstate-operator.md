# Kubernetes NMState Operator 설치

## 개요

Kubernetes NMState Operator는 노드의 네트워크 구성을 선언적으로 관리하는 Operator입니다.
`NodeNetworkConfigurationPolicy (NNCP)`를 통해 Linux Bridge, Bond, VLAN 등을 구성하고,
`NodeNetworkState (NNS)`로 각 노드의 현재 네트워크 상태를 조회할 수 있습니다.

OpenShift Virtualization에서 VM 네트워크(NAD/Multus) 구성에 필요합니다.

---

## 사전 요구 사항

- cluster-admin 권한

---

## 설치 방법

### 방법 1: OpenShift Console (Web UI)

1. **Operators > OperatorHub** 메뉴로 이동
2. `Kubernetes NMState` 검색
3. **Kubernetes NMState Operator** 선택
4. `Install` 클릭
5. 설정:
   - Installation mode: `All namespaces on the cluster`
   - Installed Namespace: `openshift-nmstate`
6. `Install` 클릭
7. 설치 완료 후, **NMState 인스턴스 생성**:
   - Operators > Installed Operators > Kubernetes NMState Operator
   - **NMState** 탭 > `Create NMState` 클릭
   - 기본값으로 생성

### 방법 2: CLI (YAML)

```bash
# Namespace 및 Operator 설치
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nmstate
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-nmstate
  namespace: openshift-nmstate
spec:
  targetNamespaces:
  - openshift-nmstate
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubernetes-nmstate-operator
  namespace: openshift-nmstate
spec:
  channel: stable
  name: kubernetes-nmstate-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# NMState 인스턴스 생성 (Operator 설치 완료 후)
cat <<'EOF' | oc apply -f -
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
EOF
```

### 설치 확인

```bash
# Operator 설치 확인
oc get csv -n openshift-nmstate | grep nmstate

# NMState handler Pod 확인
oc get pods -n openshift-nmstate

# 노드별 네트워크 상태 조회
oc get nodenetworkstate
```

### 노드 네트워크 인터페이스 조회

```bash
# 특정 노드의 이더넷 인터페이스 목록
NODE=worker-0
oc get nns $NODE -o jsonpath='{range .status.currentState.interfaces[?(@.type=="ethernet")]}{.name}{"\n"}{end}'
```
