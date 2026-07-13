# Migration Toolkit for Virtualization (MTV) 랩

VMware에서 OpenShift Virtualization으로 VM을 마이그레이션하는 랩입니다.

```
VMware vSphere
  └─ VM (Windows/Linux)
       │  MTV Provider 등록
       ▼
Migration Toolkit for Virtualization
  └─ Migration Plan 생성
       │  Cold Migration 또는 Warm Migration
       ▼
OpenShift Virtualization
  └─ VirtualMachine (poc-mtv namespace)
```

---

## 사전 요구사항

- MTV Operator 설치 완료 (`operators/mtv-operator.md` 참조)
- vSphere 접속 정보 (vCenter URL, 사용자명/비밀번호)
- VMware VDDK 이미지 (`env.conf`의 `VDDK_IMAGE`)
- `13-mtv.sh` 실행 완료

---

## ⚠️ VMware 마이그레이션 전 필수 확인 사항

마이그레이션 실패 및 데이터 손실을 방지하기 위해 **마이그레이션 전**에 다음 사항을 확인하세요.

---

### 1. Hot-plug 비활성화 (VMware)

마이그레이션 대상 VM에서 **CPU Hot-plug / Memory Hot-plug을 반드시 비활성화**해야 합니다.

마이그레이션 중 Hot-plug이 활성화되어 있으면
OpenShift Virtualization에서 VM이 정상적으로 시작되지 않습니다.

**Console에서 비활성화:**
1. vCenter → VM 우클릭 → **Edit Settings**
2. **VM Options** 탭 → **Advanced** → **Edit Configuration**
3. 다음 파라미터를 확인하고 변경:

```
cpuid.coresPerSocket = <cores per socket>
vcpu.hotadd          = FALSE    ← Hot-plug CPU 비활성화
mem.hotadd           = FALSE    ← Hot-plug Memory 비활성화
```

또는 VM을 종료한 후 **Edit Settings → CPU/Memory → Enable CPU/Memory Hot Add** 체크 해제

---

### 2. Shared Disk (Multi-writer) 활성화 — Warm Migration 필수

Warm Migration을 사용하려면 VMDK 스냅샷을 위해 **Shared Disk (Multi-writer)를 활성화**해야 합니다.

> Cold Migration에는 해당하지 않습니다.

**vSphere 설정:**
1. vCenter → VM 우클릭 → **Edit Settings**
2. 디스크 선택 → **Advanced** → **Sharing** → **Multi-writer** 선택

또는 `.vmx` 파일에 직접 추가:

```
diskN.shared = "multi-writer"
```

---

### 3. Windows VM — 빠른 시작 비활성화 + 정상 종료

Windows VM을 마이그레이션할 때는 다음 두 가지를 모두 완료해야 합니다.

#### 3-1. 빠른 시작 비활성화

마이그레이션 중 빠른 시작이 활성화되어 있으면 디스크가 최대 절전 모드 상태로 복사되어
OpenShift에서 정상 부팅이 되지 않습니다.

**Windows 내부에서 설정:**
```
제어판 → 전원 옵션 → 전원 단추 작동 설정 → 빠른 시작 켜기(권장) 체크 해제
```

또는 PowerShell:
```powershell
powercfg /hibernate off
```

#### 3-2. 마이그레이션 전 정상 종료

빠른 시작을 비활성화한 후 마이그레이션 전에 **완전 종료(Shutdown)**를 수행하세요.
재시작(Restart)이 아닌 종료(Shutdown)여야 합니다.

```powershell
# PowerShell에서 완전 종료
Stop-Computer -Force
```

---

### 4. Warm Migration — vSphere CBT (Changed Block Tracking) 활성화

Warm Migration은 VM이 실행 중인 상태에서 점진적으로 마이그레이션합니다.
이를 위해 vSphere에서 **CBT (Changed Block Tracking)**를 활성화해야 합니다.

CBT가 없으면 전체 디스크가 반복적으로 복사되어 Warm Migration이 비효율적입니다.

**CBT 활성화 방법:**

VM을 종료하고 `.vmx` 파일에 추가하거나 vSphere API를 통해 설정:

```
ctkEnabled = "TRUE"
scsiN:M.ctkEnabled = "TRUE"
```

또는 PowerCLI:
```powershell
$vm = Get-VM -Name "target-vm"
$spec = New-Object VMware.Vim.VirtualMachineConfigSpec
$spec.changeTrackingEnabled = $true
$vm.ExtensionData.ReconfigVM($spec)
```

**확인:**
```powershell
(Get-VM "target-vm").ExtensionData.Config.ChangeTrackingEnabled
# → True여야 함
```

> CBT 활성화 후 **스냅샷을 한 번 생성하고 삭제**해야 CBT가 실제로 적용됩니다.

---

## MTV 설정

### Provider 등록

```bash
source env.conf

# vSphere Provider Secret 생성
oc create secret generic vsphere-secret \
  -n openshift-mtv \
  --from-literal=user=<vCenter_user> \
  --from-literal=password=<vCenter_password> \
  --from-literal=cacert="" \
  --from-literal=insecureSkipVerify=true

# vSphere Provider 등록
oc apply -f - <<EOF
apiVersion: forklift.konveyor.io/v1beta1
kind: Provider
metadata:
  name: vsphere-provider
  namespace: openshift-mtv
spec:
  type: vsphere
  url: https://<vCenter_IP>/sdk
  secret:
    name: vsphere-secret
    namespace: openshift-mtv
EOF
```

### VDDK ConfigMap 등록

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: vddk-config
  namespace: openshift-mtv
data:
  vddkInitImage: ${VDDK_IMAGE}
EOF
```

### Migration Plan 생성 (Cold)

```bash
oc apply -f - <<EOF
apiVersion: forklift.konveyor.io/v1beta1
kind: Plan
metadata:
  name: poc-cold-migration
  namespace: openshift-mtv
spec:
  provider:
    source:
      name: vsphere-provider
      namespace: openshift-mtv
    destination:
      name: host
      namespace: openshift-mtv
  targetNamespace: poc-mtv
  map:
    network:
      name: poc-network-map
      namespace: openshift-mtv
    storage:
      name: poc-storage-map
      namespace: openshift-mtv
  vms:
    - id: <vm-moref-id>
EOF
```

---

## 랩 검증

```bash
# Provider 상태 확인
oc get provider -n openshift-mtv

# Migration Plan 상태 확인
oc get plan -n openshift-mtv

# Migration 진행 상황 확인
oc get migration -n openshift-mtv

# 마이그레이션된 VM 확인
oc get vm -n poc-mtv
```

---

## 문제 해결

```bash
# MTV Controller 로그
oc logs -n openshift-mtv deployment/forklift-controller --tail=50

# VDDK 이미지 확인
oc get configmap vddk-config -n openshift-mtv -o yaml

# Provider 상태 상세 정보
oc describe provider vsphere-provider -n openshift-mtv

# Migration 실패 이벤트
oc get events -n openshift-mtv --sort-by='.lastTimestamp' | tail -20
```

---

## 롤백

```bash
# Migration Plan 삭제
oc delete plan poc-cold-migration -n openshift-mtv

# Provider 삭제
oc delete provider vsphere-provider -n openshift-mtv
oc delete secret vsphere-secret -n openshift-mtv

# 마이그레이션된 VM 삭제
oc delete namespace poc-mtv
```
