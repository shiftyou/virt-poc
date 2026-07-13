# Migration Toolkit for Virtualization (MTV) Operator 설치

## 개요

MTV (Migration Toolkit for Virtualization)는 VMware vSphere, Red Hat Virtualization (RHV),
OpenStack 등의 환경에서 OpenShift Virtualization으로 VM을 마이그레이션하는 Operator입니다.
콜드 마이그레이션과 웜 마이그레이션을 지원하며, Console UI에서 마이그레이션 계획을 생성하고 실행할 수 있습니다.

```
VMware vSphere / RHV / OpenStack
        │  MTV 마이그레이션
        ▼
OpenShift Virtualization (KubeVirt)
```

---

## 사전 요구 사항

- cluster-admin 권한
- OpenShift Virtualization Operator 설치 완료 (`openshift-virtualization-operator.md` 참조)
- VMware 마이그레이션 시: VDDK (Virtual Disk Development Kit) 이미지 준비

---

## 설치 방법

### 방법 1: OpenShift Console (Web UI)

1. **Operators > OperatorHub** 메뉴로 이동
2. `Migration Toolkit for Virtualization` 검색
3. **Migration Toolkit for Virtualization** 선택
4. `Install` 클릭
5. 설정:
   - Update channel: `release-v2.7` (최신 채널 선택)
   - Installation mode: `All namespaces on the cluster`
   - Installed Namespace: `openshift-mtv`
6. `Install` 클릭 후 완료 대기
7. 설치 완료 후, **ForkliftController 인스턴스 생성**:
   - Operators > Installed Operators > Migration Toolkit for Virtualization
   - **ForkliftController** 탭 > `Create ForkliftController` 클릭
   - 기본값으로 생성

### 방법 2: CLI (YAML)

```bash
# 1. Namespace 생성
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-mtv
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# 2. OperatorGroup 생성
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: migration
  namespace: openshift-mtv
spec:
  targetNamespaces:
    - openshift-mtv
EOF

# 3. Subscription 생성
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: mtv-operator
  namespace: openshift-mtv
spec:
  channel: release-v2.7
  name: mtv-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# 4. Operator 설치 완료 대기
oc wait csv -n openshift-mtv \
  -l operators.coreos.com/mtv-operator.openshift-mtv \
  --for=jsonpath='{.status.phase}'=Succeeded \
  --timeout=5m

# 5. ForkliftController 인스턴스 생성
oc apply -f - <<'EOF'
apiVersion: forklift.konveyor.io/v1beta1
kind: ForkliftController
metadata:
  name: forklift-controller
  namespace: openshift-mtv
spec:
  olm_managed: true
EOF
```

---

## 설치 확인

```bash
# Operator 설치 상태 확인
oc get csv -n openshift-mtv | grep mtv

# ForkliftController 상태 확인
oc get forkliftcontroller -n openshift-mtv

# 모든 Pod 상태 확인
oc get pods -n openshift-mtv

# MTV Console plugin 활성화 확인
oc get consolePlugin forklift-console-plugin
```

---

## VMware 마이그레이션 준비 (VDDK)

VMware에서 마이그레이션할 때 VDDK 이미지가 필요합니다.

```bash
# 1. VMware 사이트에서 VDDK 다운로드
#    https://developer.vmware.com/web/sdk/8.0/vddk

# 2. VDDK 이미지 빌드 후 내부 레지스트리에 Push
# Dockerfile 예시:
cat > Dockerfile.vddk <<'EOF'
FROM registry.access.redhat.com/ubi8/ubi-minimal
COPY vmware-vix-disklib-distrib /vmware-vix-disklib-distrib
RUN mkdir -p /opt
ENTRYPOINT ["cp", "-r", "/vmware-vix-disklib-distrib", "/opt"]
EOF

# 3. 빌드 및 Push
VDDK_IMAGE="image-registry.openshift-image-registry.svc:5000/openshift/vddk:latest"
podman build -f Dockerfile.vddk -t ${VDDK_IMAGE} .
podman push ${VDDK_IMAGE}

# 4. MTV에 VDDK 이미지 등록
oc patch forkliftcontroller forklift-controller -n openshift-mtv \
  --type=merge \
  -p "{\"spec\":{\"vddk_job_image\":\"${VDDK_IMAGE}\"}}"
```

---

## 마이그레이션 절차 개요

```bash
# 1. Provider 등록 (VMware vCenter)
#    Migration > Providers > Add Provider

# 2. 네트워크 매핑 생성
#    Migration > NetworkMaps > Create NetworkMap

# 3. 스토리지 매핑 생성
#    Migration > StorageMaps > Create StorageMap

# 4. 마이그레이션 계획 생성 및 실행
#    Migration > Plans > Create Plan

# Provider 목록 확인
oc get providers -n openshift-mtv

# 마이그레이션 계획 상태 확인
oc get migrationplans -n openshift-mtv

# VM 마이그레이션 상태 확인
oc get migrations -n openshift-mtv
```

---

## 문제 해결

```bash
# ForkliftController 이벤트 확인
oc describe forkliftcontroller -n openshift-mtv forklift-controller

# Operator 로그 확인
oc logs -n openshift-mtv deployment/forklift-operator

# 개별 컴포넌트 로그
oc logs -n openshift-mtv deployment/forklift-controller
oc logs -n openshift-mtv deployment/forklift-api

# VMware Provider 연결 상태 확인
oc get providers -n openshift-mtv
oc describe provider <provider-name> -n openshift-mtv
```
