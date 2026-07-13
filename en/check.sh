#!/bin/bash
# =============================================================================
# check.sh
#
# OpenShift Virtualization Feature Verification Script
#
# Checks all major features and configurations across all labs
#
# Usage: ./check.sh [--verbose]
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
GRAY='\033[0;90m'
NC='\033[0m'

print_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[PASS]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_fail()  { echo -e "${RED}[FAIL]${NC} $1"; }
print_skip()  { echo -e "${GRAY}[SKIP]${NC} $1"; }
print_section() { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# Test counters
TOTAL=0
PASSED=0
FAILED=0
WARNED=0
SKIPPED=0

# =============================================================================
# Test helpers
# =============================================================================
test_start() {
    TOTAL=$((TOTAL+1))
    [ "$VERBOSE" = "--verbose" ] && echo -e "\n${GRAY}Testing: $1${NC}"
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

test_skip() {
    SKIPPED=$((SKIPPED+1))
    print_skip "$1"
}

# =============================================================================
# Preflight checks
# =============================================================================
preflight() {
    print_section "Preflight Checks"

    test_start "OpenShift connection"
    if ! oc whoami &>/dev/null; then
        test_fail "Not logged in to OpenShift (oc login required)"
        exit 1
    fi
    test_pass "Connected to: $(oc whoami --show-server) as $(oc whoami)"

    CSV_CACHE=$(oc get csv -A 2>/dev/null || true)

    test_start "OpenShift Virtualization Operator"
    if echo "$CSV_CACHE" | grep -qi "kubevirt-hyperconverged"; then
        local version
        version=$(echo "$CSV_CACHE" | grep -i "kubevirt-hyperconverged" | awk '{print $NF}' | head -1)
        test_pass "OpenShift Virtualization installed (version: ${version:-unknown})"
    else
        test_fail "OpenShift Virtualization not installed"
        exit 1
    fi

    test_start "HyperConverged CR"
    if oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv &>/dev/null; then
        local phase
        phase=$(oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.status.phase}')
        if [ "$phase" = "Deployed" ]; then
            test_pass "HyperConverged is Deployed"
        else
            test_warn "HyperConverged phase: $phase (expected: Deployed)"
        fi
    else
        test_fail "HyperConverged CR not found"
    fi
}

# =============================================================================
# Lab 01: Template
# =============================================================================
check_template() {
    print_section "Lab 01: VM Template"

    test_start "DataSource 'poc-golden'"
    if oc get datasource poc-golden -n openshift-virtualization-os-images &>/dev/null; then
        test_pass "DataSource 'poc-golden' exists"
    else
        test_fail "DataSource 'poc-golden' not found (run 01-template/01-template.sh)"
    fi

    test_start "Template 'poc'"
    if oc get template poc -n openshift &>/dev/null; then
        test_pass "Template 'poc' exists (namespace: openshift)"
    else
        test_fail "Template 'poc' not found (namespace: openshift)"
    fi
}

# =============================================================================
# Lab 02: Network
# =============================================================================
check_network() {
    print_section "Lab 02: Network Configuration"

    test_start "NMState Operator"
    if echo "$CSV_CACHE" | grep -qi "kubernetes-nmstate"; then
        test_pass "NMState Operator installed"
    else
        test_warn "NMState Operator not installed"
    fi

    test_start "NNCP (NodeNetworkConfigurationPolicy)"
    local nncp_count
    nncp_count=$(oc get nncp 2>/dev/null | grep -v NAME | wc -l)
    if [ "$nncp_count" -gt 0 ]; then
        test_pass "NNCP found: $nncp_count configuration(s)"
        [ "$VERBOSE" = "--verbose" ] && oc get nncp
    else
        test_warn "No NNCP found (run 02-network/02-network.sh)"
    fi

    test_start "NetworkAttachmentDefinition"
    local nad_count
    nad_count=$(oc get network-attachment-definitions -A 2>/dev/null | grep -v NAMESPACE | wc -l)
    if [ "$nad_count" -gt 0 ]; then
        test_pass "NAD found: $nad_count network(s)"
        [ "$VERBOSE" = "--verbose" ] && oc get network-attachment-definitions -A
    else
        test_warn "No NAD found"
    fi
}

# =============================================================================
# Lab 03: VM Workload
# =============================================================================
check_vm_workload() {
    print_section "Lab 03: VM Workload"

    test_start "VMs in cluster"
    local vm_count running_count
    vm_count=$(oc get vm -A 2>/dev/null | grep -v NAMESPACE | wc -l)
    running_count=$(oc get vmi -A 2>/dev/null | grep -v NAMESPACE | wc -l)

    if [ "$vm_count" -gt 0 ]; then
        test_pass "VMs: $vm_count total, $running_count running"
        [ "$VERBOSE" = "--verbose" ] && oc get vm,vmi -A
    else
        test_warn "No VMs found"
    fi

    test_start "Live Migration capability"
    if oc get vmim -A 2>/dev/null | grep -q .; then
        test_pass "Live Migration capability verified (migrations found)"
    else
        test_skip "No VM migrations found (not tested yet)"
    fi
}

# =============================================================================
# Lab 04: Multitenancy
# =============================================================================
check_multitenancy() {
    print_section "Lab 04: Multitenancy"

    test_start "Tenant namespaces"
    local tenant_count=0
    oc get ns poc-multitenancy-1 &>/dev/null && tenant_count=$((tenant_count+1))
    oc get ns poc-multitenancy-2 &>/dev/null && tenant_count=$((tenant_count+1))
    if [ "$tenant_count" -eq 2 ]; then
        test_pass "Multi-tenant namespaces: poc-multitenancy-1, poc-multitenancy-2"
    elif [ "$tenant_count" -eq 1 ]; then
        test_warn "Only 1 multi-tenant namespace found (2 expected)"
    else
        test_warn "No multi-tenant namespaces found (run 04-multitenancy)"
    fi

    test_start "RBAC configuration"
    local rb_count
    rb_count=$(oc get rolebinding -n poc-multitenancy-1 -n poc-multitenancy-2 2>/dev/null | grep -E "user[1-4]" | wc -l)
    if [ "$rb_count" -gt 0 ]; then
        test_pass "Multitenancy RoleBindings: $rb_count found"
    else
        test_warn "No multitenancy RoleBindings found"
    fi
}

# =============================================================================
# Lab 05: Network Policy
# =============================================================================
check_network_policy() {
    print_section "Lab 05: Network Policy"

    test_start "NetworkPolicies"
    local np_count
    np_count=$(oc get networkpolicy -n poc-network-policy-1 -n poc-network-policy-2 2>/dev/null | grep -v NAME | wc -l)
    if [ "$np_count" -gt 0 ]; then
        test_pass "NetworkPolicies: $np_count found (poc-network-policy-*)"
        [ "$VERBOSE" = "--verbose" ] && oc get networkpolicy -n poc-network-policy-1 -n poc-network-policy-2
    else
        test_warn "No NetworkPolicies found (run 05-network-policy)"
    fi
}

# =============================================================================
# Lab 06: Resource Quota
# =============================================================================
check_resource_quota() {
    print_section "Lab 06: Resource Quota"

    test_start "ResourceQuotas"
    if oc get resourcequota -n poc-resource-quota 2>/dev/null | grep -q poc; then
        test_pass "ResourceQuota found (poc-resource-quota)"
        [ "$VERBOSE" = "--verbose" ] && oc get resourcequota -n poc-resource-quota
    else
        test_warn "No ResourceQuota found (run 06-resource-quota)"
    fi
}

# =============================================================================
# Lab 07: Descheduler
# =============================================================================
check_descheduler() {
    print_section "Lab 07: Descheduler"

    test_start "Kube Descheduler Operator"
    if echo "$CSV_CACHE" | grep -qi "descheduler"; then
        test_pass "Descheduler Operator installed"
    else
        test_warn "Descheduler Operator not installed"
        return
    fi

    test_start "KubeDescheduler CR"
    if oc get kubedescheduler -A &>/dev/null; then
        test_pass "KubeDescheduler configured"
    else
        test_warn "KubeDescheduler not configured"
    fi
}

# =============================================================================
# Lab 08: Liveness Probe
# =============================================================================
check_liveness_probe() {
    print_section "Lab 08: Liveness Probe"

    test_start "VMs with health probes"
    local probe_vms
    probe_vms=$(oc get vm -A -o yaml 2>/dev/null | grep -c "livenessProbe:" || echo 0)
    if [ "$probe_vms" -gt 0 ]; then
        test_pass "VMs with liveness probes: $probe_vms"
    else
        test_warn "No VMs with liveness probes found"
    fi
}

# =============================================================================
# Lab 09: Alert
# =============================================================================
check_alert() {
    print_section "Lab 09: Alert"

    test_start "PrometheusRules for VMs"
    local pr_count
    pr_count=$(oc get prometheusrule -A 2>/dev/null | grep -i "vm\|virt" | wc -l)
    if [ "$pr_count" -gt 0 ]; then
        test_pass "PrometheusRules for VMs: $pr_count found"
    else
        test_warn "No VM-related PrometheusRules found"
    fi
}

# =============================================================================
# Lab 10-12: Monitoring
# =============================================================================
check_monitoring() {
    print_section "Lab 10-12: Monitoring Stack"

    test_start "Node Exporter deployment"
    local ne_count
    ne_count=$(oc get pods -A 2>/dev/null | grep node-exporter | wc -l)
    if [ "$ne_count" -gt 0 ]; then
        test_pass "Node Exporter pods: $ne_count"
    else
        test_warn "No node-exporter pods found"
    fi

    test_start "Cluster Observability Operator"
    if echo "$CSV_CACHE" | grep -qi "cluster-observability"; then
        test_pass "COO installed"
    else
        test_warn "COO not installed"
    fi

    test_start "Grafana Operator"
    if echo "$CSV_CACHE" | grep -qi "grafana-operator"; then
        test_pass "Grafana Operator installed"
    else
        test_warn "Grafana Operator not installed"
    fi
}

# =============================================================================
# Lab 13: MTV (Migration Toolkit for Virtualization)
# =============================================================================
check_mtv() {
    print_section "Lab 13: MTV (Migration)"

    test_start "MTV Operator"
    if echo "$CSV_CACHE" | grep -qi "mtv-operator\|forklift"; then
        test_pass "MTV Operator installed"
    else
        test_warn "MTV Operator not installed"
    fi
}

# =============================================================================
# Lab 14: OADP (Backup/Restore)
# =============================================================================
check_oadp() {
    print_section "Lab 14: OADP (Backup/Restore)"

    test_start "OADP Operator"
    if echo "$CSV_CACHE" | grep -qi "oadp"; then
        test_pass "OADP Operator installed"
    else
        test_warn "OADP Operator not installed"
        return
    fi

    test_start "DataProtectionApplication"
    if oc get dpa -n ${OADP_NS:-openshift-adp} &>/dev/null; then
        test_pass "DPA configured"
    else
        test_warn "DPA not configured"
    fi

    test_start "Garage S3 storage"
    if oc get pods -n ${GARAGE_NS:-garage} 2>/dev/null | grep -q garage; then
        test_pass "Garage S3 storage running"
    else
        test_warn "Garage not deployed (see 14-oadp/14-oadp.md)"
    fi

    test_start "Backup/Restore CRs"
    local backup_count
    backup_count=$(oc get backup -n ${OADP_NS:-openshift-adp} 2>/dev/null | grep -v NAME | wc -l)
    if [ "$backup_count" -gt 0 ]; then
        test_pass "Backups created: $backup_count"
    else
        test_skip "No backups created yet"
    fi
}

# =============================================================================
# Lab 15-17: Node Management
# =============================================================================
check_node_management() {
    print_section "Lab 15-17: Node Management & Remediation"

    test_start "Node Maintenance Operator"
    if echo "$CSV_CACHE" | grep -qi "node-maintenance"; then
        test_pass "Node Maintenance Operator installed"
    else
        test_warn "Node Maintenance Operator not installed"
    fi

    test_start "Self Node Remediation Operator"
    if echo "$CSV_CACHE" | grep -qi "self-node-remediation"; then
        test_pass "SNR Operator installed"
    else
        test_warn "SNR Operator not installed"
    fi

    test_start "Fence Agents Remediation Operator"
    if echo "$CSV_CACHE" | grep -qi "fence-agents"; then
        test_pass "FAR Operator installed"
    else
        test_warn "FAR Operator not installed"
    fi
}

# =============================================================================
# Lab 19: HyperConverged Configuration
# =============================================================================
check_hyperconverged() {
    print_section "Lab 19: HyperConverged Configuration"

    test_start "CPU Overcommit ratio"
    local cpu_ratio
    cpu_ratio=$(oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.spec.resourceRequirements.vmiCPUAllocationRatio}' 2>/dev/null || echo "not set")
    if [ "$cpu_ratio" != "not set" ]; then
        test_pass "CPU allocation ratio: $cpu_ratio"
    else
        test_skip "CPU allocation ratio not configured"
    fi

    test_start "Live Migration configuration"
    local migration_config
    migration_config=$(oc get hyperconverged kubevirt-hyperconverged -n openshift-cnv -o jsonpath='{.spec.liveMigrationConfig}' 2>/dev/null)
    if [ -n "$migration_config" ]; then
        test_pass "Live Migration configured"
    else
        test_skip "Live Migration not customized"
    fi
}

# =============================================================================
# Lab 20: Logging
# =============================================================================
check_logging() {
    print_section "Lab 20: Logging"

    test_start "OpenShift Logging Operator"
    if echo "$CSV_CACHE" | grep -qi "cluster-logging"; then
        test_pass "Logging Operator installed"
    else
        test_warn "Logging Operator not installed"
    fi

    test_start "Loki Operator"
    if echo "$CSV_CACHE" | grep -qi "loki-operator"; then
        test_pass "Loki Operator installed"
    else
        test_warn "Loki Operator not installed"
    fi

    test_start "LokiStack"
    if oc get lokistack -n openshift-logging &>/dev/null; then
        test_pass "LokiStack configured"
    else
        test_skip "LokiStack not configured"
    fi
}

# =============================================================================
# Storage Check
# =============================================================================
check_storage() {
    print_section "Storage Configuration"

    test_start "StorageClasses"
    local sc_count
    sc_count=$(oc get sc 2>/dev/null | grep -v NAME | wc -l)
    if [ "$sc_count" -gt 0 ]; then
        test_pass "StorageClasses: $sc_count"
        [ "$VERBOSE" = "--verbose" ] && oc get sc
    else
        test_fail "No StorageClasses found"
    fi

    test_start "Default StorageClass"
    if oc get sc 2>/dev/null | grep -q "(default)"; then
        local default_sc
        default_sc=$(oc get sc 2>/dev/null | grep "(default)" | awk '{print $1}')
        test_pass "Default StorageClass: $default_sc"
    else
        test_warn "No default StorageClass configured"
    fi

    test_start "iSCSI configuration"
    local iscsi_pvs
    iscsi_pvs=$(oc get pv 2>/dev/null | grep -i iscsi | wc -l)
    if [ "$iscsi_pvs" -gt 0 ]; then
        test_pass "iSCSI PVs: $iscsi_pvs found"
    else
        test_skip "No iSCSI PVs (see operators/iscsi-storage.md)"
    fi
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
    print_section "Test Summary"

    local total_executed=$((PASSED + FAILED + WARNED))
    local pass_rate=0
    [ "$total_executed" -gt 0 ] && pass_rate=$((PASSED * 100 / total_executed))

    echo ""
    printf "  %-20s %3d\n" "Total Tests:" "$TOTAL"
    printf "  ${GREEN}%-20s %3d${NC}\n" "Passed:" "$PASSED"
    printf "  ${RED}%-20s %3d${NC}\n" "Failed:" "$FAILED"
    printf "  ${YELLOW}%-20s %3d${NC}\n" "Warnings:" "$WARNED"
    printf "  ${GRAY}%-20s %3d${NC}\n" "Skipped:" "$SKIPPED"
    echo ""
    printf "  Pass Rate: %d%%\n" "$pass_rate"
    echo ""

    if [ "$FAILED" -eq 0 ]; then
        print_ok "All critical checks passed!"
    else
        print_fail "$FAILED critical check(s) failed"
        echo ""
        echo "  Review the output above and run the corresponding lab scripts."
    fi

    if [ "$WARNED" -gt 0 ]; then
        echo ""
        print_warn "$WARNED optional feature(s) not configured"
        echo "  These are optional but recommended for full POC coverage."
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    clear
    echo ""
    echo "╔════════════════════════════════════════════════════════════════╗"
    echo "║                                                                ║"
    echo "║   OpenShift Virtualization Feature Verification Script        ║"
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
