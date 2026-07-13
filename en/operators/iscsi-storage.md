# iSCSI Storage Configuration for OpenShift Virtualization

iSCSI 스토리지를 OpenShift Virtualization에서 사용하기 위한 설정 가이드입니다.

```
iSCSI Target (Storage Server)
  │
  ├─ LUN 1 → PV → PVC → VM Disk
  ├─ LUN 2 → PV → PVC → VM Disk
  └─ LUN 3 → PV → PVC → DataVolume
```

---

## Prerequisites

- OpenShift cluster with worker nodes
- iSCSI target server configured and accessible
- iSCSI initiator package installed on worker nodes
- Network connectivity between worker nodes and iSCSI target

---

## Architecture Overview

| Component | Role |
|-----------|------|
| **iSCSI Target** | Storage server providing LUNs |
| **iSCSI Initiator** | Worker nodes (configured via MachineConfig) |
| **PersistentVolume (PV)** | Kubernetes abstraction for iSCSI LUN |
| **PersistentVolumeClaim (PVC)** | User request for storage |
| **StorageClass** | Dynamic provisioning (optional) |

---

## 1. Configure iSCSI Initiator on Worker Nodes

### Method A: Using MachineConfig (Recommended)

iSCSI initiator를 모든 worker 노드에 자동으로 설정합니다.

```bash
# Get worker node's machine config pool
oc get mcp

# Create MachineConfig for iSCSI initiator
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

**Note**: 각 노드는 고유한 IQN이 필요합니다. 프로덕션 환경에서는 노드별로 다른 IQN을 설정해야 합니다.

### Method B: Manual Configuration (Testing)

특정 노드에서 테스트용으로 수동 설정:

```bash
# SSH into worker node (if accessible)
ssh core@worker-0

# Install iSCSI packages (if not already installed)
sudo rpm-ostree install iscsi-initiator-utils
sudo systemctl reboot

# After reboot, check initiator name
sudo cat /etc/iscsi/initiatorname.iscsi

# Start iSCSI services
sudo systemctl enable iscsid iscsi --now
sudo systemctl status iscsid
```

### Verify iSCSI Initiator

```bash
# Check MachineConfig status
oc get mcp worker

# Verify on nodes
oc debug node/worker-0
chroot /host
systemctl status iscsid
cat /etc/iscsi/initiatorname.iscsi
exit
```

---

## 2. Discover and Login to iSCSI Target

### Discover Targets

```bash
# From worker node or debug pod
ISCSI_TARGET_IP="192.168.1.100"
ISCSI_TARGET_PORT="3260"

# Discover available targets
iscsiadm -m discovery -t st -p ${ISCSI_TARGET_IP}:${ISCSI_TARGET_PORT}

# Example output:
# 192.168.1.100:3260,1 iqn.2024-01.com.example:storage.target01
```

### Login to Target

```bash
# Login to discovered target
TARGET_IQN="iqn.2024-01.com.example:storage.target01"

iscsiadm -m node -T ${TARGET_IQN} -p ${ISCSI_TARGET_IP}:${ISCSI_TARGET_PORT} --login

# Verify connection
iscsiadm -m session

# List discovered devices
lsblk | grep sd
```

### Configure Automatic Login (Optional)

```bash
# Set automatic login on boot
iscsiadm -m node -T ${TARGET_IQN} -p ${ISCSI_TARGET_IP}:${ISCSI_TARGET_PORT} --op update -n node.startup -v automatic

# Verify
iscsiadm -m node -T ${TARGET_IQN} -p ${ISCSI_TARGET_IP}:${ISCSI_TARGET_PORT}
```

---

## 3. Create PersistentVolume for iSCSI LUN

### Static Provisioning

각 iSCSI LUN에 대해 PV를 생성합니다.

```bash
# Get LUN information
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

### With CHAP Authentication

CHAP 인증을 사용하는 경우:

```bash
# Create Secret for CHAP credentials
oc create secret generic iscsi-chap-secret \
  -n default \
  --from-literal=node.session.auth.username=chapuser \
  --from-literal=node.session.auth.password=chappassword

# PV with CHAP
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

## 4. Create StorageClass (Optional)

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

**Note**: 표준 iSCSI는 동적 프로비저닝을 지원하지 않습니다. CSI driver가 필요합니다.

---

## 5. Create PVC and Use in VM

### Create PVC

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

# Verify PVC binding
oc get pvc iscsi-pvc-01
```

### Use PVC in VM

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

## 6. Multipath Configuration (Production)

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

## 7. Verify and Test

### Check PV/PVC Status

```bash
# List all PVs
oc get pv

# Check specific PV details
oc describe pv iscsi-pv-01

# List PVCs
oc get pvc -A

# Check PVC binding
oc describe pvc iscsi-pvc-01 -n default
```

### Verify iSCSI Sessions

```bash
# From worker node
oc debug node/worker-0
chroot /host

# Check active sessions
iscsiadm -m session

# Check session details
iscsiadm -m session -P 3

# List attached disks
lsblk | grep sd
```

### Test VM with iSCSI Disk

```bash
# Check VM status
oc get vm,vmi vm-iscsi-disk

# Console into VM
virtctl console vm-iscsi-disk

# Inside VM, check disks
lsblk
fdisk -l

# Create filesystem and mount (if needed)
sudo mkfs.ext4 /dev/vdb
sudo mkdir /mnt/iscsi-disk
sudo mount /dev/vdb /mnt/iscsi-disk
df -h
```

---

## 8. Troubleshooting

### iSCSI Service Not Running

```bash
# Check service status
systemctl status iscsid
systemctl status iscsi

# Restart services
systemctl restart iscsid iscsi

# Check logs
journalctl -u iscsid -f
```

### Discovery Fails

```bash
# Test network connectivity
ping 192.168.1.100

# Test port connectivity
nc -zv 192.168.1.100 3260

# Check firewall
firewall-cmd --list-all

# Manually discover
iscsiadm -m discovery -t st -p 192.168.1.100:3260 -d 8
```

### Login Fails

```bash
# Check target status on storage server
targetcli ls

# Check ACL permissions
# Target server should allow initiator IQN

# Try manual login with debug
iscsiadm -m node -T <IQN> -p <IP>:3260 --login -d 8

# Check authentication
iscsiadm -m node -T <IQN> -p <IP>:3260
```

### PV Not Binding

```bash
# Check PV status
oc get pv iscsi-pv-01 -o yaml

# Check events
oc get events -n default --sort-by='.lastTimestamp'

# Verify LUN accessibility
# From worker node:
iscsiadm -m session -P 3 | grep -A5 "Lun: 0"
```

### VM Cannot Use iSCSI Disk

```bash
# Check PVC status
oc get pvc iscsi-pvc-01 -o yaml

# Check VM events
oc describe vm vm-iscsi-disk

# Check virt-launcher pod
oc get pods -l kubevirt.io/vm=vm-iscsi-disk
oc logs <virt-launcher-pod>

# Verify disk attachment
oc get vmi vm-iscsi-disk -o yaml | grep -A10 volumes
```

---

## 9. Best Practices

### Security

1. **Use CHAP authentication** for production
2. **Limit ACLs** on target to specific initiator IQNs
3. **Use dedicated network** for iSCSI traffic (VLAN)
4. **Enable firewall** rules to restrict access

### Performance

1. **Use jumbo frames** (MTU 9000) for iSCSI network
2. **Configure multipath** for redundancy
3. **Use separate NICs** for iSCSI traffic
4. **Monitor disk I/O** performance

### Availability

1. **Configure multipath** with multiple paths
2. **Use multiple targets** for redundancy
3. **Regular backup** of LUN data
4. **Monitor target health**

---

## 10. Cleanup

### Remove VM and PVC

```bash
oc delete vm vm-iscsi-disk
oc delete pvc iscsi-pvc-01
```

### Remove PV

```bash
oc delete pv iscsi-pv-01
```

### Logout from iSCSI Target

```bash
# From worker node
iscsiadm -m node -T <IQN> -p <IP>:3260 --logout

# Remove saved target
iscsiadm -m node -T <IQN> -p <IP>:3260 -o delete
```

### Remove MachineConfig (Optional)

```bash
oc delete mc 99-worker-iscsi-initiator
oc delete mc 99-worker-multipath
```

---

## Reference

- [OpenShift Virtualization Documentation](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/virtualization/index)
- [Kubernetes iSCSI Persistent Volumes](https://kubernetes.io/docs/concepts/storage/volumes/#iscsi)
- [iSCSI Target Configuration](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/managing_storage_devices/getting-started-with-iscsi_managing-storage-devices)
