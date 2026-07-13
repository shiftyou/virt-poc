# 네트워크 구성 (NNCP / NAD)

OpenShift Virtualization에서 VM을 물리 네트워크에 연결하기 위해
NNCP (NodeNetworkConfigurationPolicy)와 NAD (NetworkAttachmentDefinition)를 구성합니다.

`02-network.sh` 실행 시 4가지 방식 중 하나를 선택합니다.

---

## 방식 비교

| 항목 | Linux Bridge | OVN Localnet | Linux Bridge + VLAN | OVN Localnet + VLAN |
|------|-------------|-------------|---------------------|---------------------|
| CNI driver | `cnv-bridge` | `ovn-k8s-cni-overlay` | `cnv-bridge` | `ovn-k8s-cni-overlay` |
| VLAN 격리 | ❌ | ❌ | ✅ (NAD에서 VLAN ID 지정) | ✅ (NAD에서 vlanID 지정) |
| OVN port security·ACL | ❌ | ✅ | ❌ | ✅ |
| 스위치 요구사항 | Access 또는 Trunk | Trunk (OVN이 처리) | Trunk | Trunk |
| NNCP 추가 설정 | bridge만 | bridge + `ovn.bridge-mappings` | bridge + VLAN trunk port | bridge + `ovn.bridge-mappings` |

---

## 선택 가이드 -- 어떤 방식을 사용할 것인가?

### 결정 흐름

```
                     ┌──────────────────────────┐
                     │  VLAN 격리가 필요한가?    │
                     └────┬────────────────┬────┘
                          │ 아니오         │ 예
                  ┌───────▼───────┐  ┌─────▼─────────────────┐
                  │ OVN 보안이    │  │ OVN 보안이            │
                  │ 필요한가?     │  │ 필요한가?             │
                  │ (port security│  │ (port security / ACL) │
                  │  / ACL)       │  │                       │
                  └──┬─────────┬──┘  └──┬────────────────┬──┘
                     │ 아니오  │ 예     │ 아니오         │ 예
                     ▼         ▼        ▼                ▼
                 방식 1     방식 2    방식 3           방식 4
              Linux Bridge   OVN    Bridge+VLAN     OVN+VLAN
```

| 시나리오 | 권장 방식 |
|----------|-----------|
| 테스트/개발 환경, 빠른 설정 | **방식 1** -- 가장 간단한 구성, 스위치 변경 불필요 |
| VM 네트워크 보안 정책 (port security, ACL) | **방식 2** -- OVN이 L2 switching + 보안 제공 |
| 테넌트/부서별 네트워크 격리 | **방식 3** -- 기존 인프라를 활용한 VLAN ID 기반 트래픽 격리 |
| VLAN 격리 + OVN 보안 모두 필요 | **방식 4** -- 가장 완전한 격리, 복잡도 최고 |

### 물리 스위치 체크리스트

**물리 스위치 포트** 구성은 OpenShift 노드 NIC에 대해 방식별로 다릅니다.

#### 방식 1: Linux Bridge

| 항목 | 상세 |
|------|------|
| 스위치 포트 모드 | **Access** 또는 **Trunk** -- 둘 다 가능 |
| VLAN 설정 | 불필요 (untagged 트래픽 사용) |
| 비고 | Access 포트인 경우, 해당 VLAN의 untagged 트래픽이 노드에 도달합니다. 가장 간단한 설정 |

```
# Cisco IOS 예시 — Access port
interface GigabitEthernet0/1
  switchport mode access
  switchport access vlan 10        ← 노드가 속한 VLAN
  spanning-tree portfast           ← 권장 (빠른 link-up)
  no shutdown
```

**체크리스트:**
- [ ] 노드 NIC에 연결된 스위치 포트가 UP 상태
- [ ] 필요 시 Spanning-tree PortFast 활성화 (bridge 생성 시 STP 지연 방지)

#### 방식 2: OVN Localnet

| 항목 | 상세 |
|------|------|
| 스위치 포트 모드 | **Trunk** (필수) |
| VLAN 설정 | 불필요 -- OVN이 내부적으로 switching 처리 |
| 비고 | OVN이 L2 switching을 관리합니다. NNCP의 `ovn.bridge-mappings`를 통해 물리 bridge를 OVN localnet 이름에 매핑합니다 |

```
# Cisco IOS 예시 — Trunk port (모든 VLAN 허용)
interface GigabitEthernet0/1
  switchport mode trunk
  switchport trunk encapsulation dot1q
  switchport trunk allowed vlan all
  spanning-tree portfast trunk
  no shutdown
```

**체크리스트:**
- [ ] 스위치 포트가 trunk 모드 (`show interface GigabitEthernet0/1 switchport`)
- [ ] NNCP `bridge-mappings[].localnet` 값이 NAD CNI 설정의 `"name"` 값과 **일치**

#### 방식 3: Linux Bridge + VLAN

| 항목 | 상세 |
|------|------|
| 스위치 포트 모드 | **Trunk** (필수) |
| VLAN 설정 | VM이 사용하는 VLAN ID가 스위치 **allowed** 목록에 포함되어야 함 |
| 비고 | bridge 포트를 trunk 모드로 설정하여 tagged 트래픽을 수신합니다. NAD의 `"vlan"` 필드가 VM 트래픽에 태그를 지정합니다 |

```
# Cisco IOS 예시 — Trunk port (특정 VLAN만 허용)
interface GigabitEthernet0/1
  switchport mode trunk
  switchport trunk encapsulation dot1q
  switchport trunk allowed vlan 100,200,300   ← VM용 VLAN 목록
  switchport trunk native vlan 999            ← VM VLAN과 다른 번호 사용
  spanning-tree portfast trunk
  no shutdown
```

> 스위치에서 VLAN을 먼저 생성해야 합니다:
> ```
> vlan 100
>   name VM-Production
> vlan 200
>   name VM-Development
> ```

**체크리스트:**
- [ ] 스위치 포트가 trunk 모드
- [ ] VLAN ID가 `switchport trunk allowed vlan` 목록에 포함
- [ ] 스위치에 VLAN이 존재 (`show vlan brief`)
- [ ] Native VLAN이 VM VLAN과 **겹치지 않음** (겹치면 untagged 처리 → 격리 실패)
- [ ] NNCP `trunk-tags` 범위가 스위치의 allowed VLAN 범위와 일치

#### 방식 4: OVN Localnet + VLAN

| 항목 | 상세 |
|------|------|
| 스위치 포트 모드 | **Trunk** (필수) |
| VLAN 설정 | NAD에 지정된 VLAN ID가 스위치에서 허용되어야 함 |
| 비고 | NNCP는 방식 2와 동일합니다. NAD에 `"vlanID"`를 추가합니다. OVN port security와 VLAN 격리가 모두 적용됩니다 |

스위치 구성은 방식 3과 동일합니다. 추가로:

**체크리스트:**
- [ ] 방식 3 체크리스트의 모든 항목 적용
- [ ] NNCP `bridge-mappings[].localnet`이 NAD `"name"`과 일치 (방식 2와 동일한 규칙)

### 자주 발생하는 실수 / 문제 해결

| 증상 | 원인 | 해결 방법 |
|------|------|-----------|
| NNCP가 `Available`인데 VM 네트워크가 안 됨 | VLAN 방식을 사용하는데 스위치 포트가 Access 모드 | 스위치 포트를 Trunk 모드로 변경 |
| 특정 VLAN의 VM만 통신 불가 | 스위치 `allowed vlan` 목록에 해당 VLAN이 누락 | `switchport trunk allowed vlan add <ID>` |
| 같은 VLAN의 VM끼리 통신 불가 | Native VLAN이 VM VLAN과 동일 → 트래픽이 untagged로 처리 | Native VLAN을 사용하지 않는 번호(예: 999)로 변경 |
| NNCP 생성 후 Bridge가 Forwarding 상태에 도달하지 않음 | STP가 Blocking → Learning → Forwarding을 거침 (최대 30초) | 스위치에서 PortFast를 활성화하거나, NNCP에서 `stp.enabled: false` 설정 |
| OVN Localnet 방식으로 VM NIC가 생성되지 않음 | NNCP `localnet` 이름과 NAD `"name"`이 불일치 | 두 값을 동일하게 맞춤 ([문제 해결](#ovn-localnet--localnet-name-mismatch)) |
| NNCP 적용 후 노드 네트워크가 끊김 | 관리용 NIC를 bridge 포트로 사용함 | bridge 포트에 별도의 NIC를 사용. 관리용 NIC는 절대 사용 금지 |

### 스위치 확인 명령어 (참고)

```
# Cisco IOS / NX-OS
show interfaces trunk                     ← trunk 포트 목록 + 허용된 VLAN
show interfaces <port> switchport         ← 포트 모드 (access/trunk)
show vlan brief                           ← 생성된 VLAN 목록
show spanning-tree interface <port>       ← STP 상태 (Forwarding?)

# Juniper JunOS
show vlans
show interfaces <port> extensive
show ethernet-switching interface <port>

# 노드에서 확인 (OpenShift)
oc debug node/<node> -- chroot /host bridge vlan show         ← bridge VLAN 필터 상태
oc debug node/<node> -- chroot /host ip -d link show <bridge> ← bridge 상태
oc get nnce                                                    ← 노드별 NNCP 상태
```

---

## 사전 요구사항

- NMState Operator 설치 및 NMState CR 생성 완료 (`operators/nmstate-operator.md` 참고)
- `env.conf`에 `BRIDGE_INTERFACE`, `BRIDGE_NAME`, `SECONDARY_IP_PREFIX` 설정 완료
- Namespace: `poc-network` (고정)

```bash
# NMState Operator 상태
oc get csv -n openshift-nmstate | grep nmstate

# NMState CR 존재 확인
oc get nmstate

# 노드 인터페이스 이름 확인
oc get nns <worker-node> \
  -o jsonpath='{range .status.currentState.interfaces[?(@.type=="ethernet")]}{.name}{"\n"}{end}'
```

---

## 방식 1. Linux Bridge

```
Physical NIC (BRIDGE_INTERFACE)
    │  NNCP → Linux Bridge 생성
    ▼
Linux Bridge (BRIDGE_NAME)
    │  NAD → cnv-bridge CNI
    ▼
VM eth1 (L2 직접 연결)
```

### NNCP

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: poc-bridge-nncp
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: br1                     # BRIDGE_NAME
        type: linux-bridge
        state: up
        ipv4:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ens4              # BRIDGE_INTERFACE
```

### NAD

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: poc-bridge-nad
  namespace: poc-network
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/br1
spec:
  config: '{
    "cniVersion": "0.3.1",
    "name": "poc-bridge-nad",
    "type": "cnv-bridge",
    "bridge": "br1",
    "macspoofchk": true,
    "ipam": {}
  }'
```

---

## 방식 2. OVN Localnet

OVN-Kubernetes가 switching을 처리합니다.
NNCP에 `ovn.bridge-mappings`를 추가하여 물리 bridge를 OVN localnet 이름에 매핑합니다.

> **핵심**: NNCP의 `bridge-mappings[].localnet` 값과 NAD CNI 설정의 `"name"` 값이 반드시 **일치**해야 합니다.

```
Physical NIC (BRIDGE_INTERFACE)
    │  NNCP → Linux Bridge + OVN bridge-mappings
    ▼
Linux Bridge (BRIDGE_NAME) ← OVN localnet: "poc-localnet"
    │  NAD → ovn-k8s-cni-overlay CNI
    ▼
VM eth1 (OVN port security·ACL 적용)
```

### NNCP

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: poc-localnet-nncp
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: br1
        type: linux-bridge
        state: up
        ipv4:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ens4
    ovn:
      bridge-mappings:
        - localnet: poc-localnet      # NAD "name" 값과 일치해야 함
          bridge: br1
          state: present
```

### NAD

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: poc-localnet-nad
  namespace: poc-network
spec:
  config: '{
    "cniVersion": "0.3.1",
    "name": "poc-localnet",           # NNCP bridge-mappings localnet 값과 일치해야 함
    "type": "ovn-k8s-cni-overlay",
    "topology": "localnet",
    "netAttachDefName": "poc-network/poc-localnet-nad"
  }'
```

---

## 방식 3. Linux Bridge + VLAN 필터링

Linux Bridge 포트를 **trunk 모드**로 구성하여 단일 물리 NIC로 여러 VLAN을 분리합니다.
NAD별로 다른 VLAN ID를 지정하여 VM을 원하는 VLAN에 배치합니다.

> 물리 스위치 포트도 **trunk 모드**로 설정되어 있어야 합니다.

```
Physical NIC (BRIDGE_INTERFACE) — 스위치 trunk 포트에 연결
    │  NNCP → Linux Bridge + VLAN trunk port
    ▼
Linux Bridge (BRIDGE_NAME)
    │  NAD → cnv-bridge + vlan: 100
    ▼
VM eth1 (VLAN 100에 배치)
```

### NNCP

```yaml
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: poc-bridge-nncp
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: br1
        type: linux-bridge
        state: up
        ipv4:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ens4
              vlan:
                mode: trunk            # VLAN 필터링 활성화
                trunk-tags:
                  - id-range:
                      min: 1
                      max: 4094        # 모든 VLAN 허용 (필요 시 범위 축소)
```

### NAD (VLAN 100 예시)

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: poc-bridge-vlan-nad
  namespace: poc-network
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/br1
spec:
  config: '{
    "cniVersion": "0.3.1",
    "name": "poc-bridge-vlan-nad",
    "type": "cnv-bridge",
    "bridge": "br1",
    "vlan": 100,                       # VM이 연결될 VLAN ID
    "macspoofchk": true,
    "ipam": {}
  }'
```

> 다른 VLAN(예: 200)을 사용하려면 동일한 NNCP를 재사용하고 `"vlan": 200`으로 새 NAD를 생성합니다.

---

## 방식 4. OVN Localnet + VLAN

OVN bridge-mappings + NAD에 `vlanID`를 지정합니다.
NNCP는 방식 2와 동일하고, NAD에 `vlanID`만 추가합니다.

```
Physical NIC (BRIDGE_INTERFACE) — 스위치 trunk 포트에 연결
    │  NNCP → Linux Bridge + OVN bridge-mappings
    ▼
Linux Bridge ← OVN localnet: "poc-localnet"
    │  NAD → ovn-k8s-cni-overlay + vlanID: 100
    ▼
VM eth1 (OVN port security + VLAN 100)
```

### NNCP

방식 2 NNCP (`poc-localnet-nncp`)와 동일합니다.

### NAD (VLAN 100 예시)

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: poc-localnet-vlan-nad
  namespace: poc-network
spec:
  config: '{
    "cniVersion": "0.3.1",
    "name": "poc-localnet",
    "type": "ovn-k8s-cni-overlay",
    "topology": "localnet",
    "netAttachDefName": "poc-network/poc-localnet-vlan-nad",
    "vlanID": 100
  }'
```

---

## VM 생성 (공통)

선택한 NAD를 secondary network로 연결하고, cloud-init을 통해 eth1에 고정 IP를 구성합니다.
두 개의 VM (`poc-network-vm-1`, `poc-network-vm-2`)을 배포합니다.

| VM | eth1 IP |
|----|---------|
| poc-network-vm-1 | `SECONDARY_IP_PREFIX`.10/24 |
| poc-network-vm-2 | `SECONDARY_IP_PREFIX`.11/24 |

> `SECONDARY_IP_PREFIX` 기본값: `192.168.100` (env.conf에서 변경 가능)
> `02-network.sh`가 아래 patch를 자동으로 수행합니다.

```bash
NAD_NAME="poc-bridge-nad"           # 선택한 방식에 따라 변경
SECONDARY_IP_PREFIX="192.168.100"   # env.conf 값 사용

for suffix in 1 2; do
  VM_NAME="poc-network-vm-${suffix}"
  IP_SUFFIX=$([ "$suffix" = "1" ] && echo "10" || echo "11")

  # poc 템플릿에서 VM 생성 (Halted 상태)
  oc process -n openshift poc -p NAME="${VM_NAME}" \
    | sed 's/  running: false/  runStrategy: Halted/' \
    | oc apply -n "poc-network" -f -

  # Secondary NIC 추가
  oc patch vm "${VM_NAME}" -n "poc-network" --type=json -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/domain/devices/interfaces/-",
      "value": {"name": "bridge-net", "bridge": {}, "model": "virtio"}
    },
    {
      "op": "add",
      "path": "/spec/template/spec/networks/-",
      "value": {"name": "bridge-net", "multus": {"networkName": "'"${NAD_NAME}"'"}}
    }
  ]'

  # 기존 cloudinitdisk 볼륨에 networkData 추가 (VM 시작 전)
  CI_IDX=$(oc get vm "${VM_NAME}" -n "poc-network" \
    -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' | \
    grep -n "cloudinitdisk" | cut -d: -f1 | head -1)
  CI_IDX=$(( CI_IDX - 1 ))
  oc patch vm "${VM_NAME}" -n "poc-network" --type=json -p="[
    {\"op\": \"add\",
     \"path\": \"/spec/template/spec/volumes/${CI_IDX}/cloudInitNoCloud/networkData\",
     \"value\": \"version: 2\nethernets:\n  eth1:\n    dhcp4: false\n    addresses:\n      - ${SECONDARY_IP_PREFIX}.${IP_SUFFIX}/24\n    gateway4: ${SECONDARY_IP_PREFIX}.1\n    nameservers:\n      addresses:\n        - 8.8.8.8\n\"}
  ]"

  virtctl start "${VM_NAME}" -n "poc-network"
done
```

결과로 생성되는 `cloudinitdisk` 볼륨:

```yaml
- name: cloudinitdisk
  cloudInitNoCloud:
    userData: |-
      #cloud-config
      user: cloud-user
      password: ...
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

### VM 네트워크 검증

```bash
# VMI NIC 상태 (두 VM 모두)
for vm in poc-network-vm-1 poc-network-vm-2; do
  echo "=== ${vm} ==="
  oc get vmi "${vm}" -n "poc-network" \
    -o jsonpath='{range .status.interfaces[*]}{.name}: {.ipAddress}{"\n"}{end}'
done

# VM 콘솔 접속
virtctl console poc-network-vm-1 -n "poc-network"
# ip addr show eth1
# ping 192.168.100.11   ← vm-2와 통신 테스트
```

---

## 상태 확인

```bash
# NNCP 상태
oc get nncp

# 노드별 적용 상태 (NNCE)
oc get nnce

# NodeNetworkState에서 bridge 확인
oc get nns <node> -o yaml | grep -A5 "linux-bridge"

# OVN bridge-mappings 확인 (방식 2/4)
oc get nncp poc-localnet-nncp -o jsonpath='{.spec.desiredState.ovn}' | python3 -m json.tool

# NAD 목록
oc get net-attach-def -n poc-network
```

---

## 롤백

```bash
# NAD 삭제
oc delete net-attach-def -n poc-network --all

# NNCP 삭제 (Bridge 제거)
oc delete nncp poc-bridge-nncp poc-localnet-nncp 2>/dev/null || true

# Namespace 삭제
oc delete namespace poc-network
```

---

## 문제 해결

```bash
# NNCP 실패 원인 확인
oc describe nncp <nncp-name>

# 노드별 NNCE 오류 확인
oc describe nnce <node>.<nncp-name>

# NMState handler 로그
oc logs -n openshift-nmstate -l component=kubernetes-nmstate-handler -f

# 노드에서 네트워크 상태 직접 확인
oc debug node/<node> -- chroot /host nmstatectl show

# OVN localnet 매핑 확인 (방식 2/4)
oc debug node/<node> -- chroot /host ovs-vsctl list open .
```

### OVN Localnet -- localnet 이름 불일치

NNCP의 `bridge-mappings[].localnet` 값과 NAD CNI 설정의 `"name"` 값이 다르면
VM 네트워크 인터페이스가 생성되지 않습니다.

```bash
# NNCP의 localnet 이름 확인
oc get nncp poc-localnet-nncp \
  -o jsonpath='{.spec.desiredState.ovn.bridge-mappings[0].localnet}'

# NAD CNI 설정의 name 확인
oc get net-attach-def poc-localnet-nad -n poc-network \
  -o jsonpath='{.spec.config}' | python3 -m json.tool | grep '"name"'
```

두 값이 반드시 동일해야 합니다.
