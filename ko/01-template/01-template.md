# POC용 커스텀 VM 이미지 생성 가이드

OpenShift Virtualization POC 테스트에 사용할 RHEL9 기반 커스텀 VM 이미지를 준비합니다.
RHEL9 VM을 생성하고, subscription을 등록하고, httpd를 설치한 다음 PVC를 qcow2로 내보내어
`openshift-virtualization-os-images` namespace에 golden image로 등록합니다.

```
RHEL9 base image (OCP 기본 제공)
        │  VM 생성 (rhel9-vm)
        ▼
subscription-manager 등록 + httpd 설치
        │  VM 종료
        ▼
PVC → qcow2 (virtctl vmexport)
        │  virtctl image-upload
        ▼
PVC: rhel9-poc-golden  (openshift-virtualization-os-images)
        │  DataSource 등록
        ▼
DataSource: rhel9-poc-golden  → 클러스터 전체에서 VM 생성 가능
```

---

## 단계 1: RHEL9 VM 생성

OpenShift Virtualization UI 또는 CLI를 사용하여 RHEL9 VM을 생성합니다.

### CLI를 통한 생성

```bash
# poc-vm-build namespace 생성
oc new-project poc-vm-build

# RHEL9 기본 템플릿을 사용하여 VM 생성 (기존 RHEL9 템플릿 활용)
oc process -n openshift rhel9-server-small \
  -p NAME=rhel9-vm \
  -p NAMESPACE=poc-vm-build | oc apply -f -
```

### VM 시작 및 접속

```bash
# VM 시작
virtctl start rhel9-vm -n poc-vm-build

# VM이 Running 상태가 될 때까지 대기
oc wait vm/rhel9-vm -n poc-vm-build \
  --for=jsonpath='{.status.printableStatus}'=Running --timeout=300s

# VNC 콘솔 접속
virtctl vnc rhel9-vm -n poc-vm-build

# 또는 SSH (cloud-init으로 SSH 키를 주입한 경우)
virtctl ssh cloud-user@rhel9-vm -n poc-vm-build
```

---

## 단계 2: RHEL Subscription 등록

VM 콘솔 또는 SSH로 접속하여 Red Hat subscription을 등록합니다.

```bash
# Subscription 등록 (Red Hat 계정 사용)
subscription-manager register \
  --username <username> \
  --password <password> \
  --auto-attach

# 등록 확인
subscription-manager status
subscription-manager list --installed
```

---

## 단계 3: httpd 설치 및 POC 웹 서버 구성

VM 내부에서 다음 스크립트를 실행합니다.

```bash
#!/bin/bash

# 1. 필수 패키지 설치 (httpd, firewalld, tar, wget)
echo ">>> [1/5] Installing base packages..."
dnf install -y httpd firewalld tar wget bash-completion

# 2. BMT 웹 서버 구성 (index.html)
echo ">>> [4/5] Creating BMT information page..."
cat <<EOF > /var/www/html/index.html
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>OpenShift BMT</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; text-align: center; margin-top: 80px; background-color: #f0f2f5; }
        .card { background: white; border-top: 8px solid #ee0000; display: inline-block; padding: 40px; border-radius: 12px; box-shadow: 0 10px 30px rgba(0,0,0,0.1); }
        h1 { color: #ee0000; margin-bottom: 5px; font-size: 2.2em; }
        h2 { color: #333; font-weight: 400; margin-top: 15px; border-top: 1px solid #eee; padding-top: 15px; }
        .info { margin-top: 20px; font-size: 0.9em; color: #666; }
    </style>
</head>
<body>
    <div class="card">
        <h1>OpenShift Virtualization PoC/BMT Test</h1>
        <h2>Node Hostname: $(hostname)</h2>
        <div class="info">CLI Tools Installed: oc, kubectl, virtctl</div>
    </div>
</body>
</html>
EOF

# 3. 서비스 활성화 및 방화벽 설정
echo ">>> [5/5] Enabling services and configuring firewall..."
systemctl enable --now httpd firewalld
firewall-cmd --permanent --add-service=http
firewall-cmd --reload

echo "------------------------------------------------"
echo "✅ All configuration is complete!"
echo "1. Web access: http://$(hostname -I | awk '{print $1}')"
echo "2. oc version: $(oc version --client)"
echo "3. virtctl version: $(virtctl version --client | grep Client)"
echo "------------------------------------------------"
```

설치 확인:

```bash
# httpd 서비스 상태
systemctl status httpd

# 웹 서버 응답 확인
curl http://localhost
```

---

## 단계 4: VM 종료

이미지 추출 전 VM을 완전히 종료합니다.

```bash
# VM 내부에서 종료
sudo shutdown -h now
```

또는 외부에서:

```bash
virtctl stop rhel9-vm -n poc-vm-build

# 완전히 중지될 때까지 대기
oc wait vm/rhel9-vm -n poc-vm-build \
  --for=jsonpath='{.status.printableStatus}'=Stopped --timeout=120s
```

---

## 단계 5: PVC를 qcow2로 내보내기

VM의 root disk PVC를 로컬 qcow2 파일로 내보냅니다.

```bash
# PVC 이름 확인
oc get pvc -n poc-vm-build

# VMExport 생성
virtctl vmexport create rhel9-poc-export \
  --pvc=<rhel9-vm의 rootdisk PVC 이름> \
  -n poc-vm-build

# Ready 상태 확인
oc get vmexport rhel9-poc-export -n poc-vm-build

# qcow2 다운로드
virtctl vmexport download rhel9-poc-export \
  --output=./vm-images/rhel9-poc-export.qcow2 \
  -n poc-vm-build

# VMExport 정리
virtctl vmexport delete rhel9-poc-export -n poc-vm-build
```

> **상세 가이드**: VM export 워크플로우에 대해서는 OpenShift 문서를 참고하세요

---

## 단계 6: Golden Image로 등록

추출한 qcow2를 `openshift-virtualization-os-images` namespace에 업로드하고 DataSource와 Template을 등록합니다.

```bash
# env.conf 로드 (StorageClass 등 변수 사용)
source env.conf
```

### 6-1. DataVolume 업로드

```bash
virtctl image-upload dv poc-golden \
  --image-path=vm-images/rhel9-poc-golden.qcow2 \
  --size=30Gi \
  --storage-class=${STORAGE_CLASS} \
  --access-mode=ReadWriteMany \
  --volume-mode=block \
  -n openshift-virtualization-os-images \
  --insecure \
  --force-bind
```

> StorageClass가 `ReadWriteMany`를 지원하지 않는 경우 `--access-mode=ReadWriteOnce`로 변경하세요

업로드 완료 확인:

```bash
oc get dv poc-golden -n openshift-virtualization-os-images
oc get pvc poc-golden -n openshift-virtualization-os-images
```

### 6-2. DataSource 등록

```bash
cat <<'EOF' | oc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: poc
  namespace: openshift-virtualization-os-images
spec:
  source:
    pvc:
      name: poc-golden
      namespace: openshift-virtualization-os-images
EOF

# 등록 확인
oc get datasource poc -n openshift-virtualization-os-images
```

### 6-3. VM Template 등록

> **중요:** 모든 namespace에서 Template을 사용하려면 **`openshift` 프로젝트**에 생성해야 합니다.
> 다른 namespace에 생성하면 해당 namespace에서만 사용할 수 있습니다.

```bash
cat <<'EOF' | oc apply -f -
apiVersion: template.openshift.io/v1
kind: Template
metadata:
  name: poc
  namespace: openshift
  labels:
    app.kubernetes.io/part-of: hyperconverged-cluster
    flavor.template.kubevirt.io/small: 'true'
    template.kubevirt.io/version: v0.31.1
    template.kubevirt.io/type: vm
    vm.kubevirt.io/template: rhel9-server-small
    app.kubernetes.io/component: templating
    app.kubernetes.io/managed-by: ssp-operator
    os.template.kubevirt.io/rhel9.0: 'true'
    os.template.kubevirt.io/rhel9.1: 'true'
    os.template.kubevirt.io/rhel9.2: 'true'
    os.template.kubevirt.io/rhel9.3: 'true'
    os.template.kubevirt.io/rhel9.4: 'true'
    os.template.kubevirt.io/rhel9.5: 'true'
    vm.kubevirt.io/template.namespace: openshift
    app.kubernetes.io/name: custom-templates
    workload.template.kubevirt.io/server: 'true'
  annotations:
    openshift.io/display-name: POC VM
    description: Template for Red Hat Enterprise Linux 9 VM or newer. A PVC with the RHEL disk image must be available.
    tags: 'hidden,kubevirt,virtualmachine,linux,rhel'
    iconClass: icon-rhel
    template.kubevirt.io/version: v1alpha1
    defaults.template.kubevirt.io/disk: rootdisk
    template.openshift.io/bindable: 'false'
    openshift.kubevirt.io/pronounceable-suffix-for-name-expression: 'true'
    name.os.template.kubevirt.io/rhel9.0: Red Hat Enterprise Linux 9.0 or higher
    name.os.template.kubevirt.io/rhel9.1: Red Hat Enterprise Linux 9.0 or higher
    name.os.template.kubevirt.io/rhel9.2: Red Hat Enterprise Linux 9.0 or higher
    name.os.template.kubevirt.io/rhel9.3: Red Hat Enterprise Linux 9.0 or higher
    name.os.template.kubevirt.io/rhel9.4: Red Hat Enterprise Linux 9.0 or higher
    name.os.template.kubevirt.io/rhel9.5: Red Hat Enterprise Linux 9.0 or higher
objects:
  - apiVersion: kubevirt.io/v1
    kind: VirtualMachine
    metadata:
      annotations:
        vm.kubevirt.io/validations: |
          [
            {
              "name": "minimal-required-memory",
              "path": "jsonpath::.spec.domain.memory.guest",
              "rule": "integer",
              "message": "This VM requires more memory.",
              "min": 1610612736
            }
          ]
      labels:
        app: '${NAME}'
        kubevirt.io/dynamic-credentials-support: 'true'
        vm.kubevirt.io/template: poc
        vm.kubevirt.io/template.revision: '1'
        vm.kubevirt.io/template.namespace: openshift
      name: '${NAME}'
    spec:
      dataVolumeTemplates:
        - apiVersion: cdi.kubevirt.io/v1beta1
          kind: DataVolume
          metadata:
            name: '${NAME}'
          spec:
            sourceRef:
              kind: DataSource
              name: '${DATA_SOURCE_NAME}'
              namespace: '${DATA_SOURCE_NAMESPACE}'
            storage:
              storageClassName: ${STORAGE_CLASS}
              resources:
                requests:
                  storage: 30Gi
      runStrategy: Halted
      template:
        metadata:
          annotations:
            vm.kubevirt.io/flavor: small
            vm.kubevirt.io/os: rhel9
            vm.kubevirt.io/workload: server
          labels:
            kubevirt.io/domain: '${NAME}'
            kubevirt.io/size: small
        spec:
          architecture: amd64
          domain:
            cpu:
              cores: 1
              sockets: 1
              threads: 1
            devices:
              disks:
                - disk:
                    bus: virtio
                  name: rootdisk
                - disk:
                    bus: virtio
                  name: cloudinitdisk
              interfaces:
                - masquerade: {}
                  model: virtio
                  name: default
              rng: {}
            features:
              smm:
                enabled: true
            firmware:
              bootloader:
                efi: {}
            memory:
              guest: 2Gi
          networks:
            - name: default
              pod: {}
          terminationGracePeriodSeconds: 180
          volumes:
            - dataVolume:
                name: '${NAME}'
              name: rootdisk
            - cloudInitNoCloud:
                userData: |-
                  #cloud-config
                  user: cloud-user
                  password: ${CLOUD_USER_PASSWORD}
                  chpasswd: { expire: False }
              name: cloudinitdisk
parameters:
  - name: NAME
    description: VM name
    generate: expression
    from: 'poc-[a-z0-9]{16}'
  - name: DATA_SOURCE_NAME
    description: Name of the DataSource to clone
    value: poc
  - name: DATA_SOURCE_NAMESPACE
    description: Namespace of the DataSource
    value: openshift-virtualization-os-images
  - name: CLOUD_USER_PASSWORD
    description: Randomized password for the cloud-init user cloud-user
    generate: expression
    from: '[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}'
EOF

# 등록 확인
oc get template poc -n openshift
```

### 6-4. Template에서 VM 생성 확인

```bash
# Template 파라미터 확인
oc process --parameters -n openshift poc

# VM 생성 테스트
oc process -n openshift poc | oc apply -n poc-test -f -
```

---

## Console에서 기존 VM 이미지로 새 Template 만들기

Console UI에서 기존 VM으로부터 커스텀 Template을 만드는 가장 쉬운 방법은 **기존 Template을 복제하여 수정**하는 것입니다.

1. **Virtualization → Templates**로 이동합니다
2. 기반으로 할 Template(예: `rhel9-server-small`)의 우측 메뉴에서 **Clone**을 클릭합니다
3. 복제 이름을 입력하고 namespace를 **`openshift`**로 설정 → **Clone** 클릭
4. 복제된 Template을 편집합니다:
   - **Boot source** → DataSource를 `poc` (`openshift-virtualization-os-images`)로 변경
   - CPU/Memory 기본값 조정
   - Display name 및 description 편집
5. **Save**

> Console에서 복제한 Template은 즉시 **Virtualization → Catalog**에서 모든 프로젝트에 대해 표시됩니다.

---

## 참고

- `virtctl` 설치: OpenShift Console > `?` 메뉴 > **Command line tools**에서 다운로드
- 전체 자동화 스크립트: [`01-template.sh`](01-template.sh) -- 업로드, DataSource, Template을 한 번에 실행
- StorageClass 확인: `oc get storageclass`

---
