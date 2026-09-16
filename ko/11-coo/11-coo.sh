#!/bin/bash
# =============================================================================
# 11-coo.sh
#
# Cluster Observability Operator (COO) + VM node_exporter 구성
#   1/5  poc-monitoring Namespace 생성
#   2/5  poc 템플릿 VM + node-exporter Service + ServiceMonitor 생성
#   3/5  COO MonitoringStack + ServiceMonitor (monitoring.rhobs/v1) + PrometheusRule
#   4/5  VM OS Metrics 대시보드 (COO-Prometheus / node_exporter)
#   5/5  Grafana에 COO Prometheus DataSource 등록 (GRAFANA_INSTALLED=true인 경우)
#
# 사용법: ./11-coo.sh
# =============================================================================

set -euo pipefail
trap 'echo -e "\n\033[0;31m[오류]\033[0m ${LINENO}번째 줄에서 명령 실패: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-monitoring"
VM_NAME="poc-coo-vm"

if [ -f "${SCRIPT_DIR}/../utils/common.sh" ]; then
    source "${SCRIPT_DIR}/../utils/common.sh"
else
    # ── 독립 실행 모드: common.sh 없이 인라인 헬퍼 사용 ──
    RED='\033[0;31m'; GREEN='\033[0;32m'; DIM='\033[2m'
    POC_VERSION=$(cat "${SCRIPT_DIR}/../../VERSION" 2>/dev/null || echo "dev")
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

preflight() {
    print_step "사전 점검"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 연결: $(oc whoami) @ $(oc whoami --show-server)"

    # env.conf에 없으면 클러스터 CSV에서 자동 감지
    if [ "${COO_INSTALLED:-false}" != "true" ]; then
        if oc get csv --all-namespaces --no-headers 2>/dev/null \
            | grep -qi "cluster-observability-operator"; then
            COO_INSTALLED=true
            print_ok "Cluster Observability Operator 자동 감지됨 (CSV)"
        fi
    fi

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        if oc get csv --all-namespaces --no-headers 2>/dev/null \
            | grep -qi "kubevirt-hyperconverged"; then
            VIRT_INSTALLED=true
            print_ok "OpenShift Virtualization 자동 감지됨 (CSV)"
        fi
    fi

    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        if oc get csv --all-namespaces --no-headers 2>/dev/null \
            | grep -qi "grafana-operator"; then
            GRAFANA_INSTALLED=true
            print_ok "Grafana Community Operator 자동 감지됨 (CSV)"
        fi
    fi

    if [ "${COO_INSTALLED:-false}" != "true" ]; then
        print_error "Cluster Observability Operator가 설치되어 있지 않습니다."
        echo ""
        print_info "OperatorHub에서 COO를 설치하거나 매니페스트를 적용하세요:"
        echo -e "  ${CYAN}# OperatorHub → Red Hat operators → 'Cluster Observability Operator'에서 설치${NC}"
        echo ""
        print_info "설치 후 확인:"
        echo -e "  ${CYAN}oc get csv --all-namespaces | grep cluster-observability-operator${NC}"
        print_info "그런 다음 이 스크립트를 다시 실행하세요."
        echo ""
        exit 77
    fi

    print_ok "Cluster Observability Operator 확인됨"

    if [ "${VIRT_INSTALLED:-false}" = "true" ]; then
        print_ok "OpenShift Virtualization 확인됨 — VM 생성 단계가 실행됩니다."
    else
        print_warn "OpenShift Virtualization이 설치되어 있지 않습니다 — VM 생성 단계를 건너뜁니다."
    fi

    if [ "${GRAFANA_INSTALLED:-false}" = "true" ]; then
        print_ok "Grafana Community Operator 확인됨 — 5/5 단계에서 COO datasource를 등록합니다."
    else
        print_warn "Grafana Operator가 설치되어 있지 않습니다 — 5/5 단계(datasource 등록)를 건너뜁니다."
    fi
}

step_namespace() {
    print_step "1/5  Namespace 생성 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        local ns_phase
        ns_phase=$(oc get namespace "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

        if [ "$ns_phase" = "Terminating" ]; then
            print_warn "Namespace ${NS}가 Terminating 상태입니다 — 삭제 완료 대기 중..."
            local retries=36
            local i=0
            while [ "$i" -lt "$retries" ]; do
                if ! oc get namespace "$NS" &>/dev/null; then
                    print_ok "Namespace 삭제 완료"
                    break
                fi
                printf "  [%d/%d] Terminating 대기 중...\r" "$((i+1))" "$retries"
                sleep 5
                i=$((i+1))
            done
            echo ""

            if oc get namespace "$NS" &>/dev/null; then
                print_error "Namespace ${NS}가 여전히 Terminating 상태입니다."
                print_info "수동 확인: oc get namespace $NS -o yaml"
                print_info "finalizer 강제 제거: oc patch namespace $NS -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge"
                exit 1
            fi

            oc new-project "$NS" > /dev/null
            print_ok "Namespace $NS 재생성됨"
        else
            print_ok "Namespace $NS 이미 존재합니다 (Active) — 건너뜀"
        fi
    else
        oc new-project "$NS" > /dev/null
        print_ok "Namespace $NS 생성됨"
    fi
}

step_vm() {
    if [ "${COO_INSTALLED:-false}" != "true" ] || [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        return
    fi
    print_step "2/5  poc 템플릿 VM 생성 (${VM_NAME})"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc Template을 찾을 수 없습니다 — 먼저 01-template을 실행하세요. VM 생성 건너뜀."
        return
    fi
    print_ok "poc Template 확인됨"

    if ! command -v virtctl &>/dev/null; then
        print_warn "virtctl을 찾을 수 없습니다 — VM 생성 건너뜀."
        return
    fi

    # VM 생성
    if oc get vm "$VM_NAME" -n "$NS" &>/dev/null; then
        print_ok "VM $VM_NAME 이미 존재합니다 — 건너뜀"
    else
        oc process -n openshift poc -p NAME="$VM_NAME" > ./${VM_NAME}.yaml
        oc apply -n "$NS" -f ./${VM_NAME}.yaml
        print_ok "VM $VM_NAME 생성됨"
    fi

    # virt-launcher Pod에 monitor=metrics 레이블 전파
    oc patch vm "$VM_NAME" -n "$NS" --type=merge -p '{
      "spec": {
        "template": {
          "metadata": {
            "labels": {
              "monitor": "metrics"
            }
          }
        }
      }
    }' 2>/dev/null && print_ok "Label monitor=metrics 구성됨" || true

    # node-exporter Service 생성
    # virt-launcher Pod(monitor=metrics)에서 VM 내부 node-exporter(9100)로 트래픽 전달
    if oc get svc poc-monitoring-node-exporter -n "$NS" &>/dev/null; then
        print_ok "Service poc-monitoring-node-exporter 이미 존재합니다 — 건너뜀"
    else
        cat > ./poc-monitoring-vm-service.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: poc-monitoring-node-exporter
  namespace: ${NS}
  labels:
    app: poc-monitoring-vm
    monitoring.rhobs/stack: poc-monitoring-stack
spec:
  ports:
    - name: metrics
      protocol: TCP
      port: 9100
      targetPort: 9100
  selector:
    monitor: metrics
  type: ClusterIP
EOF
        oc apply -f ./poc-monitoring-vm-service.yaml
        print_ok "Service poc-monitoring-node-exporter 생성됨"
    fi

    # Namespace에 user-workload monitoring 레이블 추가 (OpenShift Console 가시성)
    oc label namespace "$NS" openshift.io/cluster-monitoring=true --overwrite 2>/dev/null || true
    print_ok "user-workload monitoring 레이블 구성됨"

    # OpenShift Console Observe 탭용 ServiceMonitor (monitoring.coreos.com/v1)
    if oc get servicemonitor poc-vm-node-exporter-console -n "$NS" &>/dev/null; then
        print_ok "ServiceMonitor poc-vm-node-exporter-console 이미 존재합니다 — 건너뜀"
    else
        cat > ./poc-vm-servicemonitor-console.yaml <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: poc-vm-node-exporter-console
  namespace: ${NS}
  labels:
    app: poc-monitoring-vm
spec:
  selector:
    matchLabels:
      app: poc-monitoring-vm
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
      relabelings:
        - targetLabel: job
          replacement: poc-monitoring-vm
        - sourceLabels: [__meta_kubernetes_endpoint_hostname]
          targetLabel: vmname
EOF
        oc apply -f ./poc-vm-servicemonitor-console.yaml
        print_ok "ServiceMonitor poc-vm-node-exporter-console 생성됨 (OpenShift Console용)"
    fi

    # VM 시작
    virtctl start "$VM_NAME" -n "$NS" 2>/dev/null || true
    print_info "VM 시작 요청됨 — Running 상태까지 시간이 걸릴 수 있습니다."
    print_warn "VM 내부 node_exporter 설치가 필요합니다 (10-node-exporter/node-exporter-install.sh 참조)"
    print_info "  oc get vmi $VM_NAME -n $NS"
}

step_coo() {
    if [ "${COO_INSTALLED:-false}" != "true" ]; then
        return
    fi
    print_step "3/5  Cluster Observability Operator (COO) 구성"

    # MonitoringStack CRD 확인
    if ! oc get crd monitoringstacks.monitoring.rhobs &>/dev/null; then
        print_warn "MonitoringStack CRD를 찾을 수 없습니다 — COO가 완전히 설치되지 않았습니다."
        return
    fi
    print_ok "MonitoringStack CRD 확인됨"

    # MonitoringStack 생성
    if oc get monitoringstack poc-monitoring-stack -n "$NS" &>/dev/null; then
        print_ok "MonitoringStack poc-monitoring-stack 이미 존재합니다 — 건너뜀"
    else
        cat > ./poc-monitoring-stack.yaml <<EOF
apiVersion: monitoring.rhobs/v1alpha1
kind: MonitoringStack
metadata:
  name: poc-monitoring-stack
  namespace: ${NS}
spec:
  logLevel: info
  retention: 24h
  resourceSelector:
    matchLabels:
      monitoring.rhobs/stack: poc-monitoring-stack
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  prometheusConfig:
    replicas: 1
  alertmanagerConfig:
    enabled: true
EOF
        oc apply -f ./poc-monitoring-stack.yaml
        print_ok "MonitoringStack poc-monitoring-stack 배포됨"
    fi

    # VM node-exporter용 ServiceMonitor (monitoring.rhobs/v1 — COO 전용)
    if [ "${VIRT_INSTALLED:-false}" = "true" ]; then
        if oc get servicemonitor.monitoring.rhobs poc-vm-node-exporter -n "$NS" &>/dev/null; then
            print_ok "ServiceMonitor poc-vm-node-exporter 이미 존재합니다 — 건너뜀"
        else
            cat > ./poc-vm-servicemonitor-coo.yaml <<EOF
apiVersion: monitoring.rhobs/v1
kind: ServiceMonitor
metadata:
  name: poc-vm-node-exporter
  namespace: ${NS}
  labels:
    monitoring.rhobs/stack: poc-monitoring-stack
spec:
  selector:
    matchLabels:
      app: poc-monitoring-vm
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
      relabelings:
        - targetLabel: job
          replacement: poc-monitoring-vm
        - sourceLabels: [__meta_kubernetes_endpoint_hostname]
          targetLabel: vmname
EOF
            oc apply -f ./poc-vm-servicemonitor-coo.yaml
            print_ok "ServiceMonitor poc-vm-node-exporter 생성됨 (COO 전용)"
        fi
    fi

    # PrometheusRule (VM 알림 규칙)
    if oc get prometheusrule poc-vm-alerts -n "$NS" &>/dev/null; then
        print_ok "PrometheusRule poc-vm-alerts 이미 존재합니다 — 건너뜀"
    else
        cat > ./poc-vm-alerts.yaml <<EOF
apiVersion: monitoring.rhobs/v1
kind: PrometheusRule
metadata:
  name: poc-vm-alerts
  namespace: ${NS}
  labels:
    monitoring.rhobs/stack: poc-monitoring-stack
spec:
  groups:
    - name: vm.rules
      interval: 30s
      rules:
        - alert: VMNotRunning
          expr: kubevirt_vmi_phase_count{phase!~"Running|running|Paused|paused"} > 0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "VM이 Running 상태가 아님"
            description: "VM {{ \$labels.name }} 상태: {{ \$labels.phase }}"
        - alert: VMHighMemoryUsage
          expr: >
            (kubevirt_vmi_memory_resident_bytes /
             (kubevirt_vmi_memory_resident_bytes + kubevirt_vmi_memory_available_bytes)) > 0.9
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "VM 메모리 사용률 90% 초과"
            description: "VM {{ \$labels.name }}의 메모리 사용률이 높습니다."
EOF
        oc apply -f ./poc-vm-alerts.yaml
        print_ok "PrometheusRule poc-vm-alerts 생성됨"
    fi

    # 모든 namespace의 VMI에 대한 node_exporter 스크래핑 구성
    print_info "모든 클러스터 VMI에 대한 node_exporter Service/ServiceMonitor 구성 중..."
    local vmi_ns_list
    vmi_ns_list=$(oc get vmi --all-namespaces --no-headers 2>/dev/null \
        | awk '{print $1}' | sort -u || true)

    if [ -z "$vmi_ns_list" ]; then
        print_warn "실행 중인 VMI가 없습니다 — namespace별 node_exporter 구성을 건너뜁니다."
    else
        while IFS= read -r vmi_ns; do
            [ -z "$vmi_ns" ] && continue

            # virt-launcher Pod에 monitor=metrics 레이블 추가
            oc label pods -n "$vmi_ns" -l "kubevirt.io=virt-launcher" \
                monitor=metrics --overwrite 2>/dev/null || true

            # Headless Service — 각 Pod에서 node_exporter(9100)를 직접 수집
            cat > ./vm-ne-svc.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: vm-node-exporter
  namespace: ${vmi_ns}
  labels:
    app: vm-node-exporter
    monitoring.rhobs/stack: poc-monitoring-stack
spec:
  clusterIP: None
  ports:
    - name: metrics
      port: 9100
      targetPort: 9100
  selector:
    monitor: metrics
EOF
            oc apply -f ./vm-ne-svc.yaml

            # ServiceMonitor (monitoring.rhobs/v1 — COO 전용)
            cat > ./vm-ne-sm.yaml <<EOF
apiVersion: monitoring.rhobs/v1
kind: ServiceMonitor
metadata:
  name: vm-node-exporter
  namespace: ${vmi_ns}
  labels:
    monitoring.rhobs/stack: poc-monitoring-stack
spec:
  selector:
    matchLabels:
      app: vm-node-exporter
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
      relabelings:
        - targetLabel: job
          replacement: vm-node-exporter
        - sourceLabels: [__meta_kubernetes_pod_label_vm_kubevirt_io_name]
          targetLabel: vmname
        - targetLabel: vm_namespace
          replacement: ${vmi_ns}
EOF
            oc apply -f ./vm-ne-sm.yaml

            print_ok "  [${vmi_ns}] Service + ServiceMonitor 완료"
        done <<< "$vmi_ns_list"
    fi

    print_info "MonitoringStack Pod 시작 대기 중..."
    local retries=12
    local i=0
    while [ $i -lt $retries ]; do
        local ready
        ready=$(oc get pods -n "$NS" -l app.kubernetes.io/name=prometheus \
            --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
        if [ "$ready" -ge 1 ]; then
            print_ok "COO Prometheus Pod 실행 중"
            break
        fi
        printf "  [%d/%d] COO Prometheus 대기 중...\r" "$((i+1))" "$retries"
        sleep 5
        i=$((i+1))
    done
    echo ""
}

step_coo_dashboard() {
    print_step "4/5  VM OS Metrics 대시보드 배포 (COO-Prometheus / node_exporter)"

    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        print_warn "Grafana Operator가 설치되어 있지 않습니다 — 대시보드 배포 건너뜀."
        print_info "Grafana Operator 설치 후 12-grafana/12-grafana.sh를 실행하세요."
        return
    fi

    # 기존 CR 삭제 후 재생성
    if oc get grafanadashboard poc-vm-node-exporter -n "$NS" &>/dev/null; then
        print_info "GrafanaDashboard poc-vm-node-exporter: 기존 CR을 삭제하고 재생성 중..."
        oc delete grafanadashboard poc-vm-node-exporter -n "$NS" --wait=false 2>/dev/null || true
        sleep 2
    fi

    cat > ./poc-vm-node-exporter-dashboard.json << 'NEDASHEOF'
{
  "annotations": {"list": [{"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": true, "hide": true, "iconColor": "rgba(0,211,255,1)", "name": "Annotations & Alerts", "type": "dashboard"}]},
  "description": "VM internal OS metrics (node_exporter) — COO-Prometheus based",
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "refresh": "30s",
  "schemaVersion": 39,
  "tags": ["node-exporter", "vm", "poc", "coo"],
  "templating": {
    "list": [
      {
        "current": {"selected": false, "text": "COO-Prometheus", "value": "COO-Prometheus"},
        "hide": 0,
        "includeAll": false,
        "label": "Datasource",
        "multi": false,
        "name": "datasource",
        "options": [],
        "query": "prometheus",
        "refresh": 1,
        "type": "datasource"
      },
      {
        "allValue": ".*",
        "current": {"selected": true, "text": "All", "value": "$__all"},
        "datasource": {"type": "prometheus", "uid": "${datasource}"},
        "definition": "label_values(node_cpu_seconds_total{job=\"vm-node-exporter\"}, vm_namespace)",
        "hide": 0,
        "includeAll": true,
        "label": "Namespace",
        "multi": true,
        "name": "vm_namespace",
        "options": [],
        "query": {"query": "label_values(node_cpu_seconds_total{job=\"vm-node-exporter\"}, vm_namespace)", "refId": "Q"},
        "refresh": 2,
        "regex": "",
        "sort": 1,
        "type": "query"
      },
      {
        "allValue": ".*",
        "current": {"selected": true, "text": "All", "value": "$__all"},
        "datasource": {"type": "prometheus", "uid": "${datasource}"},
        "definition": "label_values(node_cpu_seconds_total{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\"}, vmname)",
        "hide": 0,
        "includeAll": true,
        "label": "VM Name",
        "multi": true,
        "name": "vmname",
        "options": [],
        "query": {"query": "label_values(node_cpu_seconds_total{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\"}, vmname)", "refId": "Q"},
        "refresh": 2,
        "regex": "",
        "sort": 1,
        "type": "query"
      }
    ]
  },
  "time": {"from": "now-1h", "to": "now"},
  "timepicker": {},
  "timezone": "browser",
  "title": "VM OS Metrics (node_exporter / COO)",
  "uid": "poc-vm-node-exporter",
  "version": 1,
  "panels": [
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0},
      "id": 100,
      "title": "VM Status Summary",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "thresholds"},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 70}, {"color": "red", "value": 90}]},
          "unit": "percent", "min": 0, "max": 100
        },
        "overrides": []
      },
      "gridPos": {"h": 4, "w": 12, "x": 0, "y": 1},
      "id": 1,
      "options": {"colorMode": "background", "graphMode": "area", "justifyMode": "center", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
      "title": "VM Average CPU Utilization",
      "type": "stat",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "100 - avg(rate(node_cpu_seconds_total{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\", mode=\"idle\"}[5m])) * 100",
          "legendFormat": "CPU %",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "thresholds"},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 70}, {"color": "red", "value": 90}]},
          "unit": "percent", "min": 0, "max": 100
        },
        "overrides": []
      },
      "gridPos": {"h": 4, "w": 12, "x": 12, "y": 1},
      "id": 2,
      "options": {"colorMode": "background", "graphMode": "area", "justifyMode": "center", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
      "title": "VM Average Memory Utilization",
      "type": "stat",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "100 * (1 - avg(node_memory_MemAvailable_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"} / node_memory_MemTotal_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"}))",
          "legendFormat": "Memory %",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 5},
      "id": 101,
      "title": "CPU",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {"axisBorderShow": false, "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0, "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none", "hideFrom": {"legend": false, "tooltip": false, "viz": false}, "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5, "scaleDistribution": {"type": "linear"}, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "none"}, "thresholdsStyle": {"mode": "off"}},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "percent", "min": 0, "max": 100
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 24, "x": 0, "y": 6},
      "id": 3,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "CPU Utilization (%) — Per VM",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "100 - rate(node_cpu_seconds_total{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\", mode=\"idle\"}[5m]) * 100",
          "legendFormat": "{{vm_namespace}}/{{vmname}} cpu{{cpu}}",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 14},
      "id": 102,
      "title": "Memory",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {"axisBorderShow": false, "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0, "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none", "hideFrom": {"legend": false, "tooltip": false, "viz": false}, "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5, "scaleDistribution": {"type": "linear"}, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "none"}, "thresholdsStyle": {"mode": "off"}},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "bytes"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 15},
      "id": 4,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "Memory Usage (Used)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "node_memory_MemTotal_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"} - node_memory_MemAvailable_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"}",
          "legendFormat": "{{vm_namespace}}/{{vmname}} used",
          "refId": "A"
        },
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "node_memory_MemTotal_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"}",
          "legendFormat": "{{vm_namespace}}/{{vmname}} total",
          "refId": "B"
        }
      ]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {"axisBorderShow": false, "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0, "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none", "hideFrom": {"legend": false, "tooltip": false, "viz": false}, "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5, "scaleDistribution": {"type": "linear"}, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "none"}, "thresholdsStyle": {"mode": "off"}},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "red", "value": 90}]},
          "unit": "percent", "min": 0, "max": 100
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 15},
      "id": 5,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "Memory Utilization (%)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "100 * (1 - node_memory_MemAvailable_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"} / node_memory_MemTotal_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"})",
          "legendFormat": "{{vm_namespace}}/{{vmname}}",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 23},
      "id": 103,
      "title": "Disk I/O",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {"axisBorderShow": false, "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0, "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none", "hideFrom": {"legend": false, "tooltip": false, "viz": false}, "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5, "scaleDistribution": {"type": "linear"}, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "none"}, "thresholdsStyle": {"mode": "off"}},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 24},
      "id": 6,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "Disk Read",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "rate(node_disk_read_bytes_total{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"}[5m])",
          "legendFormat": "{{vm_namespace}}/{{vmname}} [{{device}}]",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {"axisBorderShow": false, "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0, "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none", "hideFrom": {"legend": false, "tooltip": false, "viz": false}, "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5, "scaleDistribution": {"type": "linear"}, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "none"}, "thresholdsStyle": {"mode": "off"}},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 24},
      "id": 7,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "Disk Write",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "rate(node_disk_written_bytes_total{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"}[5m])",
          "legendFormat": "{{vm_namespace}}/{{vmname}} [{{device}}]",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 32},
      "id": 104,
      "title": "Network I/O",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {"axisBorderShow": false, "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0, "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none", "hideFrom": {"legend": false, "tooltip": false, "viz": false}, "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5, "scaleDistribution": {"type": "linear"}, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "none"}, "thresholdsStyle": {"mode": "off"}},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 33},
      "id": 8,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "Network Receive (RX)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "rate(node_network_receive_bytes_total{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\", device!=\"lo\"}[5m])",
          "legendFormat": "{{vm_namespace}}/{{vmname}} [{{device}}]",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {"axisBorderShow": false, "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0, "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none", "hideFrom": {"legend": false, "tooltip": false, "viz": false}, "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5, "scaleDistribution": {"type": "linear"}, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "none"}, "thresholdsStyle": {"mode": "off"}},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 33},
      "id": 9,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "Network Transmit (TX)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "rate(node_network_transmit_bytes_total{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\", device!=\"lo\"}[5m])",
          "legendFormat": "{{vm_namespace}}/{{vmname}} [{{device}}]",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 41},
      "id": 105,
      "title": "System Load (Load Average)",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {"axisBorderShow": false, "axisColorMode": "text", "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0, "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none", "hideFrom": {"legend": false, "tooltip": false, "viz": false}, "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5, "scaleDistribution": {"type": "linear"}, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "none"}, "thresholdsStyle": {"mode": "off"}},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 24, "x": 0, "y": 42},
      "id": 10,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "Load Average (1m / 5m / 15m)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "node_load1{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"}",
          "legendFormat": "{{vm_namespace}}/{{vmname}} load1",
          "refId": "A"
        },
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "node_load5{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"}",
          "legendFormat": "{{vm_namespace}}/{{vmname}} load5",
          "refId": "B"
        },
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "node_load15{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\"}",
          "legendFormat": "{{vm_namespace}}/{{vmname}} load15",
          "refId": "C"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 50},
      "id": 106,
      "title": "Filesystem",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "thresholds"},
          "custom": {"align": "auto", "cellOptions": {"type": "auto"}, "filterable": true, "inspect": false},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 70}, {"color": "red", "value": 90}]}
        },
        "overrides": [
          {"matcher": {"id": "byName", "options": "Utilization (%)"}, "properties": [{"id": "custom.cellOptions", "value": {"type": "color-background"}}, {"id": "thresholds", "value": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "yellow", "value": 70}, {"color": "red", "value": 90}]}}]},
          {"matcher": {"id": "byName", "options": "Total"}, "properties": [{"id": "unit", "value": "bytes"}]},
          {"matcher": {"id": "byName", "options": "Used"}, "properties": [{"id": "unit", "value": "bytes"}]},
          {"matcher": {"id": "byName", "options": "Available"}, "properties": [{"id": "unit", "value": "bytes"}]}
        ]
      },
      "gridPos": {"h": 8, "w": 24, "x": 0, "y": 51},
      "id": 11,
      "options": {"cellHeight": "sm", "footer": {"countRows": false, "reducer": ["sum"], "show": false}, "showHeader": true},
      "title": "Filesystem Usage Status",
      "transformations": [
        {"id": "merge", "options": {}},
        {
          "id": "organize",
          "options": {
            "renameByName": {
              "vm_namespace": "Namespace",
              "vmname": "VM Name",
              "device": "Device",
              "mountpoint": "Mount Point",
              "Value #A": "Total",
              "Value #B": "Used",
              "Value #C": "Available",
              "Value #D": "Utilization (%)"
            }
          }
        }
      ],
      "type": "table",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "node_filesystem_size_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\", fstype!~\"tmpfs|devtmpfs\"}",
          "instant": true,
          "legendFormat": "",
          "refId": "A"
        },
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "node_filesystem_size_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\", fstype!~\"tmpfs|devtmpfs\"} - node_filesystem_free_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\", fstype!~\"tmpfs|devtmpfs\"}",
          "instant": true,
          "legendFormat": "",
          "refId": "B"
        },
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "node_filesystem_avail_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\", fstype!~\"tmpfs|devtmpfs\"}",
          "instant": true,
          "legendFormat": "",
          "refId": "C"
        },
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "100 * (1 - node_filesystem_avail_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\", fstype!~\"tmpfs|devtmpfs\"} / node_filesystem_size_bytes{job=\"vm-node-exporter\", vm_namespace=~\"$vm_namespace\", vmname=~\"$vmname\", fstype!~\"tmpfs|devtmpfs\"})",
          "instant": true,
          "legendFormat": "",
          "refId": "D"
        }
      ]
    }
  ]
}
NEDASHEOF

    {
        printf 'apiVersion: grafana.integreatly.org/v1beta1\n'
        printf 'kind: GrafanaDashboard\n'
        printf 'metadata:\n'
        printf '  name: poc-vm-node-exporter\n'
        printf '  namespace: %s\n' "${NS}"
        printf '  labels:\n'
        printf '    app: poc-grafana\n'
        printf 'spec:\n'
        printf '  resyncPeriod: 5m\n'
        printf '  instanceSelector:\n'
        printf '    matchLabels:\n'
        printf '      dashboards: poc-grafana\n'
        printf '  json: |\n'
        sed 's/^/    /' ./poc-vm-node-exporter-dashboard.json
    } > ./poc-vm-node-exporter-dashboard.yaml

    oc create -f ./poc-vm-node-exporter-dashboard.yaml
    print_ok "GrafanaDashboard poc-vm-node-exporter 배포됨"

    # Grafana Operator 동기화 대기 (최대 90초)
    print_info "  Grafana 대시보드 동기화 대기 중..."
    local synced=false
    for i in $(seq 1 18); do
        sleep 5
        local conditions
        conditions=$(oc get grafanadashboard poc-vm-node-exporter -n "${NS}" -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || true)
        if echo "${conditions}" | grep -q "Synchronized"; then
            synced=true
            break
        fi
        printf "    대기 중... (%d초)\n" $((i * 5))
    done

    if [ "${synced}" = "true" ]; then
        print_ok "  대시보드 동기화 완료"
    else
        print_warn "  동기화를 확인할 수 없습니다 — Grafana에서 직접 확인하세요 (resyncPeriod: 5m)"
    fi
    print_info "  대시보드: Grafana → Dashboards → VM OS Metrics (node_exporter / COO)"
}

step_datasource_for_grafana() {
    print_step "5/5  Grafana에 COO Prometheus DataSource 등록"

    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        print_warn "Grafana Operator가 설치되어 있지 않습니다 — DataSource 등록 건너뜀."
        print_info "Grafana Operator 설치 후 12-grafana/12-grafana.sh를 실행하세요."
        return
    fi

    if oc get grafanadatasource coo-prometheus-datasource -n "$NS" &>/dev/null; then
        print_ok "GrafanaDatasource coo-prometheus-datasource 이미 존재합니다 — 건너뜀"
    else
        cat > ./coo-prometheus-datasource.yaml <<EOF
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: coo-prometheus-datasource
  namespace: ${NS}
spec:
  instanceSelector:
    matchLabels:
      dashboards: poc-grafana
  datasource:
    name: COO-Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus-operated.${NS}.svc.cluster.local:9090
    isDefault: false
    jsonData:
      timeInterval: 5s
EOF
        oc apply -f ./coo-prometheus-datasource.yaml
        print_ok "GrafanaDatasource coo-prometheus-datasource 등록됨"
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! COO 모니터링 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    echo -e "  COO MonitoringStack 확인:"
    echo -e "    ${CYAN}oc get monitoringstack -n ${NS}${NC}"
    echo -e "  ServiceMonitor (COO) 확인:"
    echo -e "    ${CYAN}oc get servicemonitor.monitoring.rhobs -n ${NS}${NC}"
    echo -e "  ServiceMonitor (OpenShift Console) 확인:"
    echo -e "    ${CYAN}oc get servicemonitor.monitoring.coreos.com -n ${NS}${NC}"
    echo -e "  PrometheusRule 확인:"
    echo -e "    ${CYAN}oc get prometheusrule -n ${NS}${NC}"
    echo ""
    echo -e "  COO Prometheus 직접 접근 (port-forward):"
    echo -e "    ${CYAN}oc port-forward svc/prometheus-operated 9090:9090 -n ${NS}${NC}"
    echo -e "    브라우저: ${CYAN}http://localhost:9090${NC}"
    echo ""

    if [ "${VIRT_INSTALLED:-false}" = "true" ]; then
        echo -e "  VM 상태:"
        echo -e "    ${CYAN}oc get vmi ${VM_NAME} -n ${NS}${NC}"
        echo -e "  OpenShift Console → Observe → Metrics:"
        echo -e "    ${CYAN}node_memory_MemAvailable_bytes{job=\"poc-monitoring-vm\"}${NC}"
        echo ""
    fi

    if [ "${GRAFANA_INSTALLED:-false}" = "true" ]; then
        local grafana_route
        grafana_route=$(oc get route poc-grafana-route -n "$NS" \
            -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
        if [ -n "$grafana_route" ]; then
            echo -e "  COO node_exporter 대시보드:"
            echo -e "    ${CYAN}https://${grafana_route}/d/poc-vm-node-exporter${NC}"
        fi
        echo ""
    fi

    echo -e "  Pod 상태 확인:"
    echo -e "    ${CYAN}oc get pods -n ${NS}${NC}"
    echo ""
    echo -e "  자세한 내용: 11-coo/11-coo.md 참조"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 11-coo 리소스 삭제"
    oc delete project poc-monitoring --ignore-not-found 2>/dev/null || true
    oc delete clusterrolebinding grafana-cluster-monitoring-view --ignore-not-found 2>/dev/null || true
    print_ok "11-coo 리소스 삭제됨"
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  COO -- Cluster Observability Operator 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}  virt-poc ${POC_VERSION}${NC}"

    preflight
    step_namespace
    step_vm
    step_coo
    step_coo_dashboard
    step_datasource_for_grafana
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
