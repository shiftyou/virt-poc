#!/bin/bash
# =============================================================================
# 09-alert.sh
#
# VM Alert 실습 환경 구성
#   1. poc-alert namespace 생성
#   2. 사용자 정의 프로젝트 모니터링 활성화
#   3. PrometheusRule (VM 알림 규칙) 배포
#
# 사용법: ./09-alert.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

source "${SCRIPT_DIR}/../utils/common.sh"

NS="poc-alert"
VM_NAME="poc-alert-vm"
ALERT_VM_NAME="${ALERT_VM_NAME:-${VM_NAME}}"
ALERT_VM_NS="${ALERT_VM_NS:-${NS}}"

preflight() {
    print_step "사전 점검"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 연결: $(oc whoami) @ $(oc whoami --show-server)"

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "VIRT_INSTALLED=false — VM 생성 단계를 건너뜁니다."
    else
        if ! oc get template poc -n openshift &>/dev/null; then
            print_warn "poc Template을 찾을 수 없습니다 — VM 생성 건너뜀 (먼저 01-template을 실행하세요)"
        else
            print_ok "poc Template 확인됨"
        fi
    fi
}

step_namespace() {
    print_step "1/4  namespace 생성 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "Namespace $NS 이미 존재합니다 — 건너뜀"
    else
        oc new-project "$NS" > /dev/null
        print_ok "Namespace $NS 생성됨"
    fi
}

step_user_workload_monitoring() {
    print_step "2/5  사용자 정의 프로젝트 모니터링 활성화"

    local current
    current=$(oc get configmap cluster-monitoring-config \
        -n openshift-monitoring \
        -o jsonpath='{.data.config\.yaml}' 2>/dev/null || true)

    if echo "$current" | grep -q "enableUserWorkload: true"; then
        print_ok "User Workload Monitoring 이미 활성화되어 있습니다 — 건너뜀"
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
    print_ok "User Workload Monitoring 활성화됨"

    # Pod 시작 대기
    print_info "openshift-user-workload-monitoring Pod 시작 대기 중..."
    local retries=18
    local i=0
    while [ $i -lt $retries ]; do
        local ready
        ready=$(oc get pods -n openshift-user-workload-monitoring \
            --no-headers 2>/dev/null | grep -c "Running" || true)
        if [ "$ready" -ge 2 ]; then
            print_ok "User Workload Monitoring Pod 준비 완료 (${ready}개 Running)"
            break
        fi
        printf "  [%d/%d] 대기 중... (%s Running)\r" "$((i+1))" "$retries" "$ready"
        sleep 10
        i=$((i+1))
    done
    echo ""
}

step_prometheus_rule() {
    print_step "3/5  PrometheusRule (VM 알림 규칙) 배포"

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
    print_ok "PrometheusRule poc-vm-alerts 배포됨"
}

step_consoleyamlsamples() {
    print_step "5/5  ConsoleYAMLSample 등록"

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
    print_ok "ConsoleYAMLSample poc-prometheusrule-vm-alerts 등록됨"
}

step_vm() {
    print_step "4/5  VM 생성 (poc 템플릿 — Alert 트리거 테스트용)"

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "VIRT_INSTALLED=false — VM 생성 건너뜀"
        return
    fi

    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc Template을 찾을 수 없습니다 — VM 생성 건너뜀 (먼저 01-template을 실행하세요)"
        return
    fi

    if oc get vm "$VM_NAME" -n "$NS" &>/dev/null; then
        print_ok "VM $VM_NAME 이미 존재합니다 — 건너뜀"
    else
        oc process -n openshift poc -p NAME="$VM_NAME" | \
            sed 's/runStrategy: Always/runStrategy: Halted/' | sed 's/  running: false/  runStrategy: Halted/' | \
            oc apply -n "$NS" -f -
        print_ok "VM $VM_NAME 생성됨"
    fi

    virtctl start "$VM_NAME" -n "$NS" 2>/dev/null || true
    print_ok "VM $VM_NAME 시작됨 — Running 상태 이후 알림 트리거 테스트 가능"
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! VM Alert 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  PrometheusRule 확인:"
    echo -e "    ${CYAN}oc get prometheusrule -n ${NS}${NC}"
    echo ""
    echo -e "  VM 상태 확인:"
    echo -e "    ${CYAN}oc get vm,vmi -n ${NS}${NC}"
    echo ""
    echo -e "  Alert 상태 확인:"
    echo -e "    ${CYAN}OpenShift Console → Observe → Alerting → Alert Rules${NC}"
    echo -e "    ${CYAN}oc get prometheusrule -n ${NS}${NC}"
    echo ""
    echo -e "  모니터링 대상 VM:"
    echo -e "    이름      : ${CYAN}${ALERT_VM_NAME}${NC}"
    echo -e "    Namespace : ${CYAN}${ALERT_VM_NS}${NC}"
    echo -e "    변경 방법 : ${CYAN}ALERT_VM_NAME=<vm> ALERT_VM_NS=<ns> ./09-alert.sh${NC}"
    echo ""
    echo -e "  알림 트리거 테스트 (예시):"
    echo -e "    ${CYAN}# VMStoppedByName — 지정된 VM 중지 1분 후 발생${NC}"
    echo -e "    ${CYAN}virtctl stop ${ALERT_VM_NAME} -n ${ALERT_VM_NS}${NC}"
    echo ""
    echo -e "    ${CYAN}# VMStopped — namespace 내 VM이 중지되면 발생${NC}"
    echo -e "    ${CYAN}virtctl stop ${VM_NAME} -n ${NS}${NC}"
    echo ""
    echo -e "    ${CYAN}# 복구${NC}"
    echo -e "    ${CYAN}virtctl start ${ALERT_VM_NAME} -n ${ALERT_VM_NS}${NC}"
    echo ""
    echo -e "  자세한 내용: 09-alert.md 참조"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 09-alert 리소스 삭제"
    oc delete project poc-alert --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-prometheusrule-vm-alerts --ignore-not-found 2>/dev/null || true
    print_ok "09-alert 리소스 삭제됨"
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  VM Alert 실습 환경 구성${NC}"
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
