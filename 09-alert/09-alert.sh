#!/bin/bash
# =============================================================================
# 08-alert.sh
#
# VM Alert practice environment setup
#   1. Create poc-alert namespace
#   2. Enable user-defined project monitoring
#   3. Deploy PrometheusRule (VM alert rules)
#
# Usage: ./08-alert.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-alert"
VM_NAME="poc-alert-vm"
ALERT_VM_NAME="${ALERT_VM_NAME:-${VM_NAME}}"   # Specific VM name to monitor (can be overridden via env.conf or environment variable)
ALERT_VM_NS="${ALERT_VM_NS:-${NS}}"            # Namespace of the specific VM to monitor

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

print_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERR ]${NC} $1"; }
print_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

preflight() {
    print_step "Pre-flight checks"

    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift."
        exit 1
    fi
    print_ok "Cluster connection: $(oc whoami) @ $(oc whoami --show-server)"

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "VIRT_INSTALLED=false — VM creation step will be skipped."
    else
        if ! oc get template poc -n openshift &>/dev/null; then
            print_warn "poc Template not found — skipping VM creation (run 01-template first)"
        else
            print_ok "poc Template confirmed"
        fi
    fi
}

step_namespace() {
    print_step "1/4  Create namespace (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "Namespace $NS already exists — skipping"
    else
        oc new-project "$NS" > /dev/null
        print_ok "Namespace $NS created"
    fi
}

step_user_workload_monitoring() {
    print_step "2/5  Enable User-defined Project Monitoring"

    local current
    current=$(oc get configmap cluster-monitoring-config \
        -n openshift-monitoring \
        -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)

    if echo "$current" | grep -q "enableUserWorkload: true"; then
        print_ok "User Workload Monitoring already enabled — skipping"
        return
    fi

    cat > cluster-monitoring-config.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-monitoring-config
  namespace: openshift-monitoring
data:
  config.yaml: |
    enableUserWorkload: true
EOF
    oc apply -f cluster-monitoring-config.yaml
    print_ok "User Workload Monitoring enabled"

    # Wait for Pods to start
    print_info "Waiting for openshift-user-workload-monitoring Pods to start..."
    local retries=18
    local i=0
    while [ $i -lt $retries ]; do
        local ready
        ready=$(oc get pods -n openshift-user-workload-monitoring \
            --no-headers 2>/dev/null | grep -c "Running" || true)
        if [ "$ready" -ge 2 ]; then
            print_ok "User Workload Monitoring Pods ready (${ready} Running)"
            break
        fi
        printf "  [%d/%d] Waiting... (%s Running)\r" "$((i+1))" "$retries" "$ready"
        sleep 10
        i=$((i+1))
    done
    echo ""
}

step_prometheus_rule() {
    print_step "3/5  Deploy PrometheusRule (VM alert rules)"

    cat > poc-vm-alerts.yaml <<EOF
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: poc-vm-alerts
  namespace: ${NS}
  labels:
    role: alert-rules
spec:
  groups:
    - name: poc-vm-availability
      interval: 30s
      rules:
        - alert: VMStoppedByName
          expr: |
            (
              kubevirt_vm_info{name="${ALERT_VM_NAME}", namespace="${ALERT_VM_NS}"}
            ) unless on(name, namespace) (
              kubevirt_vmi_info{name="${ALERT_VM_NAME}", namespace="${ALERT_VM_NS}"}
            )
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "Specified VM {{ \$labels.name }} has stopped"
            description: "VM {{ \$labels.name }} in namespace {{ \$labels.namespace }} is stopped. VMI does not exist. Immediate attention required."
        - alert: VMStopped
          expr: |
            kubevirt_vmi_phase_count{phase="succeeded"} > 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "VM has stopped"
            description: "{{ \$value }} VM(s) in succeeded (stopped) state detected in namespace {{ \$labels.namespace }}."
        - alert: VMStuckPending
          expr: |
            kubevirt_vmi_phase_count{phase="pending"} > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "VM is waiting in pending state"
            description: "{{ \$value }} VM(s) in pending state exist in namespace {{ \$labels.namespace }}."
        - alert: VMStuckStarting
          expr: |
            kubevirt_vmi_phase_count{phase=~"scheduling|scheduled"} > 0
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "VM is stuck while starting"
            description: "VM(s) in {{ \$labels.phase }} state have persisted for more than 10 minutes in namespace {{ \$labels.namespace }}."
        - alert: VMLiveMigrationFailed
          expr: |
            increase(kubevirt_vmi_migration_phase_transition_time_seconds_count{phase="Failed"}[10m]) > 0
          labels:
            severity: warning
          annotations:
            summary: "VM Live Migration has failed"
            description: "Live Migration of VM {{ \$labels.vmi }} has failed."
    - name: poc-vm-resources
      interval: 60s
      rules:
        - alert: VMLowMemory
          expr: |
            kubevirt_vmi_memory_available_bytes < 100 * 1024 * 1024
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "VM memory is running low"
            description: "Available memory for VM {{ \$labels.name }} (namespace: {{ \$labels.namespace }}) is {{ \$value | humanize }}."
EOF
    oc apply -f poc-vm-alerts.yaml
    print_ok "PrometheusRule poc-vm-alerts deployed"
}

step_consoleyamlsamples() {
    print_step "5/5  Register ConsoleYAMLSample"

    cat > consoleyamlsample-prometheusrule.yaml <<'EOF'
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-prometheusrule-vm-alerts
spec:
  title: "POC PrometheusRule VM Alert Rules"
  description: "A PrometheusRule example that detects major VM status anomalies such as VM stopped, Pending, Migration failure, etc. Use in environments where User-defined Project Monitoring is enabled."
  targetResource:
    apiVersion: monitoring.coreos.com/v1
    kind: PrometheusRule
  yaml: |
    apiVersion: monitoring.coreos.com/v1
    kind: PrometheusRule
    metadata:
      name: poc-vm-alerts
      namespace: poc-alert
      labels:
        role: alert-rules
    spec:
      groups:
        - name: poc-vm-availability
          interval: 30s
          rules:
            - alert: VMStoppedByName
              expr: |
                (
                  kubevirt_vm_info{name="poc-alert-vm", namespace="poc-alert"}
                ) unless on(name, namespace) (
                  kubevirt_vmi_info{name="poc-alert-vm", namespace="poc-alert"}
                )
              for: 1m
              labels:
                severity: critical
              annotations:
                summary: "Specified VM {{ $labels.name }} has stopped"
                description: "VM {{ $labels.name }} in namespace {{ $labels.namespace }} is stopped."
            - alert: VMStopped
              expr: |
                kubevirt_vmi_phase_count{phase="succeeded"} > 0
              for: 2m
              labels:
                severity: critical
              annotations:
                summary: "VM has stopped"
                description: "{{ $value }} VM(s) in succeeded state detected in namespace {{ $labels.namespace }}."
            - alert: VMStuckPending
              expr: |
                kubevirt_vmi_phase_count{phase="pending"} > 0
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "VM is waiting in pending state"
                description: "{{ $value }} VM(s) in pending state exist in namespace {{ $labels.namespace }}."
            - alert: VMLiveMigrationFailed
              expr: |
                increase(kubevirt_vmi_migration_phase_transition_time_seconds_count{phase="Failed"}[10m]) > 0
              labels:
                severity: warning
              annotations:
                summary: "VM Live Migration has failed"
                description: "Live Migration of VM {{ $labels.vmi }} has failed."
EOF
    oc apply -f consoleyamlsample-prometheusrule.yaml
    print_ok "ConsoleYAMLSample poc-prometheusrule-vm-alerts registered"
}

step_vm() {
    print_step "4/5  Create VM (poc template — for Alert trigger testing)"

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "VIRT_INSTALLED=false — skipping VM creation"
        return
    fi

    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc Template not found — skipping VM creation (run 01-template first)"
        return
    fi

    if oc get vm "$VM_NAME" -n "$NS" &>/dev/null; then
        print_ok "VM $VM_NAME already exists — skipping"
    else
        oc process -n openshift poc -p NAME="$VM_NAME" | \
            sed 's/runStrategy: Always/runStrategy: Halted/' | sed 's/  running: false/  runStrategy: Halted/' | \
            oc apply -n "$NS" -f -
        print_ok "VM $VM_NAME created"
    fi

    virtctl start "$VM_NAME" -n "$NS" 2>/dev/null || true
    print_ok "VM $VM_NAME started — alert trigger testing available after Running state"
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! VM Alert practice environment is ready.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Check PrometheusRule:"
    echo -e "    ${CYAN}oc get prometheusrule -n ${NS}${NC}"
    echo ""
    echo -e "  Check VM status:"
    echo -e "    ${CYAN}oc get vm,vmi -n ${NS}${NC}"
    echo ""
    echo -e "  Check Alert status:"
    echo -e "    ${CYAN}OpenShift Console → Observe → Alerting → Alert Rules${NC}"
    echo -e "    ${CYAN}oc get prometheusrule -n ${NS}${NC}"
    echo ""
    echo -e "  Monitored specific VM:"
    echo -e "    Name      : ${CYAN}${ALERT_VM_NAME}${NC}"
    echo -e "    Namespace : ${CYAN}${ALERT_VM_NS}${NC}"
    echo -e "    To change : ${CYAN}ALERT_VM_NAME=<vm> ALERT_VM_NS=<ns> ./09-alert.sh${NC}"
    echo ""
    echo -e "  Alert trigger test (examples):"
    echo -e "    ${CYAN}# VMStoppedByName — fires 1 minute after specified VM stops${NC}"
    echo -e "    ${CYAN}virtctl stop ${ALERT_VM_NAME} -n ${ALERT_VM_NS}${NC}"
    echo ""
    echo -e "    ${CYAN}# VMStopped — fires when any VM in the namespace stops${NC}"
    echo -e "    ${CYAN}virtctl stop ${VM_NAME} -n ${NS}${NC}"
    echo ""
    echo -e "    ${CYAN}# Recovery${NC}"
    echo -e "    ${CYAN}virtctl start ${ALERT_VM_NAME} -n ${ALERT_VM_NS}${NC}"
    echo ""
    echo -e "  For details: refer to 09-alert.md"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Delete 09-alert resources"
    oc delete project poc-alert --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-prometheusrule-vm-alerts --ignore-not-found 2>/dev/null || true
    print_ok "09-alert resources deleted"
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  VM Alert Practice Environment Setup${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_user_workload_monitoring
    step_prometheus_rule
    step_vm
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
