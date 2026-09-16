#!/bin/bash
# =============================================================================
# virt-poc 환경 설정 스크립트
# OpenShift Virtualization POC 테스트를 위한 공통 환경 변수를 수집하고
# env.conf 파일을 생성합니다.
#
# Lab별 변수 (S3, IPMI, Grafana, Alert 등)는 각 lab 스크립트 실행 시
# 자동으로 env.conf에 추가됩니다.
#
# 사용법: ./setup.sh
# =============================================================================

set -euo pipefail
trap 'echo -e "\n\033[0;31m[오류]\033[0m ${LINENO}번째 줄에서 명령 실패: ${BASH_COMMAND}" >&2' ERR

ENV_FILE="./env.conf"
EXAMPLE_FILE="./env.conf.example"

source "$(dirname "${BASH_SOURCE[0]}")/utils/common.sh"

# oc 명령어 확인
check_oc() {
    if ! command -v oc &> /dev/null; then
        print_warn "oc 명령어를 찾을 수 없습니다. OpenShift 클러스터 연결 없이 설정을 저장합니다."
        return 1
    fi

    if ! oc whoami &> /dev/null; then
        print_warn "OpenShift 클러스터에 로그인되어 있지 않습니다. 설정만 저장합니다."
        return 1
    fi

    print_ok "OpenShift 클러스터 연결 확인됨: $(oc whoami)"
    return 0
}

# Operator 설치 확인
check_operators() {
    print_header "사전 요구 사항: Operator 설치 확인"

    VIRT_INSTALLED=false
    MTV_INSTALLED=false
    DESCHEDULER_INSTALLED=false
    FAR_INSTALLED=false
    NMO_INSTALLED=false
    NHC_INSTALLED=false
    SNR_INSTALLED=false
    NMSTATE_INSTALLED=false
    OADP_INSTALLED=false
    OADP_NS="openshift-adp"
    GRAFANA_INSTALLED=false
    COO_INSTALLED=false
    ODF_INSTALLED=false
    LOGGING_INSTALLED=false
    LOKI_INSTALLED=false

    if check_oc 2>/dev/null; then
        oc get csv -A 2>/dev/null > /tmp/_poc_csv.txt || true

        grep -qi "kubevirt-hyperconverged"   /tmp/_poc_csv.txt 2>/dev/null && VIRT_INSTALLED=true
        grep -qi "mtv-operator"              /tmp/_poc_csv.txt 2>/dev/null && MTV_INSTALLED=true
        grep -qi "kube-descheduler"          /tmp/_poc_csv.txt 2>/dev/null && DESCHEDULER_INSTALLED=true
        grep -qi "fence-agents-remediation"  /tmp/_poc_csv.txt 2>/dev/null && FAR_INSTALLED=true
        grep -qi "node-maintenance"          /tmp/_poc_csv.txt 2>/dev/null && NMO_INSTALLED=true
        grep -qi "node-healthcheck"          /tmp/_poc_csv.txt 2>/dev/null && NHC_INSTALLED=true
        grep -qi "self-node-remediation"     /tmp/_poc_csv.txt 2>/dev/null && SNR_INSTALLED=true
        grep -qi "kubernetes-nmstate"        /tmp/_poc_csv.txt 2>/dev/null && NMSTATE_INSTALLED=true
        if grep -qi "oadp-operator" /tmp/_poc_csv.txt 2>/dev/null; then
            OADP_INSTALLED=true
            OADP_NS=$(oc get subscription -A 2>/dev/null | grep -i "oadp\|redhat-oadp" | awk '{print $1}' | head -1)
            OADP_NS="${OADP_NS:-openshift-adp}"
        fi
        grep -qi "grafana-operator"               /tmp/_poc_csv.txt 2>/dev/null && GRAFANA_INSTALLED=true
        grep -qi "cluster-observability-operator" /tmp/_poc_csv.txt 2>/dev/null && COO_INSTALLED=true
        grep -qi "odf-operator\|ocs-operator"     /tmp/_poc_csv.txt 2>/dev/null && ODF_INSTALLED=true
        grep -qi "cluster-logging"                /tmp/_poc_csv.txt 2>/dev/null && LOGGING_INSTALLED=true
        grep -qi "loki-operator"                  /tmp/_poc_csv.txt 2>/dev/null && LOKI_INSTALLED=true
        rm -f /tmp/_poc_csv.txt
        NMSTATE_CR_EXISTS=false
        if [ "$NMSTATE_INSTALLED" = "true" ]; then
            oc get nmstate 2>/dev/null | grep -q "." && NMSTATE_CR_EXISTS=true || true
        fi
    else
        print_warn "클러스터에 연결되어 있지 않아 Operator 상태를 확인할 수 없습니다."
        print_info "Operator 설치 방법: operators/README.md 참조"
        echo ""
        return
    fi

    local ok="${GREEN}[✔]${NC}"
    local ng="${RED}[✘]${NC}"
    local wa="${YELLOW}[~]${NC}"

    echo ""
    printf "  %-45s %s\n" "Operator" "상태"
    echo "  ──────────────────────────────────────────────────────────"
    if [ "$VIRT_INSTALLED" = "true" ]; then
        echo -e "  $ok OpenShift Virtualization Operator  → Virtualization 사용 가능"
    else
        echo -e "  $ng OpenShift Virtualization Operator  → 미설치  (operators/)"
    fi
    if [ "$MTV_INSTALLED" = "true" ]; then
        echo -e "  $ok Migration Toolkit for Virt Operator → MTV 사용 가능"
    else
        echo -e "  $ng Migration Toolkit for Virt Operator → 미설치"
    fi
    if [ "$NMSTATE_INSTALLED" = "true" ] && [ "${NMSTATE_CR_EXISTS:-false}" = "true" ]; then
        echo -e "  $ok Kubernetes NMState Operator        → NodeNetworkState 조회 가능"
    elif [ "$NMSTATE_INSTALLED" = "true" ]; then
        echo -e "  $wa Kubernetes NMState Operator        → NMState CR 없음 (oc apply -f nmstate-cr.yaml 필요)  (operators/nmstate-operator.md)"
    else
        echo -e "  $ng Kubernetes NMState Operator        → NNCP/NNS 사용 불가  (operators/nmstate-operator.md)"
    fi
    if [ "$DESCHEDULER_INSTALLED" = "true" ]; then
        echo -e "  $ok Kube Descheduler Operator          → Descheduler 설정 가능"
    else
        echo -e "  $ng Kube Descheduler Operator          → Descheduler 건너뜀  (operators/descheduler-operator.md)"
    fi
    if [ "$ODF_INSTALLED" = "true" ]; then
        echo -e "  $ok ODF Operator                       → OpenShift Data Foundation 사용 가능"
    else
        echo -e "  $ng ODF Operator                       → 미설치"
    fi
    if [ "$OADP_INSTALLED" = "true" ]; then
        echo -e "  $ok OADP Operator                      → 백업/복원 설정 가능  (ns: ${OADP_NS})"
    else
        echo -e "  $ng OADP Operator                      → 백업/복원 건너뜀  (operators/oadp-operator.md)"
    fi
    if [ "$GRAFANA_INSTALLED" = "true" ]; then
        echo -e "  $ok Grafana Community Operator         → Grafana 대시보드 설정 가능"
    else
        echo -e "  $ng Grafana Community Operator         → 미설치  (11-monitoring.md 참조)"
    fi
    if [ "$COO_INSTALLED" = "true" ]; then
        echo -e "  $ok Cluster Observability Operator     → MonitoringStack 사용 가능"
    else
        echo -e "  $ng Cluster Observability Operator     → 건너뜀  (operators/coo-operator.md)"
    fi
    if [ "$FAR_INSTALLED" = "true" ]; then
        echo -e "  $ok Fence Agents Remediation Operator  → FAR 설정 가능"
    else
        echo -e "  $ng Fence Agents Remediation Operator  → FAR 건너뜀  (operators/far-operator.md)"
    fi
    if [ "$NMO_INSTALLED" = "true" ]; then
        echo -e "  $ok Node Maintenance Operator          → 노드 유지보수 사용 가능"
    else
        echo -e "  $ng Node Maintenance Operator          → 노드 유지보수 건너뜀  (operators/node-maintenance-operator.md)"
    fi
    if [ "$NHC_INSTALLED" = "true" ]; then
        echo -e "  $ok Node Health Check Operator         → NHC 설정 가능"
    else
        echo -e "  $ng Node Health Check Operator         → NHC 건너뜀  (operators/nhc-operator.md)"
    fi
    if [ "$SNR_INSTALLED" = "true" ]; then
        echo -e "  $ok Self Node Remediation Operator     → SNR 설정 가능"
    else
        echo -e "  $ng Self Node Remediation Operator     → SNR 건너뜀  (operators/snr-operator.md)"
    fi
    if [ "$LOGGING_INSTALLED" = "true" ]; then
        echo -e "  $ok OpenShift Logging Operator         → 로그 수집 설정 가능"
    else
        echo -e "  $ng OpenShift Logging Operator         → 미설치"
    fi
    if [ "$LOKI_INSTALLED" = "true" ]; then
        echo -e "  $ok Loki Operator                      → LokiStack 설정 가능"
    else
        echo -e "  $ng Loki Operator                      → 미설치"
    fi
    echo "  ──────────────────────────────────────────────────────────"
    echo ""
}

# 클러스터 정보 자동 감지
auto_detect_cluster() {
    if check_oc; then
        DETECTED_API=$(oc whoami --show-server 2>/dev/null || echo "")
        DETECTED_DOMAIN=$(oc get ingresses.config/cluster -o jsonpath='{.spec.domain}' 2>/dev/null | sed 's/^apps\.//' || echo "")
        if [ -n "$DETECTED_API" ]; then
            print_info "감지된 API 서버: $DETECTED_API"
        fi
        if [ -n "$DETECTED_DOMAIN" ]; then
            print_info "감지된 클러스터 도메인: $DETECTED_DOMAIN"
        fi

        # StorageClass 자동 감지: virtualization 전용 → ceph-rbd 계열 → default
        DETECTED_SC=$(oc get sc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | \
            grep -i "virtualization" | head -1 || true)
        if [ -z "$DETECTED_SC" ]; then
            DETECTED_SC=$(oc get sc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | \
                grep -i "ceph-rbd" | head -1 || true)
        fi
        if [ -z "$DETECTED_SC" ]; then
            DETECTED_SC=$(oc get sc -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null || echo "")
        fi
        if [ -n "$DETECTED_SC" ]; then
            print_info "감지된 StorageClass: $DETECTED_SC"
        fi
        ALL_SC=$(oc get sc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | tr '\n' ' ' || echo "")
        if [ -n "$ALL_SC" ]; then
            print_info "사용 가능한 StorageClass: $ALL_SC"
        fi

        # 노드 네트워크 인터페이스 자동 감지
        FIRST_WORKER_FOR_NNS=$(oc get nodes -l node-role.kubernetes.io/worker \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        DETECTED_IFACES=""
        if [ -n "$FIRST_WORKER_FOR_NNS" ]; then
            local brex_slaves
            brex_slaves=$(oc get nns "$FIRST_WORKER_FOR_NNS" \
                -o jsonpath='{range .status.currentState.interfaces[*]}{.name}{" "}{.controller}{"\n"}{end}' \
                2>/dev/null | awk '$2=="br-ex"{print $1}' | tr '\n' '|' | sed 's/|$//' || true)
            DETECTED_IFACES=$(oc get nns "$FIRST_WORKER_FOR_NNS" \
                -o jsonpath='{range .status.currentState.interfaces[*]}{.name}{" "}{.type}{" "}{.state}{"\n"}{end}' \
                2>/dev/null | awk '$2=="ethernet" && $3=="up"{print $1}' | \
                grep -vE "^(br-ex|ovs-system)${brex_slaves:+|${brex_slaves}}" | \
                tr '\n' ' ' | xargs || true)
        fi
        if [ -z "$DETECTED_IFACES" ] && [ -n "$FIRST_WORKER_FOR_NNS" ]; then
            if [ "${NMSTATE_INSTALLED:-false}" = "true" ] && [ "${NMSTATE_CR_EXISTS:-false}" != "true" ]; then
                print_warn "NMState Operator가 설치되어 있지만 NMState CR이 없습니다."
                print_info "NodeNetworkState를 사용하려면: oc apply -f - <<'EOF'
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
EOF"
            fi
            print_info "NodeNetworkState 없음 → oc debug node로 인터페이스 감지 중 (약 30초 소요)..."
            DETECTED_IFACES=$(oc debug node/"$FIRST_WORKER_FOR_NNS" -- \
                chroot /host ip -o link show 2>/dev/null | \
                awk '/[Ss]tate UP/ && !/master ovs-system/ && !/master br-ex/ {split($2,a,"@"); gsub(/:$/,"",a[1]); print a[1]}' | \
                grep -vE '^(lo|ovs-system|br-ex|br-int|genev_sys|veth|tun|docker|ovn)' | \
                grep -E '^(ens|eth|eno|enp|em|bond)' | tr '\n' ' ' | xargs || true)
        fi
        DETECTED_IFACE=$(echo "$DETECTED_IFACES" | awk '{print $1}')
        if [ -n "$DETECTED_IFACES" ]; then
            print_info "감지된 네트워크 인터페이스 (노드: $FIRST_WORKER_FOR_NNS): $DETECTED_IFACES"
        fi
    else
        DETECTED_API=""
        DETECTED_DOMAIN=""
        DETECTED_SC=""
        DETECTED_IFACE=""
        DETECTED_IFACES=""
    fi
}

# =============================================================================
# 메인 실행
# =============================================================================

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}  OpenShift Virtualization POC 환경 설정${NC}"
echo -e "${CYAN}  virt-poc setup.sh${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# OpenShift 클러스터 로그인 확인
if ! command -v oc &>/dev/null; then
    print_error "oc 명령어를 찾을 수 없습니다. OpenShift CLI를 설치하세요."
    exit 1
fi
if ! oc whoami &>/dev/null; then
    print_error "OpenShift 클러스터에 로그인되어 있지 않습니다."
    print_info "'oc login'으로 먼저 클러스터에 로그인하세요."
    exit 1
fi
print_ok "클러스터 연결 확인됨: $(oc whoami) @ $(oc whoami --show-server 2>/dev/null)"
echo ""

# 기존 env.conf 확인
if [ -f "$ENV_FILE" ]; then
    print_warn "기존 env.conf 파일이 발견되었습니다."
    echo -n -e "${YELLOW}  덮어쓰시겠습니까? (y/N): ${NC}"
    read overwrite
    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
        print_info "설정이 취소되었습니다. 기존 env.conf 파일을 사용합니다."
        exit 0
    fi
fi

# 클러스터 자동 감지 및 Operator 확인
auto_detect_cluster
check_operators

# =============================================================================
# [01] Template — DataVolume / DataSource / Template 등록
# =============================================================================
print_step_header "[01]" "Template — DataVolume / DataSource / Template 등록"

ask "VM 이미지 업로드에 사용할 StorageClass" "${DETECTED_SC:-ocs-external-storagecluster-ceph-rbd}" STORAGE_CLASS
ask "poc-golden.qcow2 이미지 다운로드 URL" "http://146.56.160.95/poc-golden.qcow2" GOLDEN_IMAGE_URL

# =============================================================================
# [02] Network — NNCP / NAD / VM 생성
# =============================================================================
print_step_header "[02]" "Network — NNCP / NAD / VM 생성"

# NNCP 목록 표시 및 유형별 선택
NNCP_NAME="br-poc-nncp"
NNCP_IFACE_TYPE="linux-bridge"
NET_TYPE="1"
NAD_NAME="poc-bridge-nad"
LOCALNET_NAME="poc-localnet"
VLAN_ID="100"
BOND_NAME="bond0"
BOND_MODE="active-backup"
BOND_INTERFACE_2="ens5"
_USE_EXISTING_NNCP=false
_NNCP_NAMES=()

if command -v oc &>/dev/null && oc whoami &>/dev/null 2>&1; then
    _ALL_NNCPS=$(oc get nncp -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' || true)

    if [ -n "$_ALL_NNCPS" ]; then
        echo ""
        print_info "현재 클러스터 NNCP 목록:"
        echo ""
        printf "  %-4s %-28s %-12s %-14s %-8s %s\n" "번호" "NNCP 이름" "유형" "Bridge" "상태" "NIC"
        echo "  ──────────────────────────────────────────────────────────────────────────────"
        _idx=1
        while read -r _n; do
            [ -z "$_n" ] && continue
            detect_nncp_type "$_n"
            _avail=$(oc get nncp "$_n" \
                -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' \
                2>/dev/null || true)
            printf "  ${GREEN}%-4s %-28s %-12s %-14s %-8s %s${NC}\n" \
                "${_idx})" "$_n" "$(nncp_type_label "$NNCP_IFACE_TYPE")" \
                "${BRIDGE_NAME:-N/A}" "${_avail:-알 수 없음}" "${BRIDGE_INTERFACE:-N/A}"
            _NNCP_NAMES+=("$_n")
            _idx=$((_idx + 1))
        done <<< "$_ALL_NNCPS"
        echo ""
        echo "  0) 새 NNCP 생성 (Linux Bridge / OVS / Bond / VLAN)"
        echo ""
        read -r -p "  NNCP 선택 [1-$((_idx-1)), 또는 0으로 새로 생성, Enter=건너뛰기]: " _sel_input
        if [ -n "$_sel_input" ] && [ "$_sel_input" != "0" ]; then
            if [[ "$_sel_input" =~ ^[0-9]+$ ]] && [ "$_sel_input" -ge 1 ] && [ "$_sel_input" -lt "$_idx" ]; then
                NNCP_NAME="${_NNCP_NAMES[$((_sel_input-1))]}"
                detect_nncp_type "$NNCP_NAME"
                select_localnet
                _USE_EXISTING_NNCP=true
                print_ok "선택됨: ${NNCP_NAME} (유형: $(nncp_type_label "$NNCP_IFACE_TYPE"), bridge: ${BRIDGE_NAME})"
            else
                NNCP_NAME="$_sel_input"
                detect_nncp_type "$NNCP_NAME"
                select_localnet
                _USE_EXISTING_NNCP=true
                print_ok "선택됨: ${NNCP_NAME}"
            fi
        elif [ "$_sel_input" = "0" ]; then
            _USE_EXISTING_NNCP=false
        fi
    else
        echo ""
        print_info "클러스터에 NNCP가 없습니다."
    fi
fi

if [ "$_USE_EXISTING_NNCP" = "false" ]; then
    echo ""
    if [ -n "${DETECTED_IFACES:-}" ]; then
        print_info "감지된 인터페이스 목록: $DETECTED_IFACES"
    else
        print_info "노드 네트워크 인터페이스 확인: oc debug node/<node> -- ip link show"
    fi
    BRIDGE_INTERFACE="${DETECTED_IFACE:-ens4}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Linux Bridge"
    echo -e "  ${GREEN}2)${NC} OVS Bridge (OVN Localnet)"
    echo -e "  ${GREEN}3)${NC} Bond + Linux Bridge"
    echo -e "  ${GREEN}4)${NC} VLAN + Linux Bridge"
    echo ""
    read -r -p "  NNCP 유형 선택 [1-4, Enter=1]: " _iface_sel
    case "${_iface_sel:-1}" in
        1) NNCP_IFACE_TYPE="linux-bridge"; BRIDGE_NAME="br-poc"; NNCP_NAME="${BRIDGE_NAME}-nncp"; _gen_type=1 ;;
        2) NNCP_IFACE_TYPE="ovs-bridge"; BRIDGE_NAME="ovs-br-poc"; NNCP_NAME="${BRIDGE_NAME}-nncp"; _gen_type=3 ;;
        3) NNCP_IFACE_TYPE="bond"; BRIDGE_NAME="br-poc"; NNCP_NAME="${BRIDGE_NAME}-bond-nncp"; _gen_type=4 ;;
        4) NNCP_IFACE_TYPE="vlan"; BRIDGE_NAME="br-poc"; NNCP_NAME="${BRIDGE_NAME}-vlan-nncp"; _gen_type=5 ;;
        *) NNCP_IFACE_TYPE="linux-bridge"; BRIDGE_NAME="br-poc"; NNCP_NAME="${BRIDGE_NAME}-nncp"; _gen_type=1 ;;
    esac
    print_info "  NIC       : ${BRIDGE_INTERFACE}"
    print_info "  NNCP 이름 : ${NNCP_NAME}"
    echo ""
    echo -n -e "${YELLOW}  지금 nncp-gen.sh를 실행하여 NNCP를 생성하시겠습니까? (Y/n): ${NC}"
    read _run_nncp_gen
    if [[ ! "${_run_nncp_gen:-}" =~ ^[Nn]$ ]]; then
        _SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        export BRIDGE_NAME BRIDGE_INTERFACE NNCP_NAME LOCALNET_NAME BOND_NAME BOND_MODE BOND_INTERFACE_2 VLAN_ID
        bash "${_SETUP_DIR}/02-network/nncp-gen.sh" "$_gen_type"
    fi
fi

resolve_nad_name
print_info "  NAD_NAME          : ${NAD_NAME}"
print_info "  NNCP_IFACE_TYPE   : ${NNCP_IFACE_TYPE}"

echo ""
print_info "SECONDARY_IP_PREFIX: cloud-init을 통해 Secondary NIC (eth1)에 정적 IP를 할당할 때 사용하는 네트워크 프리픽스입니다."
print_info "SECONDARY_IP_START / END: IP 범위 (마지막 옥텟). Lab별로 순차 할당됩니다."
print_info "  예) prefix=192.168.200, range=1~254 → 02-network: .1,.2 / 03-vm: .3,.4 / 05-netpol: .5,.6"
ask "Secondary NIC IP 프리픽스 (처음 3 옥텟)" "192.168.200" SECONDARY_IP_PREFIX
ask "Secondary NIC IP 범위 시작 (마지막 옥텟)" "1" SECONDARY_IP_START
ask "Secondary NIC IP 범위 끝   (마지막 옥텟)" "254" SECONDARY_IP_END
if (( SECONDARY_IP_END - SECONDARY_IP_START < 5 )); then
    print_warn "IP 범위가 너무 작습니다 (최소 6개 필요). 끝 값을 $(( SECONDARY_IP_START + 10 ))으로 조정합니다."
    SECONDARY_IP_END=$(( SECONDARY_IP_START + 10 ))
fi
print_info "  IP 범위: ${SECONDARY_IP_PREFIX}.${SECONDARY_IP_START} ~ ${SECONDARY_IP_PREFIX}.${SECONDARY_IP_END}"

# =============================================================================
# env.conf 저장
# =============================================================================
print_header "env.conf 저장 중..."

cat > "$ENV_FILE" << EOF
# =============================================================================
# virt-poc 환경 설정 파일
# setup.sh에 의해 자동 생성됨: $(date)
# Lab별 변수는 각 lab 스크립트 실행 시 자동으로 추가됩니다.
# 이 파일은 .gitignore에 등록되어 있어 git에 커밋되지 않습니다.
# =============================================================================

# 네트워크 설정
NNCP_NAME=${NNCP_NAME}
BRIDGE_INTERFACE=${BRIDGE_INTERFACE}
BRIDGE_NAME=${BRIDGE_NAME}
NNCP_IFACE_TYPE=${NNCP_IFACE_TYPE}
NAD_NAME=${NAD_NAME}
NET_TYPE=${NET_TYPE}
LOCALNET_NAME=${LOCALNET_NAME}
VLAN_ID=${VLAN_ID}
BOND_NAME=${BOND_NAME}
BOND_MODE=${BOND_MODE}
BOND_INTERFACE_2=${BOND_INTERFACE_2}
SECONDARY_IP_PREFIX=${SECONDARY_IP_PREFIX}
SECONDARY_IP_START=${SECONDARY_IP_START}
SECONDARY_IP_END=${SECONDARY_IP_END}

# StorageClass
STORAGE_CLASS=${STORAGE_CLASS}

# Golden Image URL (DataVolume HTTP import)
GOLDEN_IMAGE_URL=${GOLDEN_IMAGE_URL}

# Operator 설치 상태 (setup.sh 실행 시 자동 감지)
VIRT_INSTALLED=${VIRT_INSTALLED:-false}
MTV_INSTALLED=${MTV_INSTALLED:-false}
NMSTATE_INSTALLED=${NMSTATE_INSTALLED:-false}
OADP_INSTALLED=${OADP_INSTALLED:-false}
OADP_NS=${OADP_NS}
GRAFANA_INSTALLED=${GRAFANA_INSTALLED:-false}
COO_INSTALLED=${COO_INSTALLED:-false}
DESCHEDULER_INSTALLED=${DESCHEDULER_INSTALLED:-false}
FAR_INSTALLED=${FAR_INSTALLED:-false}
NMO_INSTALLED=${NMO_INSTALLED:-false}
NHC_INSTALLED=${NHC_INSTALLED:-false}
SNR_INSTALLED=${SNR_INSTALLED:-false}
ODF_INSTALLED=${ODF_INSTALLED:-false}
LOGGING_INSTALLED=${LOGGING_INSTALLED:-false}
LOKI_INSTALLED=${LOKI_INSTALLED:-false}
EOF

print_ok "env.conf 파일이 생성되었습니다: $ENV_FILE"

# =============================================================================
# 완료 메시지
# =============================================================================
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  설정 완료!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  다음 단계:"
echo -e ""
echo -e "  ${CYAN}[1] Operator 설치${NC}"
echo -e "      operators/README.md"
echo -e ""
echo -e "  ${CYAN}[2] poc.sh 실행${NC}"
echo -e "      ./poc.sh"
echo ""
