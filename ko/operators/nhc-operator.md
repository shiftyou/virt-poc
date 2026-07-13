# Node Health Check (NHC) Operator 설치

## 개요

Node Health Check (NHC) Operator는 노드 상태를 지속적으로 모니터링하고,
비정상 노드를 감지하면 복구 템플릿(SNR 또는 FAR)을 트리거합니다.

SNR/FAR은 복구의 **방법**을 정의하고, NHC는 복구의 **시점**을 결정합니다.
자동 복구를 완성하려면 두 Operator를 함께 사용해야 합니다.

```
NHC (감지) → SNR/FAR Template (복구 실행)
```

---

## 사전 요구 사항

- Self Node Remediation Operator 또는 FAR Operator 설치 완료
- `openshift-workload-availability` namespace 존재

---

## 설치 방법

### 방법 1: OpenShift Console (Web UI)

1. **Operators > OperatorHub** 메뉴로 이동
2. `Node Health Check` 검색
3. **Node Health Check Operator** 선택
4. `Install` 클릭
5. 설정:
   - Installation mode: `All namespaces on the cluster`
   - Installed Namespace: `openshift-workload-availability`
6. `Install` 클릭

### 방법 2: CLI (YAML)

```bash
# Namespace 생성 (이미 존재하면 생략)
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-workload-availability
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# OperatorGroup (이미 존재하면 생략)
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
  name: node-healthcheck-operator
  namespace: openshift-workload-availability
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: node-healthcheck-operator
  channel: "stable"
EOF
```

---

## 설치 확인

```bash
# CSV 상태 확인 (Succeeded여야 함)
oc get csv -n openshift-workload-availability | grep node-health

# NHC Controller Pod 확인
oc get pods -n openshift-workload-availability | grep node-health
```

---

## NHC 구성

설치 후 `01-environment/snr/` 디렉토리에서 apply.sh를 실행하면
NHC CR도 함께 생성됩니다.

```bash
cd 01-environment/snr
./apply.sh
```

---

## 문제 해결

```bash
# NHC Controller 로그 확인
oc logs -n openshift-workload-availability \
  deployment/node-healthcheck-operator-controller-manager

# NodeHealthCheck 상태 확인
oc get nodehealthcheck -A

# 노드 Condition 확인 (이상 감지 여부)
oc get nodes -o custom-columns="NAME:.metadata.name,READY:.status.conditions[?(@.type=='Ready')].status"

# 복구 이력 확인
oc get events -n openshift-workload-availability | grep -i remediat
```
