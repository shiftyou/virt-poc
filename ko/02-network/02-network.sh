#!/bin/bash
# =============================================================================
# 02-network.sh
#
# NNCP(NodeNetworkConfigurationPolicy) + NAD(NetworkAttachmentDefinition) 구성
# 4가지 네트워크 방식 중 하나를 선택하여 VM용 보조 네트워크를 설정합니다.
#
#   1. Linux Bridge          — cnv-bridge CNI, NMState NNCP
#   2. OVN Localnet          — ovn-k8s-cni-overlay, OVN bridge-mappings
#   3. Linux Bridge + VLAN   — cnv-bridge CNI + VLAN ID, trunk port
#   4. OVN Localnet + VLAN   — ovn-k8s-cni-overlay + vlanID
#
# 사용법: ./02-network.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

BRIDGE_INTERFACE="${BRIDGE_INTERFACE:-ens4}"
BRIDGE_NAME="${BRIDGE_NAME:-br1}"
NNCP_NAME="${NNCP_NAME:-${BRIDGE_NAME}-nncp}"
NAD_NAMESPACE="poc-network"
VLAN_ID="${VLAN_ID:-100}"
SECONDARY_IP_PREFIX="${SECONDARY_IP_PREFIX:-192.168.100}"

# 방식별로 설정되는 변수
NET_TYPE=""
NAD_NAME=""

source "${SCRIPT_DIR}/../utils/common.sh"

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
# 네트워크 방식 선택
# =============================================================================
choose_mode() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  네트워크 구성 방식 선택${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Linux Bridge"
    echo -e "     NNCP → Linux Bridge → cnv-bridge CNI"
    echo -e "     ${DIM}스위치: Access 또는 Trunk port (별도 스위치 설정 불필요)${NC}"
    echo -e "     ${DIM}용도  : 테스트/개발 환경, 빠른 설정${NC}"
    echo ""
    echo -e "  ${GREEN}2)${NC} Linux Bridge + VLAN filtering"
    echo -e "     NNCP → Linux Bridge trunk port → cnv-bridge + VLAN ID"
    echo -e "     ${DIM}스위치: Trunk port 필요 + VLAN이 허용 목록에 포함되어야 함${NC}"
    echo -e "     ${DIM}용도  : 테넌트/부서별 네트워크 격리 (하나의 NIC에 여러 VLAN)${NC}"
    echo ""
    echo -e "  현재 설정:"
    echo -e "    NNCP_NAME        : ${CYAN}${NNCP_NAME}${NC}"
    echo -e "    BRIDGE_NAME      : ${CYAN}${BRIDGE_NAME}${NC}"
    echo -e "    BRIDGE_INTERFACE : ${CYAN}${BRIDGE_INTERFACE}${NC}"
    echo -e "    Namespace        : ${CYAN}${NAD_NAMESPACE}${NC}"
    echo ""
    read -r -p "  선택 [1-2]: " NET_TYPE

    case "$NET_TYPE" in
        1)
            NAD_NAME="poc-bridge-nad"
            print_ok "선택됨: Linux Bridge"
            ;;
        2)
            NAD_NAME="poc-bridge-vlan-nad"
            echo ""
            read -r -p "  VLAN ID 입력 [기본값: ${VLAN_ID}]: " input_vlan
            [ -n "$input_vlan" ] && VLAN_ID="$input_vlan"
            print_ok "선택됨: Linux Bridge + VLAN ${VLAN_ID}"
            ;;
        *)
            print_error "1 또는 2를 입력해 주세요."
            exit 1
            ;;
    esac
}

# =============================================================================
# 사전 점검
# =============================================================================
preflight() {
    print_step "사전 점검"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 연결: $(oc whoami) @ $(oc whoami --show-server)"

    # NNCP 정보 표시
    echo ""
    print_info "── NNCP 정보 ──"
    print_info "  NNCP_NAME       : ${NNCP_NAME}"
    print_info "  BRIDGE_NAME     : ${BRIDGE_NAME}"
    print_info "  BRIDGE_INTERFACE: ${BRIDGE_INTERFACE}"
    _nncp_avail=$(oc get nncp "${NNCP_NAME}" \
        -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)
    if [ -n "$_nncp_avail" ]; then
        print_info "  클러스터 NNCP 상태: Available=${_nncp_avail}"
        oc get nnce 2>/dev/null | grep "${NNCP_NAME}" | \
            awk '{printf "    %-40s %s\n", $1, $2}' || true
    else
        print_info "  클러스터 NNCP 상태: 미적용 (새로 생성됩니다)"
    fi

    if [ "${NMSTATE_INSTALLED:-false}" != "true" ]; then
        if ! oc get csv -A 2>/dev/null | grep -qi "kubernetes-nmstate"; then
            print_warn "Kubernetes NMState Operator가 설치되지 않았습니다 → 건너뜀."
            print_warn "  설치 가이드: operators/nmstate-operator.md"
            exit 77
        fi
    fi
    print_ok "NMState Operator 확인됨"

    if ! oc get nmstate 2>/dev/null | grep -q "."; then
        print_warn "NMState CR을 찾을 수 없습니다. NMState 인스턴스를 생성합니다..."
        cat > nmstate-cr.yaml <<'NMEOF'
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
NMEOF
        oc apply -f nmstate-cr.yaml
        print_info "NMState handler가 준비될 때까지 대기 중 (최대 60초)..."
        oc rollout status daemonset/nmstate-handler -n openshift-nmstate --timeout=60s 2>/dev/null || true
        print_ok "NMState CR 생성됨"
    else
        print_ok "NMState CR 확인됨"
    fi
}

# =============================================================================
# NNCP 적용 완료 대기
# =============================================================================
_wait_nncp() {
    local name="$1"
    print_info "NNCP 적용됨 — 노드 설정 전파를 대기 중..."
    local retries=24 i=0
    while [ "$i" -lt "$retries" ]; do
        local status reason
        status=$(oc get nncp "$name" \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "")
        if [ "$status" = "True" ]; then
            print_ok "NNCP ${name} Available"
            break
        fi
        reason=$(oc get nncp "$name" \
            -o jsonpath='{.status.conditions[?(@.type=="Available")].reason}' 2>/dev/null || echo "")
        printf "  [%d/%d] 상태 대기 중... (%s)\r" "$((i+1))" "$retries" "${reason:-Pending}"
        sleep 5
        i=$((i+1))
    done
    echo ""
    if [ "$i" -eq "$retries" ]; then
        print_warn "NNCP 적용 시간 초과. 상태를 수동으로 확인하세요: oc get nncp / oc get nnce"
        return 1
    fi
    print_info "노드별 적용 상태 (NNCE):"
    oc get nnce 2>/dev/null | grep "$name" | \
        awk '{printf "    %-40s %s\n", $1, $2}' || true
}

# =============================================================================
# 새 NNCP 생성
# =============================================================================
_create_nncp() {
    local net_type="$1"

    echo ""
    print_step "새 NNCP 생성"

    # NNCP 이름 입력
    read -r -p "  NNCP 이름 입력 [${NNCP_NAME}]: " _input
    [ -n "$_input" ] && NNCP_NAME="$_input"

    # Bridge 이름 입력
    read -r -p "  Bridge 이름 입력 [${BRIDGE_NAME}]: " _input
    [ -n "$_input" ] && BRIDGE_NAME="$_input"

    # Bridge 인터페이스 입력
    read -r -p "  Bridge 인터페이스 (물리 NIC) 입력 [${BRIDGE_INTERFACE}]: " _input
    [ -n "$_input" ] && BRIDGE_INTERFACE="$_input"

    # MTU 설정 (선택사항)
    local mtu=""
    read -r -p "  MTU를 설정하시겠습니까? (기본값을 사용하려면 비워두세요): " mtu

    # NNCP YAML 생성
    if [ "$net_type" = "2" ]; then
        # Linux Bridge + VLAN
        {
            cat <<EOF
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ${NNCP_NAME}
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ''
  desiredState:
    interfaces:
      - name: ${BRIDGE_NAME}
        description: Linux bridge (VLAN trunk) with ${BRIDGE_INTERFACE} as a port
        type: linux-bridge
        state: up
EOF
            [ -n "${mtu}" ] && echo "        mtu: ${mtu}"
            cat <<EOF
        ipv4:
          enabled: false
        ipv6:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ${BRIDGE_INTERFACE}
              vlan:
                mode: trunk
                trunk-tags:
                  - id-range:
                      min: 1
                      max: 4094
EOF
        } > nncp-${NNCP_NAME}.yaml
    else
        # Linux Bridge (VLAN 없음)
        {
            cat <<EOF
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ${NNCP_NAME}
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ''
  desiredState:
    interfaces:
      - name: ${BRIDGE_NAME}
        description: Linux bridge with ${BRIDGE_INTERFACE} as a port
        type: linux-bridge
        state: up
EOF
            [ -n "${mtu}" ] && echo "        mtu: ${mtu}"
            cat <<EOF
        ipv4:
          enabled: false
        ipv6:
          enabled: false
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ${BRIDGE_INTERFACE}
EOF
        } > nncp-${NNCP_NAME}.yaml
    fi

    echo ""
    print_info "적용할 NNCP YAML:"
    echo "────────────────────────────────────────"
    cat nncp-${NNCP_NAME}.yaml
    echo "────────────────────────────────────────"
    echo ""
    read -r -p "이 NNCP를 클러스터에 적용하시겠습니까? [y/N]: " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        print_warn "NNCP 생성이 취소되었습니다."
        exit 1
    fi

    oc apply -f nncp-${NNCP_NAME}.yaml
    _wait_nncp "$NNCP_NAME" || {
        print_error "NNCP 생성 실패 또는 시간 초과."
        exit 1
    }
    print_ok "NNCP '${NNCP_NAME}' 생성 완료 (bridge: ${BRIDGE_NAME})"
}

# =============================================================================
# NNCP 상태 확인 및 선택 또는 생성
# =============================================================================
step_nncp() {
    print_step "1/4  NNCP 구성"

    # 기존 NNCP 조회
    local nncp_list
    nncp_list=$(oc get nncp -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Available")].status}{"\t"}{.spec.desiredState.interfaces[0].name}{"\n"}{end}' 2>/dev/null || true)

    if [ -z "$nncp_list" ]; then
        print_warn "클러스터에 NNCP가 없습니다."
        echo ""
        read -r -p "  지금 새 NNCP를 생성하시겠습니까? [Y/n]: " confirm
        if [[ "${confirm:-y}" =~ ^[Yy]$ ]]; then
            _create_nncp "$NET_TYPE"
        else
            print_error "NAD 생성에 NNCP가 필요합니다. 종료합니다."
            exit 1
        fi
    else
        echo ""
        print_info "클러스터의 기존 NNCP:"
        echo "────────────────────────────────────────────────────────────────────"
        printf "  %-4s %-30s %-12s %s\n" "번호" "NNCP 이름" "Available" "Bridge 이름"
        echo "────────────────────────────────────────────────────────────────────"

        local idx=1
        local -a nncp_names nncp_avails nncp_bridges
        while IFS=$'\t' read -r name avail bridge; do
            printf "  %-4s %-30s %-12s %s\n" "$idx)" "$name" "${avail:-Unknown}" "$bridge"
            nncp_names+=("$name")
            nncp_avails+=("$avail")
            nncp_bridges+=("$bridge")
            idx=$((idx+1))
        done <<< "$nncp_list"

        echo "────────────────────────────────────────────────────────────────────"
        echo ""
        echo "  0) 새 NNCP 생성"
        echo ""

        local selection
        read -r -p "  NNCP 선택 [1-$((idx-1)), 또는 0으로 새로 생성]: " selection

        if [ "$selection" = "0" ]; then
            _create_nncp "$NET_TYPE"
        elif [ "$selection" -ge 1 ] && [ "$selection" -lt "$idx" ]; then
            local arr_idx=$((selection-1))
            NNCP_NAME="${nncp_names[$arr_idx]}"
            BRIDGE_NAME="${nncp_bridges[$arr_idx]}"
            local avail="${nncp_avails[$arr_idx]}"
            print_ok "선택된 NNCP: ${NNCP_NAME} (bridge: ${BRIDGE_NAME}, Available: ${avail})"

            # 노드별 상태 표시
            echo ""
            print_info "노드별 적용 상태 (NNCE):"
            oc get nnce 2>/dev/null | grep "${NNCP_NAME}" | \
                awk '{printf "    %-40s %s\n", $1, $2}' || true
        else
            print_error "잘못된 선택: ${selection}"
            exit 1
        fi
    fi
}

# =============================================================================
# NAD — 방식별 등록
# =============================================================================
_ensure_namespace() {
    oc new-project "${NAD_NAMESPACE}" >/dev/null 2>&1 || \
        oc project "${NAD_NAMESPACE}" >/dev/null 2>&1 || true
    print_ok "Namespace: ${NAD_NAMESPACE}"
}

step_nad_linux_bridge() {
    print_step "2/4  NAD — Linux Bridge (bridge)"
    _ensure_namespace

    cat > nad-${NAD_NAME}.yaml <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${NAD_NAMESPACE}
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
    echo "생성된 파일: nad-${NAD_NAME}.yaml"
    oc apply -f nad-${NAD_NAME}.yaml
    print_ok "NAD ${NAD_NAME} 등록됨"
}

step_nad_linux_bridge_vlan() {
    print_step "2/4  NAD — Linux Bridge + VLAN ${VLAN_ID} (bridge)"
    _ensure_namespace

    cat > nad-${NAD_NAME}.yaml <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${NAD_NAMESPACE}
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
    echo "생성된 파일: nad-${NAD_NAME}.yaml"
    oc apply -f nad-${NAD_NAME}.yaml
    print_ok "NAD ${NAD_NAME} 등록됨 (VLAN ${VLAN_ID})"
}

# poc-로 시작하는 모든 namespace에 NAD 배포
_deploy_nad_to_poc_namespaces() {
    local nad_file="nad-${NAD_NAME}.yaml"

    # NAD_NAMESPACE를 제외한 poc- namespace 목록
    local poc_namespaces
    poc_namespaces=$(oc get namespaces \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
        tr ' ' '\n' | grep '^poc-' | grep -v "^${NAD_NAMESPACE}$" || true)

    [ -z "$poc_namespaces" ] && return 0

    print_info "NAD (${NAD_NAME})를 다음 poc- namespace에 추가 배포할 수 있습니다:"
    echo ""
    for ns in $poc_namespaces; do
        echo "    - ${ns}"
    done
    echo ""
    read -r -p "  이 namespace들에도 NAD를 배포하시겠습니까? [y/N]: " _nad_confirm
    if [[ "$_nad_confirm" != "y" && "$_nad_confirm" != "Y" ]]; then
        print_info "추가 배포를 건너뜁니다."
        return 0
    fi

    print_info "추가 poc- namespace에 NAD 배포 중..."
    for ns in $poc_namespaces; do
        sed "s|namespace: ${NAD_NAMESPACE}|namespace: ${ns}|g" \
            "$nad_file" | oc apply -f -
        print_ok "  NAD ${NAD_NAME} → ${ns}"
    done
}

step_nad() {
    case "$NET_TYPE" in
        1) step_nad_linux_bridge ;;
        2) step_nad_linux_bridge_vlan ;;
    esac
    _deploy_nad_to_poc_namespaces
}

# =============================================================================
# VM 생성 (poc template + 선택된 NAD)
# =============================================================================
step_vm() {
    print_step "3/4  VM 생성 (poc template + ${NAD_NAME})"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc Template을 찾을 수 없습니다 — VM 생성을 건너뜁니다. (먼저 01-template을 실행하세요)"
        return
    fi

    local ip_suffixes=(21 22)
    local idx=0

    for suffix in 1 2; do
        local VM_NAME="poc-network-vm-${suffix}"
        local ip_suffix="${ip_suffixes[$idx]}"
        idx=$((idx + 1))

        if oc get vm "$VM_NAME" -n "$NAD_NAMESPACE" &>/dev/null; then
            print_ok "VM $VM_NAME 이미 존재합니다 — 건너뜀"
            continue
        fi

        local vm_yaml="${SCRIPT_DIR}/vm-${VM_NAME}.yaml"
        oc process -n openshift poc -p NAME="$VM_NAME" | \
            sed 's/runStrategy: Always/runStrategy: Halted/' | sed 's/  running: false/  runStrategy: Halted/' > "${vm_yaml}"
        echo "생성된 파일: ${vm_yaml}"
        oc apply -n "$NAD_NAMESPACE" -f "${vm_yaml}"

        ensure_runstrategy "$VM_NAME" "$NAD_NAMESPACE"

        # 보조 NIC 추가 (NAD)
        oc patch vm "$VM_NAME" -n "$NAD_NAMESPACE" --type=json -p='[
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

        # cloud-init networkData — 기존 cloudinitdisk volume에 networkData 추가 (VM 시작 전)
        local ci_idx
        ci_idx=$(oc get vm "$VM_NAME" -n "$NAD_NAMESPACE" \
            -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' 2>/dev/null | \
            grep -n "cloudinitdisk" | cut -d: -f1 | head -1)
        # grep -n은 1-based, JSON patch는 0-based
        [ -n "$ci_idx" ] && ci_idx=$(( ci_idx - 1 ))

        if [ -n "$ci_idx" ]; then
            oc patch vm "$VM_NAME" -n "$NAD_NAMESPACE" --type=json -p="[
              {\"op\": \"add\",
               \"path\": \"/spec/template/spec/volumes/${ci_idx}/cloudInitNoCloud/networkData\",
               \"value\": \"version: 2\\nethernets:\\n  eth1:\\n    dhcp4: false\\n    addresses:\\n      - ${SECONDARY_IP_PREFIX}.${ip_suffix}/24\\n    gateway4: ${SECONDARY_IP_PREFIX}.1\\n    nameservers:\\n      addresses:\\n        - 8.8.8.8\\n\"}
            ]"
            print_ok "networkData 추가됨 → cloudinitdisk (index: ${ci_idx})"
        else
            print_warn "cloudinitdisk volume을 찾을 수 없습니다. networkData가 설정되지 않았습니다."
        fi

        virtctl start "$VM_NAME" -n "$NAD_NAMESPACE" 2>/dev/null || true
        print_ok "VM ${VM_NAME} 생성됨 (eth0: masquerade, eth1: ${NAD_NAME}, IP: ${SECONDARY_IP_PREFIX}.${ip_suffix}/24)"
    done
}

# =============================================================================
# ConsoleYAMLSample 등록
# =============================================================================
step_consoleyamlsamples() {
    print_step "4/4  ConsoleYAMLSample 등록"

    # NNCP 샘플 — 방식별
    local nncp_title nncp_desc nncp_yaml
    case "$NET_TYPE" in
        1)
            nncp_title="POC Linux Bridge NNCP"
            nncp_desc="Creates a Linux Bridge (${BRIDGE_NAME}) on worker nodes."
            nncp_yaml="$(cat <<YAML
    apiVersion: nmstate.io/v1
    kind: NodeNetworkConfigurationPolicy
    metadata:
      name: ${NNCP_NAME}
    spec:
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      desiredState:
        interfaces:
          - name: ${BRIDGE_NAME}
            type: linux-bridge
            state: up
            ipv4:
              enabled: false
            bridge:
              options:
                stp:
                  enabled: false
              port:
                - name: ${BRIDGE_INTERFACE}
YAML
)"
            ;;
        2)
            nncp_title="POC Linux Bridge VLAN trunk NNCP"
            nncp_desc="Creates a Linux Bridge (${BRIDGE_NAME}) with VLAN trunk port on worker nodes."
            nncp_yaml="$(cat <<YAML
    apiVersion: nmstate.io/v1
    kind: NodeNetworkConfigurationPolicy
    metadata:
      name: ${NNCP_NAME}
    spec:
      nodeSelector:
        node-role.kubernetes.io/worker: ""
      desiredState:
        interfaces:
          - name: ${BRIDGE_NAME}
            type: linux-bridge
            state: up
            ipv4:
              enabled: false
            bridge:
              options:
                stp:
                  enabled: false
              port:
                - name: ${BRIDGE_INTERFACE}
                  vlan:
                    mode: trunk
                    trunk-tags:
                      - id-range:
                          min: 1
                          max: 4094
YAML
)"
            ;;
    esac

    cat > consoleyamlsample-nncp.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: ${NNCP_NAME}
spec:
  title: "${nncp_title}"
  description: "${nncp_desc}"
  targetResource:
    apiVersion: nmstate.io/v1
    kind: NodeNetworkConfigurationPolicy
  yaml: |
${nncp_yaml}
EOF
    echo "생성된 파일: consoleyamlsample-nncp.yaml"
    oc apply -f consoleyamlsample-nncp.yaml
    print_ok "ConsoleYAMLSample ${NNCP_NAME} 등록됨"

    # NAD 샘플 — 방식별 config 블록 생성
    local nad_config_block
    case "$NET_TYPE" in
        1) nad_config_block="    {
        \"cniVersion\": \"0.3.1\",
        \"name\": \"${NAD_NAME}\",
        \"type\": \"bridge\",
        \"bridge\": \"${BRIDGE_NAME}\",
        \"ipam\": {},
        \"macspoofchk\": true,
        \"preserveDefaultVlan\": false
    }" ;;
        2) nad_config_block="    {
        \"cniVersion\": \"0.3.1\",
        \"name\": \"${NAD_NAME}\",
        \"type\": \"bridge\",
        \"bridge\": \"${BRIDGE_NAME}\",
        \"vlan\": ${VLAN_ID},
        \"ipam\": {},
        \"macspoofchk\": true,
        \"preserveDefaultVlan\": false
    }" ;;
    esac

    cat > consoleyamlsample-nad.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: ${NAD_NAME}
spec:
  title: "POC NAD — ${NAD_NAME}"
  description: "Register as VM secondary network after applying NNCP. (Method: $(echo "$NET_TYPE" | sed 's/1/Linux Bridge/;s/2/Linux Bridge+VLAN/'))"
  targetResource:
    apiVersion: k8s.cni.cncf.io/v1
    kind: NetworkAttachmentDefinition
  yaml: |
    apiVersion: k8s.cni.cncf.io/v1
    kind: NetworkAttachmentDefinition
    metadata:
      name: ${NAD_NAME}
      namespace: ${NAD_NAMESPACE}
    spec:
      config: |-
${nad_config_block}
EOF
    echo "생성된 파일: consoleyamlsample-nad.yaml"
    oc apply -f consoleyamlsample-nad.yaml
    print_ok "ConsoleYAMLSample ${NAD_NAME} 등록됨"
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    local mode_label
    case "$NET_TYPE" in
        1) mode_label="Linux Bridge" ;;
        2) mode_label="Linux Bridge + VLAN ${VLAN_ID}" ;;
    esac

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! 네트워크 구성 (${mode_label})${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  NNCP 상태 : ${CYAN}oc get nncp${NC}"
    echo -e "  NNCE 상태 : ${CYAN}oc get nnce${NC}"
    echo -e "  NAD 확인  : ${CYAN}oc get net-attach-def -n ${NAD_NAMESPACE}${NC}"
    echo -e "  VM 상태   : ${CYAN}oc get vm,vmi -n ${NAD_NAMESPACE}${NC}"
    echo ""
    echo -e "  VM IP (eth1):"
    echo -e "    poc-network-vm-1 : ${CYAN}${SECONDARY_IP_PREFIX}.21/24${NC}"
    echo -e "    poc-network-vm-2 : ${CYAN}${SECONDARY_IP_PREFIX}.22/24${NC}"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 02-network 리소스 삭제"
    oc delete vm poc-network-vm-1 poc-network-vm-2 -n poc-network --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-bridge-nncp poc-bridge-nad poc-bridge-vlan-nad --ignore-not-found 2>/dev/null || true
    oc delete project poc-network --ignore-not-found 2>/dev/null || true
    echo ""
    for _nncp in $(oc get nncp -o name 2>/dev/null | grep poc- || true); do
        local _name="${_nncp#*/}"
        read -r -p "NNCP ${_name}을(를) 삭제하시겠습니까? 노드 bridge가 제거됩니다. [y/N]: " _del
        [[ "$_del" = "y" || "$_del" = "Y" ]] && oc delete nncp "$_name" --ignore-not-found 2>/dev/null || true
    done
    print_ok "02-network 리소스 삭제됨"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  02-network: NNCP + NAD + VM 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    choose_mode
    preflight
    step_nncp
    step_nad
    step_vm
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
