# Self Node Remediation (SNR) Operator 설치

## 개요

Self Node Remediation (SNR)은 노드 장애 발생 시 노드가 스스로 재시작하여 복구하는 Operator입니다.
FAR과 달리 외부 IPMI 없이 동작하며, 노드 간 통신을 통해 장애 노드를 감지하고 재시작합니다.

---

## 사전 요구 사항

- cluster-admin 권한
- openshift-workload-availability namespace (FAR과 공유)

---

## 설치 방법

### 방법 1: OpenShift Console (Web UI)

1. **Operators > OperatorHub** 메뉴로 이동
2. `Self Node Remediation` 검색
3. **Self Node Remediation Operator** 선택
4. `Install` 클릭
5. 설정:
   - Installation mode: `All namespaces on the cluster`
   - Installed Namespace: `openshift-workload-availability`
6. `Install` 클릭

### 방법 2: CLI (YAML)

```bash
# Namespace 생성 (FAR과 공유, 없으면 생성)
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-workload-availability
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# OperatorGroup (FAR과 공유, 이미 존재하면 생략)
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: workload-availability
  namespace: openshift-workload-availability
spec:
  targetNamespaces:
    - openshift-workload-availability
EOF

# Subscription 생성
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: self-node-remediation-operator
  namespace: openshift-workload-availability
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: self-node-remediation-operator
  channel: "stable"
EOF
```

---

## 설치 확인

```bash
# CSV 상태 확인
oc get csv -n openshift-workload-availability | grep self-node

# SNR DaemonSet 확인 (모든 노드에 배포)
oc get daemonset -n openshift-workload-availability | grep self-node

# SNR Pod 상태 확인
oc get pods -n openshift-workload-availability | grep self-node
```

---

## SNR 구성

설치 후 `01-environment/snr/` 디렉토리에서 apply.sh를 실행하면
SNR 설정과 **Node Health Check (NHC)** CR이 함께 생성됩니다.

```bash
cd 01-environment/snr
./apply.sh
```

> **자동 복구가 동작하려면 NHC (Node Health Check) Operator도 설치되어 있어야 합니다.**
> NHC가 노드 상태를 감지하고 SNR을 트리거합니다.
> → [06-nhc-operator.md](./06-nhc-operator.md) 참조

---

## 문제 해결

```bash
# SNR Operator 로그 확인
oc logs -n openshift-workload-availability deployment/self-node-remediation-operator-controller-manager

# SNR DaemonSet Pod 로그 확인
oc logs -n openshift-workload-availability -l app.kubernetes.io/name=self-node-remediation

# SelfNodeRemediation 상태 확인
oc get selfnoderemediation -A
```
