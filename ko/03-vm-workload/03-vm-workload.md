# VM Workload

poc Template과 bridge network 및 cloud-init 고정 IP를 사용하여 `poc-vm` namespace에 VM을 배포하는 방법을 설명합니다.

```
poc Template (openshift namespace)
        │  oc process → VirtualMachine 생성
        ▼
VirtualMachine (poc-vm)
        │
        ├─ rootdisk (DataVolume ← poc DataSource clone)
        ├─ 추가 디스크 (PVC)
        │
        ├─ eth0 (Pod Network — masquerade)
        └─ eth1 (poc-bridge-nad → Linux Bridge → 물리 네트워크)
```

---

## 사전 요구사항

- `01-template` 완료 — `poc` Template 및 DataSource 등록됨
- `02-network` 완료 — NNCP / NAD 구성됨
- `03-vm-workload.sh` 완료 — `poc-vm` namespace 및 NAD 등록됨

```bash
# 사전 요구사항 확인
oc get template poc -n openshift
oc get datasource poc -n openshift-virtualization-os-images
oc get nncp poc-bridge-nncp
oc get net-attach-def poc-bridge-nad -n poc-vm
```

---

## 1. VM 생성 (poc Template 사용)

`poc` Template을 처리하여 VirtualMachine 오브젝트를 생성합니다.

```bash
# 기본 생성 (자동 생성 이름)
oc process -n openshift poc | oc apply -n poc-vm -f -

# VM 이름 지정
oc process -n openshift poc \
  -p NAME=my-poc-vm \
  | oc apply -n poc-vm -f -

# VM 시작
virtctl start my-poc-vm -n poc-vm
```

### VM 상태 확인

```bash
# VM 목록
oc get vm -n poc-vm

# VM 상세 정보 (Phase 확인)
oc get vmi -n poc-vm

# Pod 확인
oc get pods -n poc-vm

# 콘솔 접속
virtctl console my-poc-vm -n poc-vm

# VNC 접속
virtctl vnc my-poc-vm -n poc-vm
```

---

## 2. 스토리지 추가

실행 중인 VM에 데이터 디스크를 Hot-plug합니다.

### PVC 생성 후 Hot-plug

```bash
# 데이터용 PVC 생성
oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: my-poc-vm-data
  namespace: poc-vm
spec:
  accessModes:
    - ReadWriteMany
  volumeMode: Block
  resources:
    requests:
      storage: 10Gi
  storageClassName: ocs-external-storagecluster-ceph-rbd
EOF

# 실행 중인 VM에 디스크 Hot-plug
virtctl addvolume my-poc-vm \
  --volume-name=my-poc-vm-data \
  --disk-type=disk \
  -n poc-vm
```

### VM 중지 후 디스크 추가 (영구 연결)

```bash
# VM spec에 디스크 직접 추가
oc patch vm my-poc-vm -n poc-vm --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/domain/devices/disks/-",
    "value": {"name": "datadisk", "disk": {"bus": "virtio"}}
  },
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "datadisk",
      "persistentVolumeClaim": {"claimName": "my-poc-vm-data"}
    }
  }
]'
```

### 검증

```bash
# VM 내부에서 디스크 확인
virtctl console my-poc-vm -n poc-vm
# lsblk
# fdisk -l
```

---

## 3. 네트워크 추가 (보조 NIC)

`poc-bridge-nad`를 VM의 보조 네트워크로 연결합니다.

> VM이 실행 중인 경우, 변경 전에 먼저 중지하세요.

```bash
# VM 중지
virtctl stop my-poc-vm -n poc-vm

# 보조 NIC 추가
oc patch vm my-poc-vm -n poc-vm --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/domain/devices/interfaces/-",
    "value": {"name": "bridge-net", "bridge": {}, "model": "virtio"}
  },
  {
    "op": "add",
    "path": "/spec/template/spec/networks/-",
    "value": {
      "name": "bridge-net",
      "multus": {"networkName": "poc-bridge-nad"}
    }
  }
]'

# VM 시작
virtctl start my-poc-vm -n poc-vm
```

### 검증

```bash
# VMI에서 NIC 확인
oc get vmi my-poc-vm -n poc-vm \
  -o jsonpath='{range .status.interfaces[*]}{.name}: {.ipAddress}{"\n"}{end}'
```

---

## 4. 고정 IP / 도메인 / 라우터 설정

보조 NIC(`eth1`)에 고정 IP를 설정합니다.
초기 설정 시 cloud-init으로 구성하거나, VM 내부에서 직접 설정합니다.

> `03-vm-workload.sh`로 생성한 ConsoleYAMLSample VM에는 이미 cloud-init networkData가 포함되어 있습니다.

### 방법 A — cloud-init networkData를 통한 초기 설정

VM 생성 시 기존 `cloudinitdisk` 볼륨에 `networkData`를 추가합니다.
**VM 부팅 전에** 적용해야 하므로, `runStrategy: Halted` 상태에서 패치한 후 시작합니다.

```bash
# VM 생성 (Halted 상태)
oc process -n openshift poc \
  -p NAME=my-poc-vm \
  | sed 's/  running: false/  runStrategy: Halted/' \
  | oc apply -n poc-vm -f -

# cloudinitdisk 볼륨 인덱스 확인 (grep -n은 1부터 시작 → 0부터 시작으로 변환)
CI_IDX=$(oc get vm my-poc-vm -n poc-vm \
  -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' | \
  grep -n "cloudinitdisk" | cut -d: -f1 | head -1)
CI_IDX=$(( CI_IDX - 1 ))

# 기존 cloudinitdisk에 networkData 추가 (VM 시작 전)
oc patch vm my-poc-vm -n poc-vm --type=json -p="[
  {\"op\": \"add\",
   \"path\": \"/spec/template/spec/volumes/${CI_IDX}/cloudInitNoCloud/networkData\",
   \"value\": \"version: 2\nethernets:\n  eth1:\n    dhcp4: false\n    addresses:\n      - 192.168.100.10/24\n    gateway4: 192.168.100.1\n    nameservers:\n      addresses:\n        - 8.8.8.8\n\"}
]"

# VM 시작
virtctl start my-poc-vm -n poc-vm
```

결과적으로 `cloudinitdisk` 볼륨은 다음과 같이 구성됩니다:

```yaml
- name: cloudinitdisk
  cloudInitNoCloud:
    userData: |-
      #cloud-config
      user: cloud-user
      password: changeme
      chpasswd: { expire: False }
    networkData: |
      version: 2
      ethernets:
        eth1:
          dhcp4: false
          addresses:
            - 192.168.100.10/24
          gateway4: 192.168.100.1
          nameservers:
            addresses:
              - 8.8.8.8
```

### 방법 B — VM 내부에서 nmcli로 설정

VM 콘솔에 접속하여 직접 설정합니다.

```bash
virtctl console my-poc-vm -n poc-vm
```

VM 내부에서:

```bash
# 보조 NIC 이름 확인 (eth1 또는 ens3 등)
ip link show

# 고정 IP 설정
nmcli con add type ethernet ifname eth1 con-name eth1-static \
  ip4 192.168.100.10/24 gw4 192.168.100.1

# DNS 설정
nmcli con mod eth1-static ipv4.dns "8.8.8.8 8.8.4.4"
nmcli con mod eth1-static ipv4.dns-search "poc.example.com"

# 활성화
nmcli con up eth1-static

# 호스트명 설정
hostnamectl set-hostname my-poc-vm.poc.example.com

# 확인
ip addr show eth1
ip route
cat /etc/resolv.conf
```

### 라우터(게이트웨이) 설정

```bash
# 특정 서브넷을 보조 NIC를 통해 라우팅
ip route add 10.0.0.0/8 via 192.168.100.1 dev eth1

# 영구 설정 (nmcli)
nmcli con mod eth1-static +ipv4.routes "10.0.0.0/8 192.168.100.1"
nmcli con up eth1-static
```

---

## 5. 라이브 마이그레이션

중단 없이 VM을 다른 노드로 이동합니다.

### 사전 요구사항 확인

```bash
# VM이 실행 중인 현재 노드 확인
oc get vmi my-poc-vm -n poc-vm \
  -o jsonpath='{.status.nodeName}{"\n"}'

# 스토리지 ReadWriteMany 확인 (라이브 마이그레이션에 필요)
oc get pvc -n poc-vm
```

### 라이브 마이그레이션 실행

```bash
# virtctl로 마이그레이션 시작
virtctl migrate my-poc-vm -n poc-vm

# 또는 VirtualMachineInstanceMigration 오브젝트를 직접 생성
oc apply -f - <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: my-poc-vm-migration
  namespace: poc-vm
spec:
  vmiName: my-poc-vm
EOF
```

### 마이그레이션 상태 확인

```bash
# 마이그레이션 진행 상황
oc get vmim -n poc-vm

# 상세 확인
oc describe vmim my-poc-vm-migration -n poc-vm

# 마이그레이션 완료 후 노드 변경 확인
oc get vmi my-poc-vm -n poc-vm \
  -o jsonpath='{.status.nodeName}{"\n"}'
```

### 마이그레이션 취소

```bash
virtctl migrate-cancel my-poc-vm -n poc-vm
```

---

## 상태 확인 명령어

```bash
# VM / VMI 전체 상태
oc get vm,vmi -n poc-vm

# VM 이벤트
oc describe vm my-poc-vm -n poc-vm

# VM Runner Pod 로그
oc logs -n poc-vm \
  $(oc get pod -n poc-vm -l vm.kubevirt.io/name=my-poc-vm -o name)

# DataVolume 상태 (루트 디스크 클론 진행 상황)
oc get dv -n poc-vm
```

---

## 롤백

```bash
# VM 중지 및 삭제
virtctl stop my-poc-vm -n poc-vm
oc delete vm my-poc-vm -n poc-vm

# DataVolume 삭제 (루트 디스크)
oc delete dv my-poc-vm -n poc-vm

# 추가 PVC 삭제
oc delete pvc my-poc-vm-data -n poc-vm

# NAD 삭제
oc delete net-attach-def poc-bridge-nad -n poc-vm

# namespace 삭제
oc delete namespace poc-vm
```
