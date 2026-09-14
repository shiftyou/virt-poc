#!/bin/bash
# =============================================================================
# 03-vm-workload.sh
#
# poc-vm namespace 생성, NAD 등록 및 VM 배포 (poc template + bridge network)
# VM 워크로드 실행 환경을 준비합니다.
#
# 사용법: ./03-vm-workload.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# env.conf 자동 로드 (단독 실행 시)
ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

VM_NS="poc-vm"
NNCP_NAME="${NNCP_NAME:-poc-bridge-nncp}"
BRIDGE_NAME="${BRIDGE_NAME:-br-poc}"
BRIDGE_INTERFACE="${BRIDGE_INTERFACE:-ens4}"
NNCP_IFACE_TYPE="${NNCP_IFACE_TYPE:-linux-bridge}"
NET_TYPE="${NET_TYPE:-1}"
NAD_NAME="${NAD_NAME:-}"
LOCALNET_NAME="${LOCALNET_NAME:-poc-localnet}"
VLAN_ID="${VLAN_ID:-100}"
SECONDARY_IP_PREFIX="${SECONDARY_IP_PREFIX:-192.168.100}"

if [ -f "${SCRIPT_DIR}/../utils/common.sh" ]; then
    source "${SCRIPT_DIR}/../utils/common.sh"
else
    # ── 독립 실행 모드: common.sh 없이 인라인 헬퍼 사용 ──
    RED='\033[0;31m'; GREEN='\033[0;32m'; DIM='\033[2m'
    YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
    print_info()  { echo -e "${BLUE}[정보]${NC} $1"; }
    print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
    print_warn()  { echo -e "${YELLOW}[경고]${NC} $1"; }
    print_error() { echo -e "${RED}[오류]${NC} $1"; }
    print_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }
    print_header() {
        echo -e "\n${CYAN}================================================================${NC}"
        echo -e "${CYAN}  $1${NC}"
        echo -e "${CYAN}================================================================${NC}\n"
    }
    print_step_header() {
        echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${CYAN}  $1  $2${NC}"
        echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
    }
    ask() {
        local prompt="$1" default="$2" var_name="$3" is_secret="${4:-false}"
        if [ "$is_secret" = "true" ]; then
            echo -n -e "${YELLOW}  $prompt${NC} [기본값: ****]: "; read -s input_val; echo
        else
            echo -n -e "${YELLOW}  $prompt${NC} [기본값: ${default}]: "; read input_val
        fi
        [ -z "$input_val" ] && input_val="$default"
        eval "$var_name='$input_val'"
    }
    save_to_env() {
        local key="$1" value="$2" env_file="${3:-${ENV_FILE:-}}"
        [ -z "$env_file" ] || [ ! -f "$env_file" ] && return 0
        if grep -q "^${key}=" "$env_file" 2>/dev/null; then
            if [[ "$OSTYPE" == darwin* ]]; then sed -i '' "s|^${key}=.*|${key}=${value}|" "$env_file"
            else sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"; fi
        else echo "${key}=${value}" >> "$env_file"; fi
    }
    load_or_ask() {
        local var_name="$1" prompt="$2" default="$3" is_secret="${4:-false}" current_val
        eval "current_val=\${${var_name}:-}"; [ -n "$current_val" ] && return 0
        ask "$prompt" "$default" "$var_name" "$is_secret"
        eval "local _val=\$$var_name"; save_to_env "$var_name" "$_val"
    }
    confirm_and_apply() {
        local file="$1" auto="${2:-true}"
        if [ "$auto" != "true" ]; then
            print_info "적용할 YAML:"; cat "$file"
            read -r -p "클러스터에 적용하시겠습니까? [y/N]: " confirm
            [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { print_warn "취소됨."; return 1; }
        fi
        oc apply -f "$file"
    }
    detect_worker_nodes() {
        WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        TEST_NODE=$(echo "$WORKER_NODES" | awk '{print $1}')
        [ -z "$WORKER_NODES" ] && { print_error "워커 노드를 찾을 수 없습니다."; exit 1; }
        print_info "워커 노드: ${WORKER_NODES}"
    }
    auto_detect_garage() {
        GARAGE_ENDPOINT=""; GARAGE_BUCKET="velero"; GARAGE_ACCESS_KEY="garage"
        GARAGE_SECRET_KEY="garage123"; GARAGE_FOUND=false
        local ns; ns=$(oc get svc -A -l app=garage -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
        if [ -n "$ns" ]; then
            local svc port
            svc=$(oc get svc -n "$ns" -l app=garage -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
                oc get svc -n "$ns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
            port=$(oc get svc -n "$ns" "$svc" -o jsonpath='{.spec.ports[?(@.name=="s3-api")].port}' 2>/dev/null || echo "3900")
            GARAGE_ENDPOINT="http://${svc}.${ns}.svc.cluster.local:${port}"
            local sn; sn=$(oc get secret -n "$ns" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
                tr ' ' '\n' | grep -iE "garage|credentials|s3" | head -1 || true)
            if [ -n "$sn" ]; then
                local ak sk
                ak=$(oc get secret -n "$ns" "$sn" -o jsonpath='{.data.accessKey}' 2>/dev/null | base64 -d 2>/dev/null || \
                    oc get secret -n "$ns" "$sn" -o jsonpath='{.data.access_key_id}' 2>/dev/null | base64 -d 2>/dev/null || true)
                sk=$(oc get secret -n "$ns" "$sn" -o jsonpath='{.data.secretKey}' 2>/dev/null | base64 -d 2>/dev/null || \
                    oc get secret -n "$ns" "$sn" -o jsonpath='{.data.secret_access_key}' 2>/dev/null | base64 -d 2>/dev/null || true)
                [ -n "$ak" ] && GARAGE_ACCESS_KEY="$ak"; [ -n "$sk" ] && GARAGE_SECRET_KEY="$sk"
            fi
            GARAGE_FOUND=true
            print_info "Garage endpoint : ${GARAGE_ENDPOINT}  (ns: ${ns})"
            print_info "Garage bucket   : ${GARAGE_BUCKET}"
            print_info "Garage accessKey: ${GARAGE_ACCESS_KEY}"
        else print_warn "Garage Service (app=garage) 감지 실패 → Garage 설정을 건너뜁니다."; fi
    }
    auto_detect_odf() {
        ODF_S3_ENDPOINT=""; ODF_S3_BUCKET="velero"; ODF_S3_REGION="localstorage"
        ODF_S3_ACCESS_KEY=""; ODF_S3_SECRET_KEY=""
        local ns="openshift-storage"
        ODF_S3_ENDPOINT=$(oc get noobaa -n "$ns" -o jsonpath='{.status.services.serviceS3.internalDNS[0]}' 2>/dev/null || true)
        if [ -z "$ODF_S3_ENDPOINT" ]; then
            local p; p=$(oc get svc s3 -n "$ns" -o jsonpath='{.spec.ports[?(@.name=="s3")].port}' 2>/dev/null || echo "80")
            ODF_S3_ENDPOINT="http://s3.${ns}.svc.cluster.local:${p}"
        fi
        ODF_S3_ACCESS_KEY=$(oc get secret noobaa-admin -n "$ns" -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d 2>/dev/null || true)
        ODF_S3_SECRET_KEY=$(oc get secret noobaa-admin -n "$ns" -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)
        if [ -n "$ODF_S3_ACCESS_KEY" ]; then
            print_info "ODF MCG S3 endpoint : ${ODF_S3_ENDPOINT}"
            print_info "ODF MCG region      : ${ODF_S3_REGION}"
            print_info "ODF MCG bucket      : ${ODF_S3_BUCKET}"
            print_info "ODF MCG 인증 정보   : noobaa-admin secret에서 가져옴"
        else print_warn "ODF MCG 인증 정보 감지 실패 (noobaa-admin secret 없음)"; fi
    }
fi

# =============================================================================
# 사전 점검
# =============================================================================
preflight() {
    print_step "사전 점검"

    # OpenShift Virtualization Operator 확인
    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator가 설치되지 않았습니다 → 건너뜀."
        print_warn "  설치 가이드: operators/kubevirt-hyperconverged-operator.md"
        exit 77
    fi

    if [ -n "$NNCP_NAME" ] && oc get nncp "$NNCP_NAME" &>/dev/null; then
        detect_nncp_type "$NNCP_NAME"
    fi
    resolve_nad_name
    save_network_env

    print_ok "설정 확인됨"
    print_info "  VM_NS            : ${VM_NS}"
    print_info "  BRIDGE_NAME      : ${BRIDGE_NAME}"
    print_info "  NNCP_IFACE_TYPE  : ${NNCP_IFACE_TYPE}"
    print_info "  NAD_NAME         : ${NAD_NAME}"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 연결: $(oc whoami) @ $(oc whoami --show-server)"

    # NNCP / Bridge 확인
    if ! oc get nncp "$NNCP_NAME" &>/dev/null; then
        print_warn "NNCP '${NNCP_NAME}'을(를) 찾을 수 없습니다."
        # 사용 가능한 NNCP 목록을 표시하고 선택 요청
        local _all_nncps
        _all_nncps=$(oc get nncp -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' || true)
        if [ -n "$_all_nncps" ]; then
            print_info "클러스터에 있는 NNCP 목록:"
            echo ""
            printf "    %-35s %-15s %-20s %s\n" "NNCP 이름" "유형" "Bridge 이름" "NIC"
            echo "    ────────────────────────────────────────────────────────────────────────"
            for _n in $_all_nncps; do
                local _b _nic _ob
                _b=$(oc get nncp "$_n" \
                    -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.name}{end}' \
                    2>/dev/null || true)
                if [ -n "$_b" ]; then
                    _nic=$(oc get nncp "$_n" \
                        -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.bridge.port[0].name}{end}' \
                        2>/dev/null || true)
                    printf "    %-35s %-15s %-20s %s\n" "$_n" "linux-bridge" "$_b" "${_nic:-N/A}"
                else
                    _ob=$(oc get nncp "$_n" \
                        -o jsonpath='{.spec.desiredState.ovn.bridge-mappings[0].bridge}' \
                        2>/dev/null || true)
                    if [ -n "$_ob" ]; then
                        printf "    %-35s %-15s %-20s %s\n" "$_n" "ovn-localnet" "$_ob" "-"
                    else
                        printf "    %-35s %-15s %-20s %s\n" "$_n" "unknown" "-" "-"
                    fi
                fi
            done
            echo ""
            local _first_nncp
            _first_nncp=$(echo "$_all_nncps" | head -1)
            read -r -p "  사용할 NNCP 이름을 입력하세요 [기본값: ${_first_nncp}]: " _input_nncp
            [ -z "$_input_nncp" ] && _input_nncp="$_first_nncp"
            NNCP_NAME="$_input_nncp"
            # 선택된 NNCP에서 bridge 이름 추출
            local _new_br
            _new_br=$(oc get nncp "$NNCP_NAME" \
                -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.name}{end}' \
                2>/dev/null || true)
            [ -z "$_new_br" ] && _new_br=$(oc get nncp "$NNCP_NAME" \
                -o jsonpath='{.spec.desiredState.ovn.bridge-mappings[0].bridge}' \
                2>/dev/null || true)
            [ -n "$_new_br" ] && BRIDGE_NAME="$_new_br"
            print_ok "NNCP '${NNCP_NAME}' 사용 (bridge: ${BRIDGE_NAME})"
        else
            print_warn "사용 가능한 NNCP가 없습니다. 먼저 02-network를 실행해 주세요."
        fi
    else
        local status
        status=$(oc get nncp "$NNCP_NAME" \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
        if [ "$status" = "True" ]; then
            print_ok "NNCP ${NNCP_NAME} Available"
        else
            print_warn "NNCP ${NNCP_NAME} 상태: ${status:-Unknown}"
        fi
    fi
}

# =============================================================================
# Step 1: Namespace 생성
# =============================================================================
step_namespace() {
    print_step "1/3  Namespace 생성 (${VM_NS})"

    if oc get namespace "${VM_NS}" &>/dev/null; then
        print_ok "Namespace ${VM_NS} 이미 존재합니다 — 건너뜀"
    else
        oc new-project "${VM_NS}" > /dev/null
        print_ok "Namespace ${VM_NS} 생성됨"
    fi
}

# spec.running (deprecated) → spec.runStrategy로 마이그레이션
ensure_runstrategy() {
    local vm="$1" ns="$2"
    local running
    running=$(oc get vm "$vm" -n "$ns" \
        -o jsonpath='{.spec.running}' 2>/dev/null || true)
    [ -z "$running" ] && return 0
    local rs="Halted"
    [ "$running" = "true" ] && rs="Always"
    oc patch vm "$vm" -n "$ns" --type=json -p "[
      {\"op\":\"remove\",\"path\":\"/spec/running\"},
      {\"op\":\"add\",\"path\":\"/spec/runStrategy\",\"value\":\"${rs}\"}
    ]" &>/dev/null || true
}

# =============================================================================
# Step 2: NAD 등록
# =============================================================================
step_nad() {
    print_step "2/4  NAD — NetworkAttachmentDefinition 등록 (${NAD_NAME} → ${VM_NS})"

    local nad_file="nad-${NAD_NAME}.yaml"
    if [ "$NNCP_IFACE_TYPE" = "ovs-bridge" ]; then
        if [ "$NET_TYPE" = "2" ]; then
            cat > "$nad_file" <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${VM_NS}
spec:
  config: |-
    {
        "cniVersion": "0.3.1",
        "name": "${LOCALNET_NAME}",
        "type": "ovn-k8s-cni-overlay",
        "topology": "localnet",
        "vlanID": ${VLAN_ID},
        "netAttachDefName": "${VM_NS}/${NAD_NAME}"
    }
EOF
        else
            cat > "$nad_file" <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${VM_NS}
spec:
  config: |-
    {
        "cniVersion": "0.3.1",
        "name": "${LOCALNET_NAME}",
        "type": "ovn-k8s-cni-overlay",
        "topology": "localnet",
        "netAttachDefName": "${VM_NS}/${NAD_NAME}"
    }
EOF
        fi
    elif [ "$NET_TYPE" = "2" ] && [ "$NNCP_IFACE_TYPE" != "vlan" ]; then
        cat > "$nad_file" <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${VM_NS}
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/${BRIDGE_NAME}
spec:
  config: |-
    {
        "cniVersion": "0.3.1",
        "name": "${NAD_NAME}",
        "type": "bridge",
        "bridge": "${BRIDGE_NAME}",
        "vlan": ${VLAN_ID},
        "ipam": {},
        "macspoofchk": true,
        "preserveDefaultVlan": false
    }
EOF
    else
        cat > "$nad_file" <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${VM_NS}
  annotations:
    k8s.v1.cni.cncf.io/resourceName: bridge.network.kubevirt.io/${BRIDGE_NAME}
spec:
  config: |-
    {
        "cniVersion": "0.3.1",
        "name": "${NAD_NAME}",
        "type": "bridge",
        "bridge": "${BRIDGE_NAME}",
        "ipam": {},
        "macspoofchk": true,
        "preserveDefaultVlan": false
    }
EOF
    fi
    echo "생성된 파일: ${nad_file}"
    oc apply -f "$nad_file"
    print_ok "NAD ${NAD_NAME} 등록됨 (namespace: ${VM_NS})"
}

# =============================================================================
# Step 3: VM 생성 (poc template + poc-bridge-nad)
# =============================================================================
step_vm() {
    print_step "3/4  VM 생성 (poc template + ${NAD_NAME})"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc Template을 찾을 수 없습니다 — VM 생성을 건너뜁니다. (먼저 01-template을 실행하세요)"
        return
    fi

    local VM_NAME="poc-vm"

    if oc get vm "$VM_NAME" -n "$VM_NS" &>/dev/null; then
        print_ok "VM $VM_NAME 이미 존재합니다 — 건너뜀"
        return
    fi

    local vm_yaml="${SCRIPT_DIR}/vm-${VM_NAME}.yaml"
    oc process -n openshift poc -p NAME="$VM_NAME" | \
        sed 's/runStrategy: Always/runStrategy: Halted/' | \
        sed 's/  running: false/  runStrategy: Halted/' > "${vm_yaml}"
    echo "생성된 파일: ${vm_yaml}"
    oc apply -n "$VM_NS" -f "${vm_yaml}"

    ensure_runstrategy "$VM_NAME" "$VM_NS"

    # 보조 NIC 추가
    oc patch vm "$VM_NAME" -n "$VM_NS" --type=json -p="[
      {
        \"op\": \"add\",
        \"path\": \"/spec/template/spec/domain/devices/interfaces/-\",
        \"value\": {\"name\": \"bridge-net\", \"bridge\": {}, \"model\": \"virtio\"}
      },
      {
        \"op\": \"add\",
        \"path\": \"/spec/template/spec/networks/-\",
        \"value\": {\"name\": \"bridge-net\", \"multus\": {\"networkName\": \"${NAD_NAME}\"}}
      }
    ]"

    # cloud-init networkData — eth1 고정 IP (03 → .31/24)
    local ci_idx
    ci_idx=$(oc get vm "$VM_NAME" -n "$VM_NS" \
        -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' 2>/dev/null | \
        grep -n "cloudinitdisk" | cut -d: -f1 | head -1)
    [ -n "$ci_idx" ] && ci_idx=$(( ci_idx - 1 ))

    if [ -n "$ci_idx" ]; then
        oc patch vm "$VM_NAME" -n "$VM_NS" --type=json -p="[
          {\"op\": \"add\",
           \"path\": \"/spec/template/spec/volumes/${ci_idx}/cloudInitNoCloud/networkData\",
           \"value\": \"version: 2\\nethernets:\\n  eth1:\\n    dhcp4: false\\n    addresses:\\n      - ${SECONDARY_IP_PREFIX}.31/24\\n    gateway4: ${SECONDARY_IP_PREFIX}.1\\n    nameservers:\\n      addresses:\\n        - 8.8.8.8\\n\"}
        ]"
        print_ok "networkData 추가됨 (eth1: ${SECONDARY_IP_PREFIX}.31/24)"
    else
        print_warn "cloudinitdisk volume을 찾을 수 없습니다. networkData가 설정되지 않았습니다."
    fi

    virtctl start "$VM_NAME" -n "$VM_NS" 2>/dev/null || true
    print_ok "VM ${VM_NAME} 생성됨 (eth0: masquerade, eth1: ${NAD_NAME}, IP: ${SECONDARY_IP_PREFIX}.31/24)"
}

# =============================================================================
# Step 4: ConsoleYAMLSample 등록
# =============================================================================
step_consoleyamlsamples() {
    print_step "4/4  ConsoleYAMLSample 등록"

    cat > consoleyamlsample-virtualmachine.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-virtualmachine
spec:
  title: "Create POC VirtualMachine (Bridge network + cloud-init static IP)"
  description: "Connect NAD ${NAD_NAME} (${NNCP_IFACE_TYPE}) as a secondary network to a poc template-based VM, and configure a static IP on eth1 via cloud-init."
  targetResource:
    apiVersion: kubevirt.io/v1
    kind: VirtualMachine
  yaml: |
    apiVersion: kubevirt.io/v1
    kind: VirtualMachine
    metadata:
      name: poc-vm
      namespace: ${VM_NS}
    spec:
      runStrategy: Halted
      template:
        spec:
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
                - bridge: {}
                  model: virtio
                  name: bridge-net
            memory:
              guest: 2Gi
          networks:
            - name: default
              pod: {}
            - name: bridge-net
              multus:
                networkName: ${NAD_NAME}
          volumes:
            - dataVolume:
                name: poc-vm
              name: rootdisk
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
                        - ${SECONDARY_IP_PREFIX}.10/24
                      gateway4: ${SECONDARY_IP_PREFIX}.1
                      nameservers:
                        addresses:
                          - 8.8.8.8
      dataVolumeTemplates:
        - metadata:
            name: poc-vm
          spec:
            sourceRef:
              kind: DataSource
              name: poc
              namespace: openshift-virtualization-os-images
            storage:
              resources:
                requests:
                  storage: 30Gi
EOF
    echo "생성된 파일: consoleyamlsample-virtualmachine.yaml"
    oc apply -f consoleyamlsample-virtualmachine.yaml
    print_ok "ConsoleYAMLSample poc-virtualmachine 등록됨"
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! VM 워크로드 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Namespace : ${CYAN}oc get namespace ${VM_NS}${NC}"
    echo -e "  NAD 확인  : ${CYAN}oc get net-attach-def -n ${VM_NS}${NC}"
    echo ""
    echo -e "  다음 단계: 03-vm-workload.md 참조"
    echo -e "    - poc template을 사용한 VM 생성"
    echo -e "    - 스토리지 추가"
    echo -e "    - 네트워크 추가"
    echo -e "    - 고정 IP / 도메인 / 라우터 구성"
    echo -e "    - Live Migration"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 03-vm-workload 리소스 삭제"
    oc delete project poc-vm --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-virtualmachine --ignore-not-found 2>/dev/null || true
    print_ok "03-vm-workload 리소스 삭제됨"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  VM 워크로드 — Namespace + NAD + VM (poc template + bridge network)${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_nad
    step_vm
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
