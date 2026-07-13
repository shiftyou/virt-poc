# OpenShift Virtualization Operator 설치

## 개요

OpenShift Virtualization (CNV, Container Native Virtualization)은 컨테이너와 동일한 플랫폼에서
OpenShift 위에 가상 머신(VM)을 실행하고 관리할 수 있게 해주는 Operator입니다.
KubeVirt를 기반으로 동작하며 VM 생성, 마이그레이션, 스냅샷, 백업 등의 기능을 제공합니다.

---

## 사전 요구 사항

- cluster-admin 권한
- OpenShift 4.12 이상
- Worker 노드 CPU 가상화 지원 (Intel VT-x / AMD-V)

```bash
# Worker 노드 가상화 지원 확인
oc get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.capacity.cpu

# 노드에서 직접 확인
oc debug node/<worker-node> -- chroot /host grep -m1 -E 'vmx|svm' /proc/cpuinfo
```

---

## 설치 방법

### 방법 1: OpenShift Console (Web UI)

1. **Operators > OperatorHub** 메뉴로 이동
2. `OpenShift Virtualization` 검색
3. **OpenShift Virtualization** 선택
4. `Install` 클릭
5. 설정:
   - Update channel: `stable`
   - Installation mode: `All namespaces on the cluster`
   - Installed Namespace: `openshift-cnv`
6. `Install` 클릭 후 완료 대기
7. 설치 완료 후, **HyperConverged 인스턴스 생성**:
   - Operators > Installed Operators > OpenShift Virtualization
   - **HyperConverged** 탭 > `Create HyperConverged` 클릭
   - 기본값으로 생성

### 방법 2: CLI (YAML)

```bash
# 1. Namespace 생성
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# 2. OperatorGroup 생성
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
    - openshift-cnv
EOF

# 3. Subscription 생성
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: openshift-cnv
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: kubevirt-hyperconverged
  channel: stable
EOF

# 4. Operator 설치 완료 대기
oc wait csv -n openshift-cnv \
  -l operators.coreos.com/kubevirt-hyperconverged.openshift-cnv \
  --for=jsonpath='{.status.phase}'=Succeeded \
  --timeout=5m

# 5. HyperConverged 인스턴스 생성
oc apply -f - <<'EOF'
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
EOF
```

---

## 설치 확인

```bash
# Operator 설치 상태 확인
oc get csv -n openshift-cnv | grep kubevirt

# HyperConverged 상태 확인 (Available: True)
oc get hco -n openshift-cnv kubevirt-hyperconverged

# 모든 Pod 상태 확인
oc get pods -n openshift-cnv

# 가상화 기능 준비 상태 확인
oc get infrastructure.config.openshift.io cluster -o jsonpath='{.status.platform}'
```

---

## 설치 후 확인

```bash
# VM 생성 가능 여부 확인 (기본 Template 목록)
oc get template -n openshift | grep rhel

# virtctl CLI 다운로드 경로 확인
oc get ConsoleCLIDownload virtctl-clidownloads-kubevirt-hyperconverged \
  -o jsonpath='{.spec.links[0].href}'

# 가상화 기능 상태
oc get kubevirt -n openshift-cnv
```

---

## 문제 해결

```bash
# HyperConverged 이벤트 확인
oc describe hco -n openshift-cnv kubevirt-hyperconverged

# Operator 로그 확인
oc logs -n openshift-cnv deployment/hco-operator

# 개별 컴포넌트 상태 확인
oc get kubevirt,cdi,networkaddonsconfig,ssp -n openshift-cnv

# 노드 가상화 미지원 시
oc get nodes -l kubevirt.io/schedulable=true
```
