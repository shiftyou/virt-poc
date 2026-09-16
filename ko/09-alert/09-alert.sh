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
trap 'echo -e "\n\033[0;31m[오류]\033[0m ${LINENO}번째 줄에서 명령 실패: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

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
    auto_detect_operators() { :; }
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

NS="poc-alert"
VM_NAME="poc-alert-vm"
ALERT_VM_NAME="${ALERT_VM_NAME:-${VM_NAME}}"
ALERT_VM_NS="${ALERT_VM_NS:-${NS}}"

preflight() {
    print_step "사전 점검"
    auto_detect_operators

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
            summary: "지정된 VM {{ \$labels.name }}이(가) 중지됨"
            description: "namespace {{ \$labels.namespace }}의 VM {{ \$labels.name }}이(가) 중지되었습니다. VMI가 존재하지 않습니다. 즉시 확인이 필요합니다."
        - alert: VMStopped
          expr: |
            kubevirt_vmi_phase_count{phase="succeeded"} > 0
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "VM이 중지됨"
            description: "namespace {{ \$labels.namespace }}에서 {{ \$value }}개의 VM이 succeeded(중지) 상태로 감지되었습니다."
        - alert: VMStuckPending
          expr: |
            kubevirt_vmi_phase_count{phase="pending"} > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "VM이 pending 상태에서 대기 중"
            description: "namespace {{ \$labels.namespace }}에 {{ \$value }}개의 VM이 pending 상태로 존재합니다."
        - alert: VMStuckStarting
          expr: |
            kubevirt_vmi_phase_count{phase=~"scheduling|scheduled"} > 0
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "VM이 시작 중 멈춤"
            description: "namespace {{ \$labels.namespace }}에서 VM이 {{ \$labels.phase }} 상태로 10분 이상 지속되고 있습니다."
        - alert: VMLiveMigrationFailed
          expr: |
            increase(kubevirt_vmi_migration_phase_transition_time_seconds_count{phase="Failed"}[10m]) > 0
          labels:
            severity: warning
          annotations:
            summary: "VM Live Migration 실패"
            description: "VM {{ \$labels.vmi }}의 Live Migration이 실패했습니다."
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
            summary: "VM 메모리 부족"
            description: "VM {{ \$labels.name }} (namespace: {{ \$labels.namespace }})의 가용 메모리가 {{ \$value | humanize }}입니다."
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
  title: "POC PrometheusRule VM 알림 규칙"
  description: "VM 중지, Pending 상태 지속, Migration 실패 등 주요 VM 상태 이상을 감지하는 PrometheusRule 예제입니다. 사용자 정의 프로젝트 모니터링이 활성화된 환경에서 사용하세요."
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
                summary: "지정된 VM {{ $labels.name }}이(가) 중지됨"
                description: "namespace {{ $labels.namespace }}의 VM {{ $labels.name }}이(가) 중지되었습니다."
            - alert: VMStopped
              expr: |
                kubevirt_vmi_phase_count{phase="succeeded"} > 0
              for: 2m
              labels:
                severity: critical
              annotations:
                summary: "VM이 중지됨"
                description: "namespace {{ $labels.namespace }}에서 {{ $value }}개의 VM이 succeeded 상태로 감지되었습니다."
            - alert: VMStuckPending
              expr: |
                kubevirt_vmi_phase_count{phase="pending"} > 0
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "VM이 pending 상태에서 대기 중"
                description: "namespace {{ $labels.namespace }}에 {{ $value }}개의 VM이 pending 상태로 존재합니다."
            - alert: VMLiveMigrationFailed
              expr: |
                increase(kubevirt_vmi_migration_phase_transition_time_seconds_count{phase="Failed"}[10m]) > 0
              labels:
                severity: warning
              annotations:
                summary: "VM Live Migration 실패"
                description: "VM {{ $labels.vmi }}의 Live Migration이 실패했습니다."
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
