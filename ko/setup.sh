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
            local _oadp_ns_list
            _oadp_ns_list=$(oc get csv -A 2>/dev/null | grep -i "oadp-operator" | awk '{print $1}')
            local _oadp_ns_count
            _oadp_ns_count=$(echo "$_oadp_ns_list" | grep -c . || true)
            if [ "$_oadp_ns_count" -eq 1 ]; then
                OADP_NS=$(echo "$_oadp_ns_list")
            elif [ "$_oadp_ns_count" -gt 1 ]; then
                echo ""
                print_info "OADP Operator가 여러 namespace에 설치되어 있습니다:"
                local _i=1
                while IFS= read -r _ns; do
                    echo "    ${_i}) ${_ns}"
                    _i=$((_i+1))
                done <<< "$_oadp_ns_list"
                read -r -p "  사용할 namespace 번호 또는 이름을 입력하세요 [1]: " _sel
                _sel="${_sel:-1}"
                if [[ "$_sel" =~ ^[0-9]+$ ]]; then
                    OADP_NS=$(echo "$_oadp_ns_list" | sed -n "${_sel}p")
                else
                    OADP_NS="$_sel"
                fi
            else
                OADP_NS="openshift-adp"
            fi
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

# NNCP 목록 표시 및 linux-bridge 선택
NNCP_NAME="br-poc-nncp"
_USE_EXISTING_NNCP=false
_LB_NNCPS=()

if command -v oc &>/dev/null && oc whoami &>/dev/null 2>&1; then
    _ALL_NNCPS=$(oc get nncp -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep -v '^$' || true)

    if [ -n "$_ALL_NNCPS" ]; then
        echo ""
        print_info "현재 클러스터 NNCP 목록:"
        echo ""
        printf "  %-4s %-32s %-15s %-18s %-8s %s\n" "번호" "NNCP 이름" "유형" "Bridge 이름" "상태" "NIC"
        echo "  ──────────────────────────────────────────────────────────────────────────────────"
        _idx=1
        for _n in $_ALL_NNCPS; do
            _br=$(oc get nncp "$_n" \
                -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.name}{end}' \
                2>/dev/null || true)
            _avail=$(oc get nncp "$_n" \
                -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' \
                2>/dev/null || true)
            if [ -n "$_br" ]; then
                _nic=$(oc get nncp "$_n" \
                    -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.bridge.port[0].name}{end}' \
                    2>/dev/null || true)
                _type="linux-bridge"
                _LB_NNCPS+=("$_n")
                printf "  ${GREEN}%-4s %-32s %-15s %-18s %-8s %s${NC}\n" \
                    "${_idx})" "$_n" "$_type" "${_br:-N/A}" "${_avail:-알 수 없음}" "${_nic:-N/A}"
            else
                printf "  ${DIM}%-4s %-32s %-15s %-18s %-8s %s${NC}\n" \
                    "${_idx})" "$_n" "기타" "-" "${_avail:-알 수 없음}" "-"
            fi
            _idx=$((_idx + 1))
        done
        echo ""
    else
        echo ""
        print_info "클러스터에 NNCP가 없습니다."
    fi
fi

if [ ${#_LB_NNCPS[@]} -gt 0 ]; then
    _FIRST_LB="${_LB_NNCPS[0]}"
    if [ ${#_LB_NNCPS[@]} -eq 1 ]; then
        _cand_br=$(oc get nncp "$_FIRST_LB" \
            -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.name}{end}' \
            2>/dev/null || true)
        _cand_nic=$(oc get nncp "$_FIRST_LB" \
            -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.bridge.port[0].name}{end}' \
            2>/dev/null || true)
        echo -n -e "${YELLOW}  linux-bridge NNCP '${_FIRST_LB}' (bridge: ${_cand_br}, NIC: ${_cand_nic:-N/A})을 사용하시겠습니까? (Y/n): ${NC}"
        read _use_existing
        if [[ ! "${_use_existing:-}" =~ ^[Nn]$ ]]; then
            _USE_EXISTING_NNCP=true
            NNCP_NAME="$_FIRST_LB"
            BRIDGE_NAME="${_cand_br:-br-poc}"
            BRIDGE_INTERFACE="${_cand_nic:-${DETECTED_IFACE:-ens4}}"
            print_ok "선택됨: ${NNCP_NAME}  (bridge: ${BRIDGE_NAME}, NIC: ${BRIDGE_INTERFACE})"
        fi
    else
        echo -n -e "${YELLOW}  linux-bridge NNCP 번호 또는 이름을 입력하세요 [기본값: ${_FIRST_LB}] (Enter 후 n으로 건너뛰기): ${NC}"
        read _sel_input
        if [ -z "$_sel_input" ]; then
            _sel_nncp="$_FIRST_LB"
        elif [[ "$_sel_input" =~ ^[0-9]+$ ]]; then
            _sel_nncp="${_LB_NNCPS[$((_sel_input - 1))]:-$_FIRST_LB}"
        else
            _sel_nncp="$_sel_input"
        fi
        _sel_br=$(oc get nncp "$_sel_nncp" \
            -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.name}{end}' \
            2>/dev/null || true)
        _sel_nic=$(oc get nncp "$_sel_nncp" \
            -o jsonpath='{range .spec.desiredState.interfaces[?(@.type=="linux-bridge")]}{.bridge.port[0].name}{end}' \
            2>/dev/null || true)
        echo -n -e "${YELLOW}  '${_sel_nncp}' (bridge: ${_sel_br}, NIC: ${_sel_nic:-N/A})을 사용하시겠습니까? (Y/n): ${NC}"
        read _use_existing
        if [[ ! "${_use_existing:-}" =~ ^[Nn]$ ]]; then
            _USE_EXISTING_NNCP=true
            NNCP_NAME="$_sel_nncp"
            BRIDGE_NAME="${_sel_br:-br-poc}"
            BRIDGE_INTERFACE="${_sel_nic:-${DETECTED_IFACE:-ens4}}"
            print_ok "선택됨: ${NNCP_NAME}  (bridge: ${BRIDGE_NAME}, NIC: ${BRIDGE_INTERFACE})"
        fi
    fi
fi

if [ "$_USE_EXISTING_NNCP" = "false" ]; then
    echo ""
    if [ -n "${DETECTED_IFACES:-}" ]; then
        print_info "감지된 인터페이스 목록: $DETECTED_IFACES"
    else
        print_info "노드 네트워크 인터페이스 확인: oc debug node/<node> -- ip link show"
    fi
    ask "생성할 Linux Bridge 이름" "br-poc" BRIDGE_NAME
    BRIDGE_INTERFACE="${DETECTED_IFACE:-ens4}"
    NNCP_NAME="${BRIDGE_NAME}-nncp"
    print_info "  NIC       : ${BRIDGE_INTERFACE}"
    print_info "  NNCP 이름 : ${NNCP_NAME}"
    echo ""
    echo -n -e "${YELLOW}  지금 nncp-gen.sh를 실행하여 NNCP를 생성하시겠습니까? (Y/n): ${NC}"
    read _run_nncp_gen
    if [[ ! "${_run_nncp_gen:-}" =~ ^[Nn]$ ]]; then
        _SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        export BRIDGE_NAME BRIDGE_INTERFACE NNCP_NAME
        bash "${_SETUP_DIR}/02-network/nncp-gen.sh" 1
    fi
fi

echo ""
print_info "SECONDARY_IP_PREFIX: cloud-init을 통해 Secondary NIC (eth1)에 정적 IP를 할당할 때 사용하는 네트워크 프리픽스입니다."
print_info "  예) 192.168.100 → 02-network VM: .21, .22 / 03-vm: .31 / 05-network-policy: .51, .52"
ask "Secondary NIC IP 프리픽스 (cloud-init networkData)" "192.168.100" SECONDARY_IP_PREFIX

# =============================================================================
# [13·14·16] Node — 노드 유지보수 / SNR / 노드 추가
# =============================================================================
print_step_header "[13·14·16]" "Node — 노드 유지보수 / SNR / 노드 추가"

if check_oc 2>/dev/null; then
    DETECTED_WORKERS=$(oc get nodes -l node-role.kubernetes.io/worker \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$DETECTED_WORKERS" ]; then
        print_info "감지된 워커 노드: $DETECTED_WORKERS"
        FIRST_WORKER=$(echo $DETECTED_WORKERS | awk '{print $1}')
    else
        FIRST_WORKER="worker-0"
    fi
else
    DETECTED_WORKERS=""
    FIRST_WORKER="worker-0"
fi

ask "워커 노드 이름 목록 (공백으로 구분)" "${DETECTED_WORKERS:-worker-0 worker-1 worker-2}" WORKER_NODES
ask "테스트에 사용할 노드 이름 (단일)" "${FIRST_WORKER:-worker-0}" TEST_NODE

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
SECONDARY_IP_PREFIX=${SECONDARY_IP_PREFIX}

# StorageClass
STORAGE_CLASS=${STORAGE_CLASS}

# Golden Image URL (DataVolume HTTP import)
GOLDEN_IMAGE_URL=${GOLDEN_IMAGE_URL}

# 노드 정보
WORKER_NODES="${WORKER_NODES}"
TEST_NODE=${TEST_NODE}

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
echo -e "  ${CYAN}[2] run.sh 실행${NC}"
echo -e "      ./run.sh"
echo ""
