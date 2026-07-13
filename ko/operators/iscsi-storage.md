# OpenShift Virtualization을 위한 iSCSI 스토리지 구성

iSCSI 스토리지를 OpenShift Virtualization에서 사용하기 위한 설정 가이드입니다.

```
iSCSI Target (스토리지 서버)
  │
  ├─ LUN 1 → PV → PVC → VM 디스크
  ├─ LUN 2 → PV → PVC → VM 디스크
  └─ LUN 3 → PV → PVC → DataVolume
```

---

## 사전 요구 사항

- Worker 노드가 포함된 OpenShift 클러스터
- iSCSI target 서버 구성 및 접근 가능
- Worker 노드에 iSCSI initiator 패키지 설치
- Worker 노드와 iSCSI target 간 네트워크 연결

---

## 아키텍처 개요

| 컴포넌트 | 역할 |
|-----------|------|
| **iSCSI Target** | LUN을 제공하는 스토리지 서버 |
| **iSCSI Initiator** | Worker 노드 (MachineConfig으로 구성) |
| **PersistentVolume (PV)** | iSCSI LUN에 대한 Kubernetes 추상화 |
| **PersistentVolumeClaim (PVC)** | 스토리지에 대한 사용자 요청 |
| **StorageClass** | 동적 프로비저닝 (선택 사항) |

---

## 1. Worker 노드에 iSCSI Initiator 구성

### 방법 A: MachineConfig 사용 (권장)

iSCSI initiator를 모든 worker 노드에 자동으로 설정합니다.

```bash
# Worker 노드의 machine config pool 확인
oc get mcp

# iSCSI initiator용 MachineConfig 생성
cat <<EOF | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-worker-iscsi-initiator
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
        - name: iscsid.service
          enabled: true
        - name: iscsi.service
          enabled: true
    storage:
      files:
        - path: /etc/iscsi/initiatorname.iscsi
          mode: 0644
          overwrite: true
          contents:
            source: data:text/plain;charset=utf-8;base64,$(echo "InitiatorName=iqn.$(date +%Y-%m).com.example:node01" | base64 -w0)
EOF
```

**참고**: 각 노드는 고유한 IQN이 필요합니다. 프로덕션 환경에서는 노드별로 다른 IQN을 설정해야 합니다.

### 방법 B: 수동 구성 (테스트용)

특정 노드에서 테스트용으로 수동 설정:

```bash
# Worker 노드에 SSH 접속 (접근 가능한 경우)
ssh core@worker-0

# iSCSI 패키지 설치 (아직 설치되지 않은 경우)
sudo rpm-ostree install iscsi-initiator-utils
sudo systemctl reboot

# 재부팅 후 initiator 이름 확인
sudo cat /etc/iscsi/initiatorname.iscsi

# iSCSI 서비스 시작
sudo systemctl enable iscsid iscsi --now
sudo systemctl status iscsid
```

### iSCSI Initiator 확인

```bash
# MachineConfig 상태 확인
oc get mcp worker

# 노드에서 확인
oc debug node/worker-0
chroot /host
systemctl status iscsid
cat /etc/iscsi/initiatorname.iscsi
exit
```

---

## 2. iSCSI Target 검색 및 로그인

### Target 검색

```bash
# Worker 노드 또는 debug Pod에서
ISCSI_TARGET_IP="192.168.1.100"
ISCSI_TARGET_PORT="3260"

# 사용 가능한 target 검색
iscsiadm -m discovery -t st -p ${ISCSI_TARGET_IP}:${ISCSI_TARGET_PORT}

# 출력 예시:
# 192.168.1.100:3260,1 iqn.2024-01.com.example:storage.target01
```

### Target 로그인

```bash
# 검색된 target에 로그인
TARGET_IQN="iqn.2024-01.com.example:storage.target01"

iscsiadm -m node -T ${TARGET_IQN} -p ${ISCSI_TARGET_IP}:${ISCSI_TARGET_PORT} --login

# 연결 확인
iscsiadm -m session

# 검색된 디바이스 목록
lsblk | grep sd
```

### 자동 로그인 구성 (선택 사항)

```bash
# 부팅 시 자동 로그인 설정
iscsiadm -m node -T ${TARGET_IQN} -p ${ISCSI_TARGET_IP}:${ISCSI_TARGET_PORT} --op update -n node.startup -v automatic

# 확인
iscsiadm -m node -T ${TARGET_IQN} -p ${ISCSI_TARGET_IP}:${ISCSI_TARGET_PORT}
```

---

## 3. iSCSI LUN용 PersistentVolume 생성

### 정적 프로비저닝

각 iSCSI LUN에 대해 PV를 생성합니다.

```bash
# LUN 정보 확인
iscsiadm -m session -P 3 | grep -E "Target:|Lun:|Attached scsi disk"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: iscsi-pv-01
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: iscsi-storage
  iscsi:
    targetPortal: 192.168.1.100:3260
    iqn: iqn.2024-01.com.example:storage.target01
    lun: 0
    fsType: ext4
    readOnly: false
    chapAuthDiscovery: false
    chapAuthSession: false
EOF
```

### CHAP 인증 사용

CHAP 인증을 사용하는 경우:

```bash
# CHAP 자격 증명용 Secret 생성
oc create secret generic iscsi-chap-secret \
  -n default \
  --from-literal=node.session.auth.username=chapuser \
  --from-literal=node.session.auth.password=chappassword

# CHAP을 사용하는 PV
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: iscsi-pv-chap-01
spec:
  capacity:
    storage: 50Gi
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: iscsi-storage
  iscsi:
    targetPortal: 192.168.1.100:3260
    iqn: iqn.2024-01.com.example:storage.target01
    lun: 1
    fsType: ext4
    readOnly: false
    chapAuthSession: true
    secretRef:
      name: iscsi-chap-secret
EOF
```

---

## 4. StorageClass 생성 (선택 사항)

동적 프로비저닝을 위한 StorageClass (CSI driver 필요):

```bash
cat <<EOF | oc apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: iscsi-storage
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
EOF
```

**참고**: 표준 iSCSI는 동적 프로비저닝을 지원하지 않습니다. CSI driver가 필요합니다.

---

## 5. PVC 생성 및 VM에서 사용

### PVC 생성

```bash
cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: iscsi-pvc-01
  namespace: default
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: iscsi-storage
  resources:
    requests:
      storage: 50Gi
  volumeName: iscsi-pv-01
EOF

# PVC 바인딩 확인
oc get pvc iscsi-pvc-01
```

### VM에서 PVC 사용

```bash
cat <<EOF | oc apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm-iscsi-disk
  namespace: default
spec:
  running: true
  template:
    metadata:
      labels:
        kubevirt.io/vm: vm-iscsi-disk
    spec:
      domain:
        devices:
          disks:
            - name: root-disk
              disk:
                bus: virtio
            - name: iscsi-disk
              disk:
                bus: virtio
          interfaces:
            - name: default
              masquerade: {}
        resources:
          requests:
            memory: 2Gi
            cpu: 1
      networks:
        - name: default
          pod: {}
      volumes:
        - name: root-disk
          containerDisk:
            image: registry.redhat.io/rhel9/rhel-guest-image:latest
        - name: iscsi-disk
          persistentVolumeClaim:
            claimName: iscsi-pvc-01
EOF
```

---

## 6. Multipath 구성 (프로덕션)

프로덕션 환경에서 고가용성을 위한 multipath 설정:

```bash
cat <<EOF | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: worker
  name: 99-worker-multipath
spec:
  config:
    ignition:
      version: 3.2.0
    systemd:
      units:
        - name: multipathd.service
          enabled: true
    storage:
      files:
        - path: /etc/multipath.conf
          mode: 0644
          overwrite: true
          contents:
            inline: |
              defaults {
                user_friendly_names yes
                find_multipaths yes
              }
              blacklist {
                devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
                devnode "^hd[a-z]"
              }
EOF
```

---

## 7. 확인 및 테스트

### PV/PVC 상태 확인

```bash
# 모든 PV 목록
oc get pv

# 특정 PV 상세 정보 확인
oc describe pv iscsi-pv-01

# PVC 목록
oc get pvc -A

# PVC 바인딩 확인
oc describe pvc iscsi-pvc-01 -n default
```

### iSCSI 세션 확인

```bash
# Worker 노드에서
oc debug node/worker-0
chroot /host

# 활성 세션 확인
iscsiadm -m session

# 세션 상세 정보 확인
iscsiadm -m session -P 3

# 연결된 디스크 목록
lsblk | grep sd
```

### iSCSI 디스크가 연결된 VM 테스트

```bash
# VM 상태 확인
oc get vm,vmi vm-iscsi-disk

# VM 콘솔 접속
virtctl console vm-iscsi-disk

# VM 내부에서 디스크 확인
lsblk
fdisk -l

# 파일시스템 생성 및 마운트 (필요한 경우)
sudo mkfs.ext4 /dev/vdb
sudo mkdir /mnt/iscsi-disk
sudo mount /dev/vdb /mnt/iscsi-disk
df -h
```

---

## 8. 문제 해결

### iSCSI 서비스가 실행되지 않는 경우

```bash
# 서비스 상태 확인
systemctl status iscsid
systemctl status iscsi

# 서비스 재시작
systemctl restart iscsid iscsi

# 로그 확인
journalctl -u iscsid -f
```

### 검색 실패

```bash
# 네트워크 연결 테스트
ping 192.168.1.100

# 포트 연결 테스트
nc -zv 192.168.1.100 3260

# 방화벽 확인
firewall-cmd --list-all

# 수동 검색
iscsiadm -m discovery -t st -p 192.168.1.100:3260 -d 8
```

### 로그인 실패

```bash
# 스토리지 서버에서 target 상태 확인
targetcli ls

# ACL 권한 확인
# Target 서버에서 initiator IQN을 허용해야 함

# 디버그 모드로 수동 로그인 시도
iscsiadm -m node -T <IQN> -p <IP>:3260 --login -d 8

# 인증 확인
iscsiadm -m node -T <IQN> -p <IP>:3260
```

### PV가 바인딩되지 않는 경우

```bash
# PV 상태 확인
oc get pv iscsi-pv-01 -o yaml

# 이벤트 확인
oc get events -n default --sort-by='.lastTimestamp'

# LUN 접근 가능 여부 확인
# Worker 노드에서:
iscsiadm -m session -P 3 | grep -A5 "Lun: 0"
```

### VM에서 iSCSI 디스크를 사용할 수 없는 경우

```bash
# PVC 상태 확인
oc get pvc iscsi-pvc-01 -o yaml

# VM 이벤트 확인
oc describe vm vm-iscsi-disk

# virt-launcher Pod 확인
oc get pods -l kubevirt.io/vm=vm-iscsi-disk
oc logs <virt-launcher-pod>

# 디스크 연결 확인
oc get vmi vm-iscsi-disk -o yaml | grep -A10 volumes
```

---

## 9. 모범 사례

### 보안

1. 프로덕션 환경에서는 **CHAP 인증 사용**
2. Target에서 특정 initiator IQN으로 **ACL 제한**
3. iSCSI 트래픽에 **전용 네트워크(VLAN) 사용**
4. 접근 제한을 위한 **방화벽 규칙 활성화**

### 성능

1. iSCSI 네트워크에 **점보 프레임(MTU 9000) 사용**
2. 이중화를 위한 **multipath 구성**
3. iSCSI 트래픽에 **별도 NIC 사용**
4. **디스크 I/O 성능 모니터링**

### 가용성

1. 다중 경로로 **multipath 구성**
2. 이중화를 위한 **다중 target 사용**
3. LUN 데이터 **정기 백업**
4. **Target 상태 모니터링**

---

## 10. 정리

### VM 및 PVC 삭제

```bash
oc delete vm vm-iscsi-disk
oc delete pvc iscsi-pvc-01
```

### PV 삭제

```bash
oc delete pv iscsi-pv-01
```

### iSCSI Target 로그아웃

```bash
# Worker 노드에서
iscsiadm -m node -T <IQN> -p <IP>:3260 --logout

# 저장된 target 삭제
iscsiadm -m node -T <IQN> -p <IP>:3260 -o delete
```

### MachineConfig 삭제 (선택 사항)

```bash
oc delete mc 99-worker-iscsi-initiator
oc delete mc 99-worker-multipath
```

---

## 참고 자료

- [OpenShift Virtualization 문서](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/virtualization/index)
- [Kubernetes iSCSI Persistent Volumes](https://kubernetes.io/docs/concepts/storage/volumes/#iscsi)
- [iSCSI Target 구성](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/managing_storage_devices/getting-started-with-iscsi_managing-storage-devices)
