#!/bin/bash
# =============================================================================
# check.sh
#
# OpenShift Virtualization 기능 검증 스크립트
#
# 모든 lab의 주요 기능 및 구성을 점검합니다
#
# 사용법: ./check.sh [--verbose]
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

VERBOSE="${1:-}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
MAGENTA='\033[0;35m'
GRAY='\033[0;90m'
NC='\033[0m'

print_info()  { echo -e "${BLUE}[정보]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[통과]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[경고]${NC} $1"; }
print_fail()  { echo -e "${RED}[실패]${NC} $1"; }
print_blocked() { echo -e "${MAGENTA}[불가]${NC} $1"; }
print_skip()  { echo -e "${GRAY}[건너뜀]${NC} $1"; }
print_section() { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# 테스트 카운터
TOTAL=0
PASSED=0
FAILED=0
WARNED=0
BLOCKED=0
SKIPPED=0

# =============================================================================
# 테스트 헬퍼
# =============================================================================
test_start() {
    TOTAL=$((TOTAL+1))
    [ "$VERBOSE" = "--verbose" ] && echo -e "\n${GRAY}테스트 중: $1${NC}"
}

test_pass() {
    PASSED=$((PASSED+1))
    print_ok "$1"
}

test_fail() {
    FAILED=$((FAILED+1))
    print_fail "$1"
}

test_warn() {
    WARNED=$((WARNED+1))
    print_warn "$1"
}

test_blocked() {
    BLOCKED=$((BLOCKED+1))
    print_blocked "$1"
}

test_skip() {
    SKIPPED=$((SKIPPED+1))
    print_skip "$1"
}

# =============================================================================
# 사전 점검
# =============================================================================
preflight() {
    print_section "사전 점검"

    test_start "OpenShift 연결"
    if ! oc whoami &>/dev/null; then
        test_fail "OpenShift에 로그인되어 있지 않습니다 (oc login 필요)"
        exit 1
    fi
    test_pass "연결됨: $(oc whoami --show-server) (사용자: $(oc whoami))"

    CSV_CACHE=$(oc get csv -A 2>/dev/null || true)

    test_start "OpenShift Virtualization Operator"
    if echo "$CSV_CACHE" | grep -qi "kubevirt-hyperconverged"; then
        local version
        version=$(echo "$CSV_CACHE" | grep -i "kubevirt-hyperconverged" | awk '{print $NF}' | head -1)
        test_pass "OpenShift Virtualization 설치됨 (버전: ${version:-알 수 없음})"
    else
        test_fail "OpenShift Virtualization 미설치"
        exit 1
    fi

    test_start "HyperConverged CR"
    if oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv &>/dev/null; then
        local phase
        phase=$(oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.status.phase}')
        if [ "$phase" = "Deployed" ]; then
            test_pass "HyperConverged 배포 완료"
        else
            test_warn "HyperConverged 상태: $phase (예상: Deployed)"
        fi
    else
        test_fail "HyperConverged CR을 찾을 수 없습니다"
    fi
}

# =============================================================================
# Lab 01: Template
# =============================================================================
check_template() {
    print_section "Lab 01: VM Template"

    test_start "DataSource 'poc-golden'"
    if oc get datasource poc-golden -n openshift-virtualization-os-images &>/dev/null; then
        test_pass "DataSource 'poc-golden' 존재함"
    else
        test_fail "DataSource 'poc-golden'을 찾을 수 없습니다 (01-template/01-template.sh 실행 필요)"
    fi

    test_start "Template 'poc'"
    if oc get template poc -n openshift &>/dev/null; then
        test_pass "Template 'poc' 존재함 (namespace: openshift)"
    else
        test_fail "Template 'poc'을 찾을 수 없습니다 (namespace: openshift)"
    fi
}

# =============================================================================
# Lab 02: Network
# =============================================================================
check_network() {
    print_section "Lab 02: 네트워크 설정"

    test_start "NMState Operator"
    if echo "$CSV_CACHE" | grep -qi "kubernetes-nmstate"; then
        test_pass "NMState Operator 설치됨"
    else
        test_blocked "NMState Operator 미설치"
    fi

    test_start "NNCP (NodeNetworkConfigurationPolicy)"
    local nncp_count
    nncp_count=$(oc get nncp 2>/dev/null | grep -v NAME | wc -l)
    if [ "$nncp_count" -gt 0 ]; then
        test_pass "NNCP 발견: ${nncp_count}개 설정"
        [ "$VERBOSE" = "--verbose" ] && oc get nncp
    else
        test_warn "NNCP를 찾을 수 없습니다 (02-network/02-network.sh 실행 필요)"
    fi

    test_start "NetworkAttachmentDefinition"
    local nad_count
    nad_count=$(oc get network-attachment-definitions -A 2>/dev/null | grep -v NAMESPACE | wc -l)
    if [ "$nad_count" -gt 0 ]; then
        test_pass "NAD 발견: ${nad_count}개 네트워크"
        [ "$VERBOSE" = "--verbose" ] && oc get network-attachment-definitions -A
    else
        test_warn "NAD를 찾을 수 없습니다"
    fi
}

# =============================================================================
# Lab 03: VM Workload
# =============================================================================
check_vm_workload() {
    print_section "Lab 03: VM Workload"

    test_start "클러스터 내 VM"
    local vm_count running_count
    vm_count=$(oc get vm -A 2>/dev/null | grep -v NAMESPACE | wc -l)
    running_count=$(oc get vmi -A 2>/dev/null | grep -v NAMESPACE | wc -l)

    if [ "$vm_count" -gt 0 ]; then
        test_pass "VM: 전체 ${vm_count}개, 실행 중 ${running_count}개"
        [ "$VERBOSE" = "--verbose" ] && oc get vm,vmi -A
    else
        test_warn "VM을 찾을 수 없습니다"
    fi

    test_start "Live Migration 기능"
    if oc get vmim -A 2>/dev/null | grep -q .; then
        test_pass "Live Migration 기능 확인됨 (마이그레이션 기록 있음)"
    else
        test_skip "VM 마이그레이션 기록 없음 (아직 테스트되지 않음)"
    fi
}

# =============================================================================
# Lab 04: Multitenancy
# =============================================================================
check_multitenancy() {
    print_section "Lab 04: 멀티테넌시"

    test_start "테넌트 namespace"
    local ns1_exists ns2_exists tenant_count=0
    oc get ns poc-multitenancy-1 &>/dev/null && tenant_count=$((tenant_count+1))
    oc get ns poc-multitenancy-2 &>/dev/null && tenant_count=$((tenant_count+1))
    if [ "$tenant_count" -eq 2 ]; then
        test_pass "멀티테넌트 namespace: poc-multitenancy-1, poc-multitenancy-2"
    elif [ "$tenant_count" -eq 1 ]; then
        test_warn "멀티테넌트 namespace 1개만 발견 (2개 필요)"
    else
        test_warn "멀티테넌트 namespace를 찾을 수 없습니다 (04-multitenancy 실행 필요)"
    fi

    test_start "RBAC 설정"
    local rb_count
    rb_count=$(oc get rolebinding -n poc-multitenancy-1 -n poc-multitenancy-2 2>/dev/null | grep -E "user[1-4]" | wc -l)
    if [ "$rb_count" -gt 0 ]; then
        test_pass "멀티테넌시 RoleBinding: ${rb_count}개 발견"
    else
        test_warn "멀티테넌시 RoleBinding을 찾을 수 없습니다"
    fi
}

# =============================================================================
# Lab 05: Network Policy
# =============================================================================
check_network_policy() {
    print_section "Lab 05: Network Policy"

    test_start "NetworkPolicy"
    local np_count
    np_count=$(oc get networkpolicy -n poc-network-policy-1 -n poc-network-policy-2 2>/dev/null | grep -v NAME | wc -l)
    if [ "$np_count" -gt 0 ]; then
        test_pass "NetworkPolicy: ${np_count}개 발견 (poc-network-policy-*)"
        [ "$VERBOSE" = "--verbose" ] && oc get networkpolicy -n poc-network-policy-1 -n poc-network-policy-2
    else
        test_warn "NetworkPolicy를 찾을 수 없습니다 (05-network-policy 실행 필요)"
    fi
}

# =============================================================================
# Lab 06: Resource Quota
# =============================================================================
check_resource_quota() {
    print_section "Lab 06: Resource Quota"

    test_start "ResourceQuota"
    if oc get resourcequota -n poc-resource-quota 2>/dev/null | grep -q poc; then
        test_pass "ResourceQuota 발견 (poc-resource-quota)"
        [ "$VERBOSE" = "--verbose" ] && oc get resourcequota -n poc-resource-quota
    else
        test_warn "ResourceQuota를 찾을 수 없습니다 (06-resource-quota 실행 필요)"
    fi
}

# =============================================================================
# Lab 07: Descheduler
# =============================================================================
check_descheduler() {
    print_section "Lab 07: Descheduler"

    test_start "Kube Descheduler Operator"
    if echo "$CSV_CACHE" | grep -qi "descheduler"; then
        test_pass "Descheduler Operator 설치됨"
    else
        test_blocked "Descheduler Operator 미설치"
        return
    fi

    test_start "KubeDescheduler CR"
    if oc get kubedescheduler -A &>/dev/null; then
        test_pass "KubeDescheduler 설정됨"
    else
        test_warn "KubeDescheduler 미설정"
    fi
}

# =============================================================================
# Lab 08: Liveness Probe
# =============================================================================
check_liveness_probe() {
    print_section "Lab 08: Liveness Probe"

    test_start "Health Probe가 설정된 VM"
    local probe_vms
    probe_vms=$(oc get vm -A -o yaml 2>/dev/null | grep -c "livenessProbe:" || echo 0)
    if [ "$probe_vms" -gt 0 ]; then
        test_pass "Liveness Probe가 설정된 VM: ${probe_vms}개"
    else
        test_warn "Liveness Probe가 설정된 VM을 찾을 수 없습니다"
    fi
}

# =============================================================================
# Lab 09: Alert
# =============================================================================
check_alert() {
    print_section "Lab 09: Alert"

    test_start "VM용 PrometheusRule"
    local pr_count
    pr_count=$(oc get prometheusrule -A 2>/dev/null | grep -i "vm\|virt" | wc -l)
    if [ "$pr_count" -gt 0 ]; then
        test_pass "VM용 PrometheusRule: ${pr_count}개 발견"
    else
        test_warn "VM 관련 PrometheusRule을 찾을 수 없습니다"
    fi
}

# =============================================================================
# Lab 10-12: Monitoring
# =============================================================================
check_monitoring() {
    print_section "Lab 10-12: Monitoring Stack"

    test_start "Node Exporter 배포"
    local ne_count
    ne_count=$(oc get pods -A 2>/dev/null | grep node-exporter | wc -l)
    if [ "$ne_count" -gt 0 ]; then
        test_pass "Node Exporter Pod: ${ne_count}개"
    else
        test_warn "node-exporter Pod를 찾을 수 없습니다"
    fi

    test_start "Cluster Observability Operator"
    if echo "$CSV_CACHE" | grep -qi "cluster-observability"; then
        test_pass "COO 설치됨"
    else
        test_blocked "COO 미설치"
    fi

    test_start "Grafana Operator"
    if echo "$CSV_CACHE" | grep -qi "grafana-operator"; then
        test_pass "Grafana Operator 설치됨"
    else
        test_blocked "Grafana Operator 미설치"
    fi
}

# =============================================================================
# Lab 13: MTV (Migration Toolkit for Virtualization)
# =============================================================================
check_mtv() {
    print_section "Lab 13: MTV (마이그레이션)"

    test_start "MTV Operator"
    if echo "$CSV_CACHE" | grep -qi "mtv-operator\|forklift"; then
        test_pass "MTV Operator 설치됨"
    else
        test_blocked "MTV Operator 미설치"
    fi
}

# =============================================================================
# Lab 14: OADP (백업/복원)
# =============================================================================
check_oadp() {
    print_section "Lab 14: OADP (백업/복원)"

    test_start "OADP Operator"
    if echo "$CSV_CACHE" | grep -qi "oadp"; then
        test_pass "OADP Operator 설치됨"
    else
        test_blocked "OADP Operator 미설치"
        return
    fi

    test_start "DataProtectionApplication"
    if oc get dpa -n ${OADP_NS:-openshift-adp} &>/dev/null; then
        test_pass "DPA 설정됨"
    else
        test_warn "DPA 미설정"
    fi

    test_start "Garage S3 스토리지"
    if oc get pods -n ${GARAGE_NS:-garage} 2>/dev/null | grep -q garage; then
        test_pass "Garage S3 스토리지 실행 중"
    else
        test_warn "Garage 미배포 (14-oadp/14-oadp.md 참조)"
    fi

    test_start "Backup/Restore CR"
    local backup_count
    backup_count=$(oc get backup -n ${OADP_NS:-openshift-adp} 2>/dev/null | grep -v NAME | wc -l)
    if [ "$backup_count" -gt 0 ]; then
        test_pass "생성된 Backup: ${backup_count}개"
    else
        test_skip "아직 생성된 Backup 없음"
    fi
}

# =============================================================================
# Lab 15-17: 노드 관리
# =============================================================================
check_node_management() {
    print_section "Lab 15-17: 노드 관리 및 복구"

    test_start "Node Maintenance Operator"
    if echo "$CSV_CACHE" | grep -qi "node-maintenance"; then
        test_pass "Node Maintenance Operator 설치됨"
    else
        test_blocked "Node Maintenance Operator 미설치"
    fi

    test_start "Node Health Check Operator"
    if echo "$CSV_CACHE" | grep -qi "node-healthcheck"; then
        test_pass "NHC Operator 설치됨"
    else
        test_blocked "NHC Operator 미설치"
    fi

    test_start "Self Node Remediation Operator"
    if echo "$CSV_CACHE" | grep -qi "self-node-remediation"; then
        test_pass "SNR Operator 설치됨"
    else
        test_blocked "SNR Operator 미설치"
    fi

    test_start "Fence Agents Remediation Operator"
    if echo "$CSV_CACHE" | grep -qi "fence-agents"; then
        test_pass "FAR Operator 설치됨"
    else
        test_blocked "FAR Operator 미설치"
    fi
}

# =============================================================================
# Lab 19: HyperConverged 설정
# =============================================================================
check_hyperconverged() {
    print_section "Lab 19: HyperConverged 설정"

    test_start "CPU Overcommit 비율"
    local cpu_ratio
    cpu_ratio=$(oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.spec.resourceRequirements.vmiCPUAllocationRatio}' 2>/dev/null || echo "미설정")
    if [ "$cpu_ratio" != "미설정" ]; then
        test_pass "CPU 할당 비율: $cpu_ratio"
    else
        test_skip "CPU 할당 비율 미설정"
    fi

    test_start "Live Migration 설정"
    local migration_config
    migration_config=$(oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.spec.liveMigrationConfig}' 2>/dev/null)
    if [ -n "$migration_config" ]; then
        test_pass "Live Migration 설정됨"
    else
        test_skip "Live Migration 사용자 정의 없음"
    fi
}

# =============================================================================
# Lab 20: Logging
# =============================================================================
check_logging() {
    print_section "Lab 20: Logging"

    test_start "OpenShift Logging Operator"
    if echo "$CSV_CACHE" | grep -qi "cluster-logging"; then
        test_pass "Logging Operator 설치됨"
    else
        test_blocked "Logging Operator 미설치"
    fi

    test_start "Loki Operator"
    if echo "$CSV_CACHE" | grep -qi "loki-operator"; then
        test_pass "Loki Operator 설치됨"
    else
        test_blocked "Loki Operator 미설치"
    fi

    test_start "LokiStack"
    if oc get lokistack -n openshift-logging &>/dev/null; then
        test_pass "LokiStack 설정됨"
    else
        test_skip "LokiStack 미설정"
    fi
}

# =============================================================================
# 스토리지 점검
# =============================================================================
check_storage() {
    print_section "스토리지 설정"

    test_start "StorageClass"
    local sc_count
    sc_count=$(oc get sc 2>/dev/null | grep -v NAME | wc -l)
    if [ "$sc_count" -gt 0 ]; then
        test_pass "StorageClass: ${sc_count}개"
        [ "$VERBOSE" = "--verbose" ] && oc get sc
    else
        test_fail "StorageClass를 찾을 수 없습니다"
    fi

    test_start "기본 StorageClass"
    if oc get sc 2>/dev/null | grep -q "(default)"; then
        local default_sc
        default_sc=$(oc get sc 2>/dev/null | grep "(default)" | awk '{print $1}')
        test_pass "기본 StorageClass: $default_sc"
    else
        test_warn "기본 StorageClass가 설정되지 않았습니다"
    fi

    test_start "iSCSI 설정"
    local iscsi_pvs
    iscsi_pvs=$(oc get pv 2>/dev/null | grep -i iscsi | wc -l)
    if [ "$iscsi_pvs" -gt 0 ]; then
        test_pass "iSCSI PV: ${iscsi_pvs}개 발견"
    else
        test_skip "iSCSI PV 없음 (operators/iscsi-storage.md 참조)"
    fi
}

# =============================================================================
# 요약
# =============================================================================
print_summary() {
    print_section "테스트 요약"

    local total_executed=$((PASSED + FAILED + WARNED))
    local pass_rate=0
    [ "$total_executed" -gt 0 ] && pass_rate=$((PASSED * 100 / total_executed))

    echo ""
    printf "  %-20s %3d\n" "전체 테스트:" "$TOTAL"
    printf "  ${GREEN}%-20s %3d${NC}\n" "통과:" "$PASSED"
    printf "  ${RED}%-20s %3d${NC}\n" "실패:" "$FAILED"
    printf "  ${YELLOW}%-20s %3d${NC}\n" "경고:" "$WARNED"
    printf "  ${MAGENTA}%-20s %3d${NC}\n" "불가:" "$BLOCKED"
    printf "  ${GRAY}%-20s %3d${NC}\n" "건너뜀:" "$SKIPPED"
    echo ""
    printf "  통과율: %d%%\n" "$pass_rate"
    echo ""

    if [ "$FAILED" -eq 0 ]; then
        print_ok "모든 필수 점검을 통과했습니다!"
    else
        print_fail "${FAILED}개 필수 점검 항목이 실패했습니다"
        echo ""
        echo "  위 출력을 검토하고 해당 lab 스크립트를 실행하세요."
    fi

    if [ "$BLOCKED" -gt 0 ]; then
        echo ""
        print_blocked "${BLOCKED}개 Operator가 설치되지 않아 해당 Lab을 실행할 수 없습니다"
    fi

    if [ "$WARNED" -gt 0 ]; then
        echo ""
        print_warn "${WARNED}개 선택 기능이 설정되지 않았습니다"
        echo "  선택 사항이지만 전체 POC 범위를 위해 권장됩니다."
    fi
}

# =============================================================================
# 메인
# =============================================================================
main() {
    clear
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                                                                ║"
    echo "║   OpenShift Virtualization 기능 검증 스크립트                 ║"
    echo "║                                                                ║"
    echo "╚════════════════════════════════════════════════════════════════╝"
    echo ""

    preflight
    check_template
    check_network
    check_vm_workload
    check_multitenancy
    check_network_policy
    check_resource_quota
    check_descheduler
    check_liveness_probe
    check_alert
    check_monitoring
    check_mtv
    check_oadp
    check_node_management
    check_hyperconverged
    check_logging
    check_storage

    print_summary

    echo ""
    [ "$FAILED" -eq 0 ] && exit 0 || exit 1
}

main "$@"
