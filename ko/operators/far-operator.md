# Fence Agents Remediation (FAR) Operator 설치

## 개요

Fence Agents Remediation (FAR)은 노드 장애 발생 시 IPMI/BMC를 통해
물리 노드를 재시작(fencing)하여 장애 상황에서 자동으로 복구하는 Operator입니다.

Node Health Check Operator와 함께 사용하여 자동 노드 복구를 구성합니다.

---

## 사전 요구 사항

- cluster-admin 권한
- Worker 노드에 IPMI/BMC 접근 가능
- setup.sh에 Fence Agent 정보 입력 필요 (FENCE_AGENT_IP, FENCE_AGENT_USER, FENCE_AGENT_PASS)

---

## 설치 방법

### 방법 1: OpenShift Console (Web UI)

1. **Operators > OperatorHub** 메뉴로 이동
2. `Fence Agents Remediation` 검색
3. **Fence Agents Remediation Operator** 선택
4. `Install` 클릭
5. 설정:
   - Installation mode: `All namespaces on the cluster`
   - Installed Namespace: `openshift-workload-availability`
6. `Install` 클릭

### 방법 2: CLI (YAML)

```bash
# 1. Namespace 생성
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-workload-availability
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# 2. OperatorGroup 생성
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

# 3. Subscription 생성
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: fence-agents-remediation-operator
  namespace: openshift-workload-availability
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: fence-agents-remediation-operator
  channel: "stable"
EOF
```

---

## 설치 확인

```bash
# CSV 상태 확인
oc get csv -n openshift-workload-availability | grep fence

# Pod 상태 확인
oc get pods -n openshift-workload-availability | grep fence
```

---

## FAR 구성

설치 후 `01-environment/far/` 디렉토리의 가이드를 참조하세요.

```bash
cd 01-environment/far
./apply.sh
```

---

## 문제 해결

```bash
# FAR Operator 로그 확인
oc logs -n openshift-workload-availability deployment/fence-agents-remediation-operator-controller-manager

# FenceAgentsRemediation 상태 확인
oc get fenceagentsremediation -A

# IPMI 연결 테스트 (노드에서)
ipmitool -I lanplus -H <BMC_IP> -U <USER> -P <PASS> chassis power status
```
