#!/bin/bash
# =============================================================================
# 12-grafana.sh
#
# OpenShift 콘솔 내장 모니터링 대시보드 (Grafana Operator 없이도 동작)
#   1/4  poc-vm-overview 대시보드 배포 (KubeVirt VM 전체 상태)
#   2/4  poc-ocpv-overview 대시보드 배포 (OpenShift Virtualization 클러스터 개요)
#   3/4  동일한 대시보드를 Grafana Operator 방식으로도 배포 (선택 사항 —
#        Grafana Operator 자체가 없으면 자동 생략 — poc-grafana Grafana
#        인스턴스가 아직 없으면 자동으로 생성합니다)
#        플러그인, Grafana Operator 필수 — 3/4 단계에서 설치)
#   4/4  동일한 대시보드를 Cluster Observability Operator (COO) + Red Hat
#        build of Perses 방식으로도 배포 (선택 사항 — COO나 UIPlugin CRD가
#        없으면 자동 생략) — operators/perses-coo.md 참조
#
# 1/4, 2/4 단계의 대시보드는 openshift-config-managed Namespace에
# console.openshift.io/dashboard: "true" 라벨을 가진 ConfigMap으로 등록됩니다.
# OpenShift 웹 콘솔이 이를 직접 인식하여 Observe > Dashboards(Administrator
# perspective)에 렌더링하며, 데이터소스는 클러스터 내장 Thanos Querier를
# 사용합니다 — 이 경로에는 Grafana 인스턴스가 필요하지 않습니다.
#
# Usage: ./12-grafana.sh
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

DASHBOARD_NS="openshift-config-managed"
COO_NS="openshift-cluster-observability-operator"
GRAFANA_DEFAULT_NS="poc-grafana"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-grafana123}"
GRAFANA_NS=""

# dashboards=poc-grafana 라벨이 붙은 Grafana 인스턴스의 namespace를 찾아
# 전역 변수 GRAFANA_NS에 저장합니다 (operators/grafana-operator.md 참조).
detect_grafana_instance() {
    GRAFANA_NS=$(oc get grafana --all-namespaces -l dashboards=poc-grafana \
        -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
}

# dashboards=poc-grafana 라벨이 붙은 Grafana 인스턴스가 있는지 확인하고,
# 없으면 GRAFANA_DEFAULT_NS에 하나 생성합니다 (operators/grafana-operator.md와
# 동일한 구성). 성공하면 GRAFANA_NS를 설정하고, 인스턴스를 만들 수 없으면
# 0이 아닌 값을 반환합니다.
ensure_grafana_instance() {
    detect_grafana_instance
    if [ -n "${GRAFANA_NS:-}" ]; then
        print_ok "Grafana 인스턴스가 namespace ${GRAFANA_NS}에서 발견되었습니다"
        return 0
    fi

    print_info "dashboards=poc-grafana 라벨을 가진 Grafana 인스턴스를 찾지 못했습니다 — namespace ${GRAFANA_DEFAULT_NS}에 새로 생성합니다."

    if oc get namespace "$GRAFANA_DEFAULT_NS" &>/dev/null; then
        print_ok "Namespace ${GRAFANA_DEFAULT_NS}가 이미 존재합니다 — 생략"
    else
        oc new-project "$GRAFANA_DEFAULT_NS" > /dev/null
        print_ok "Namespace ${GRAFANA_DEFAULT_NS} 생성됨"
    fi

    if cat <<EOF | oc apply -f - > /dev/null
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: poc-grafana
  namespace: ${GRAFANA_DEFAULT_NS}
  labels:
    dashboards: poc-grafana
spec:
  config:
    auth:
      disable_login_form: "false"
    security:
      admin_user: admin
      admin_password: ${GRAFANA_ADMIN_PASSWORD}
  route:
    spec:
      tls:
        termination: edge
EOF
    then
        print_ok "Grafana 인스턴스 poc-grafana가 namespace ${GRAFANA_DEFAULT_NS}에 생성되었습니다 (admin / ${GRAFANA_ADMIN_PASSWORD})"
    else
        print_error "Grafana 인스턴스 생성에 실패했습니다."
        print_info "  Grafana Operator의 OperatorGroup이 namespace ${GRAFANA_DEFAULT_NS}를 감시하는지 확인하세요 — operators/grafana-operator.md 참고."
        return 1
    fi

    detect_grafana_instance
    if [ -z "${GRAFANA_NS:-}" ]; then
        print_error "Grafana 인스턴스를 적용했지만 아직 조회되지 않습니다."
        print_info "  'oc get grafana -n ${GRAFANA_DEFAULT_NS}'에서 확인되면 이 스크립트를 다시 실행하세요."
        return 1
    fi
    return 0
}

preflight() {
    print_step "사전 점검"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 연결: $(oc whoami) @ $(oc whoami --show-server)"

    if ! oc auth can-i create configmap -n "$DASHBOARD_NS" &>/dev/null; then
        print_error "${DASHBOARD_NS}에 ConfigMap을 생성할 권한이 없습니다."
        print_info "커스텀 콘솔 모니터링 대시보드를 등록하려면 cluster-admin 권한이 필요합니다."
        exit 1
    fi
    print_ok "${DASHBOARD_NS}에 대시보드를 작성할 권한이 확인되었습니다"

    # env.conf에 없으면 클러스터 CSV에서 자동 감지
    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        if oc get csv --all-namespaces --no-headers 2>/dev/null \
            | grep -qi "grafana-operator"; then
            GRAFANA_INSTALLED=true
            print_ok "Grafana Community Operator 자동 감지됨 (CSV)"
        fi
    fi

    if [ "${GRAFANA_INSTALLED:-false}" = "true" ]; then
        detect_grafana_instance
        if [ -n "${GRAFANA_NS:-}" ]; then
            print_ok "Grafana 인스턴스가 namespace ${GRAFANA_NS}에서 발견되었습니다 — 3/4 단계에서 Operator 기반 대시보드를 배포합니다."
        else
            print_info "Grafana Operator는 설치되어 있지만 Grafana 인스턴스를 찾지 못했습니다 — 3/4 단계에서 새로 생성(namespace ${GRAFANA_DEFAULT_NS})한 뒤 대시보드를 배포합니다."
        fi
    else
        print_error "Grafana Operator가 설치되어 있지 않습니다 — 3/4 단계는 건너뜁니다."
        print_info "  설치 방법은 operators/grafana-operator.md를 참고하세요."
    fi

    # env.conf에 없으면 클러스터 CSV에서 Cluster Observability Operator(Red Hat 카탈로그)를 자동 감지
    if [ "${COO_INSTALLED:-false}" != "true" ]; then
        if oc get csv --all-namespaces --no-headers 2>/dev/null \
            | grep -qi "cluster-observability-operator"; then
            COO_INSTALLED=true
            print_ok "Cluster Observability Operator 자동 감지됨 (CSV)"
        fi
    fi

    if [ "${COO_INSTALLED:-false}" = "true" ] && oc get crd uiplugins.observability.openshift.io &>/dev/null; then
        print_ok "Cluster Observability Operator + UIPlugin CRD 확인됨 — 4/4 단계에서 Perses 기반 대시보드를 배포합니다."
    else
        print_warn "Cluster Observability Operator(또는 UIPlugin CRD)를 찾지 못했습니다 — 4/4 단계는 생략됩니다."
        print_info "  설치 방법은 operators/perses-coo.md를 참고하세요 (OpenShift 4.15+ / COO 1.5+ 필요)."
    fi
}

step_dashboard_vm() {
    print_step "1/4  KubeVirt VM 전체 상태 대시보드 배포 (poc-vm-overview)"

    # Dashboard JSON (작은따옴표 heredoc — \$datasource/\$namespace/\$vm 는
    # 콘솔 렌더러가 이해하는 Grafana 스타일 템플릿 변수이며 bash 변수가
    # 아니므로 이 구간에서는 확장을 막아야 합니다)
    cat > ./poc-vm-overview.json << 'DASHBOARD_EOF'
{
  "annotations": {"list": []},
  "editable": false,
  "gnetId": null,
  "graphTooltip": 1,
  "hideControls": false,
  "id": null,
  "links": [],
  "refresh": "30s",
  "rows": [
    {
      "collapse": false,
      "height": "150px",
      "showTitle": true,
      "title": "VM Status Summary",
      "panels": [
        {
          "cacheTimeout": null,
          "colorBackground": true,
          "colorValue": false,
          "colors": ["#37872D", "#37872D", "#37872D"],
          "datasource": "$datasource",
          "format": "none",
          "gauge": {"maxValue": 100, "minValue": 0, "show": false, "thresholdLabels": false, "thresholdMarkers": true},
          "id": 1,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [{"name": "value to text", "value": 1}, {"name": "range to text", "value": 2}],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [{"from": "null", "text": "N/A", "to": "null"}],
          "sparkline": {"fillColor": "rgba(31, 118, 189, 0.18)", "full": false, "lineColor": "rgb(31, 120, 193)", "show": false},
          "span": 3,
          "targets": [
            {"expr": "sum(kubevirt_vmi_phase_count{phase=~\"Running|running\"}) or vector(0)", "format": "time_series", "intervalFactor": 2, "legendFormat": "", "refId": "A"}
          ],
          "thresholds": "",
          "title": "Running — Cluster Total",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [{"op": "=", "text": "N/A", "value": "null"}],
          "valueName": "current"
        },
        {
          "cacheTimeout": null,
          "colorBackground": true,
          "colorValue": false,
          "colors": ["#E5AB00", "#E5AB00", "#E5AB00"],
          "datasource": "$datasource",
          "format": "none",
          "gauge": {"maxValue": 100, "minValue": 0, "show": false, "thresholdLabels": false, "thresholdMarkers": true},
          "id": 2,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [{"name": "value to text", "value": 1}, {"name": "range to text", "value": 2}],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [{"from": "null", "text": "N/A", "to": "null"}],
          "sparkline": {"fillColor": "rgba(31, 118, 189, 0.18)", "full": false, "lineColor": "rgb(31, 120, 193)", "show": false},
          "span": 3,
          "targets": [
            {"expr": "sum(kubevirt_vmi_phase_count{phase=~\"Paused|paused\"}) or vector(0)", "format": "time_series", "intervalFactor": 2, "legendFormat": "", "refId": "A"}
          ],
          "thresholds": "",
          "title": "Paused — Cluster Total",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [{"op": "=", "text": "N/A", "value": "null"}],
          "valueName": "current"
        },
        {
          "cacheTimeout": null,
          "colorBackground": true,
          "colorValue": false,
          "colors": ["#C9190B", "#C9190B", "#C9190B"],
          "datasource": "$datasource",
          "format": "none",
          "gauge": {"maxValue": 100, "minValue": 0, "show": false, "thresholdLabels": false, "thresholdMarkers": true},
          "id": 3,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [{"name": "value to text", "value": 1}, {"name": "range to text", "value": 2}],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [{"from": "null", "text": "N/A", "to": "null"}],
          "sparkline": {"fillColor": "rgba(31, 118, 189, 0.18)", "full": false, "lineColor": "rgb(31, 120, 193)", "show": false},
          "span": 3,
          "targets": [
            {"expr": "sum(kubevirt_vmi_phase_count{phase!~\"Running|running|Paused|paused\"}) or vector(0)", "format": "time_series", "intervalFactor": 2, "legendFormat": "", "refId": "A"}
          ],
          "thresholds": "",
          "title": "Abnormal (Pending/Failed) — Cluster Total",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [{"op": "=", "text": "N/A", "value": "null"}],
          "valueName": "current"
        },
        {
          "cacheTimeout": null,
          "colorBackground": true,
          "colorValue": false,
          "colors": ["#0066CC", "#0066CC", "#0066CC"],
          "datasource": "$datasource",
          "format": "none",
          "gauge": {"maxValue": 100, "minValue": 0, "show": false, "thresholdLabels": false, "thresholdMarkers": true},
          "id": 4,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [{"name": "value to text", "value": 1}, {"name": "range to text", "value": 2}],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [{"from": "null", "text": "N/A", "to": "null"}],
          "sparkline": {"fillColor": "rgba(31, 118, 189, 0.18)", "full": false, "lineColor": "rgb(31, 120, 193)", "show": false},
          "span": 3,
          "targets": [
            {"expr": "count(kubevirt_vmi_info) or vector(0)", "format": "time_series", "intervalFactor": 2, "legendFormat": "", "refId": "A"}
          ],
          "thresholds": "",
          "title": "Total Active VMI — Cluster Total",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [{"op": "=", "text": "N/A", "value": "null"}],
          "valueName": "current"
        }
      ]
    },
    {
      "collapse": false,
      "height": "300px",
      "showTitle": true,
      "title": "CPU",
      "panels": [
        {
          "aliasColors": {},
          "bars": false,
          "dashLength": 10,
          "dashes": false,
          "datasource": "$datasource",
          "fill": 1,
          "id": 5,
          "legend": {"alignAsTable": true, "avg": true, "current": true, "max": true, "min": false, "show": true, "total": false, "values": true},
          "lines": true,
          "linewidth": 1,
          "nullPointMode": "null",
          "percentage": false,
          "pointradius": 5,
          "points": false,
          "renderer": "flot",
          "seriesOverrides": [],
          "spaceLength": 10,
          "span": 12,
          "stack": false,
          "steppedLine": false,
          "targets": [
            {"expr": "rate(kubevirt_vmi_cpu_usage_seconds_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])", "format": "time_series", "intervalFactor": 2, "legendFormat": "{{namespace}}/{{name}}", "refId": "A"}
          ],
          "thresholds": [],
          "timeFrom": null,
          "timeShift": null,
          "title": "CPU Utilization (vCPU seconds/s)",
          "tooltip": {"shared": true, "sort": 0, "value_type": "individual"},
          "type": "graph",
          "xaxis": {"buckets": null, "mode": "time", "name": null, "show": true, "values": []},
          "yaxes": [
            {"format": "short", "label": null, "logBase": 1, "max": null, "min": null, "show": true},
            {"format": "short", "label": null, "logBase": 1, "max": null, "min": null, "show": true}
          ]
        }
      ]
    },
    {
      "collapse": false,
      "height": "300px",
      "showTitle": true,
      "title": "Memory",
      "panels": [
        {
          "aliasColors": {},
          "bars": false,
          "dashLength": 10,
          "dashes": false,
          "datasource": "$datasource",
          "fill": 1,
          "id": 6,
          "legend": {"alignAsTable": true, "avg": true, "current": true, "max": true, "min": false, "show": true, "total": false, "values": true},
          "lines": true,
          "linewidth": 1,
          "nullPointMode": "null",
          "percentage": false,
          "pointradius": 5,
          "points": false,
          "renderer": "flot",
          "seriesOverrides": [],
          "spaceLength": 10,
          "span": 6,
          "stack": false,
          "steppedLine": false,
          "targets": [
            {"expr": "kubevirt_vmi_memory_resident_bytes{namespace=~\"$namespace\", name=~\"$vm\"}", "format": "time_series", "intervalFactor": 2, "legendFormat": "{{namespace}}/{{name}}", "refId": "A"}
          ],
          "thresholds": [],
          "timeFrom": null,
          "timeShift": null,
          "title": "Memory Usage (Resident)",
          "tooltip": {"shared": true, "sort": 0, "value_type": "individual"},
          "type": "graph",
          "xaxis": {"buckets": null, "mode": "time", "name": null, "show": true, "values": []},
          "yaxes": [
            {"format": "bytes", "label": null, "logBase": 1, "max": null, "min": null, "show": true},
            {"format": "short", "label": null, "logBase": 1, "max": null, "min": null, "show": true}
          ]
        },
        {
          "aliasColors": {},
          "bars": false,
          "dashLength": 10,
          "dashes": false,
          "datasource": "$datasource",
          "fill": 1,
          "id": 7,
          "legend": {"alignAsTable": true, "avg": true, "current": true, "max": true, "min": false, "show": true, "total": false, "values": true},
          "lines": true,
          "linewidth": 1,
          "nullPointMode": "null",
          "percentage": false,
          "pointradius": 5,
          "points": false,
          "renderer": "flot",
          "seriesOverrides": [],
          "spaceLength": 10,
          "span": 6,
          "stack": false,
          "steppedLine": false,
          "targets": [
            {"expr": "kubevirt_vmi_memory_resident_bytes{namespace=~\"$namespace\", name=~\"$vm\"} / (kubevirt_vmi_memory_resident_bytes{namespace=~\"$namespace\", name=~\"$vm\"} + kubevirt_vmi_memory_available_bytes{namespace=~\"$namespace\", name=~\"$vm\"})", "format": "time_series", "intervalFactor": 2, "legendFormat": "{{namespace}}/{{name}}", "refId": "A"}
          ],
          "thresholds": [],
          "timeFrom": null,
          "timeShift": null,
          "title": "Memory Utilization (%)",
          "tooltip": {"shared": true, "sort": 0, "value_type": "individual"},
          "type": "graph",
          "xaxis": {"buckets": null, "mode": "time", "name": null, "show": true, "values": []},
          "yaxes": [
            {"format": "percentunit", "label": null, "logBase": 1, "max": "1", "min": "0", "show": true},
            {"format": "short", "label": null, "logBase": 1, "max": null, "min": null, "show": true}
          ]
        }
      ]
    },
    {
      "collapse": false,
      "height": "300px",
      "showTitle": true,
      "title": "Network I/O",
      "panels": [
        {
          "aliasColors": {},
          "bars": false,
          "dashLength": 10,
          "dashes": false,
          "datasource": "$datasource",
          "fill": 1,
          "id": 8,
          "legend": {"alignAsTable": true, "avg": true, "current": true, "max": true, "min": false, "show": true, "total": false, "values": true},
          "lines": true,
          "linewidth": 1,
          "nullPointMode": "null",
          "percentage": false,
          "pointradius": 5,
          "points": false,
          "renderer": "flot",
          "seriesOverrides": [],
          "spaceLength": 10,
          "span": 6,
          "stack": false,
          "steppedLine": false,
          "targets": [
            {"expr": "rate(kubevirt_vmi_network_receive_bytes_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])", "format": "time_series", "intervalFactor": 2, "legendFormat": "{{namespace}}/{{name}} [{{interface}}]", "refId": "A"}
          ],
          "thresholds": [],
          "timeFrom": null,
          "timeShift": null,
          "title": "Network Receive (RX)",
          "tooltip": {"shared": true, "sort": 0, "value_type": "individual"},
          "type": "graph",
          "xaxis": {"buckets": null, "mode": "time", "name": null, "show": true, "values": []},
          "yaxes": [
            {"format": "Bps", "label": null, "logBase": 1, "max": null, "min": null, "show": true},
            {"format": "short", "label": null, "logBase": 1, "max": null, "min": null, "show": true}
          ]
        },
        {
          "aliasColors": {},
          "bars": false,
          "dashLength": 10,
          "dashes": false,
          "datasource": "$datasource",
          "fill": 1,
          "id": 9,
          "legend": {"alignAsTable": true, "avg": true, "current": true, "max": true, "min": false, "show": true, "total": false, "values": true},
          "lines": true,
          "linewidth": 1,
          "nullPointMode": "null",
          "percentage": false,
          "pointradius": 5,
          "points": false,
          "renderer": "flot",
          "seriesOverrides": [],
          "spaceLength": 10,
          "span": 6,
          "stack": false,
          "steppedLine": false,
          "targets": [
            {"expr": "rate(kubevirt_vmi_network_transmit_bytes_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])", "format": "time_series", "intervalFactor": 2, "legendFormat": "{{namespace}}/{{name}} [{{interface}}]", "refId": "A"}
          ],
          "thresholds": [],
          "timeFrom": null,
          "timeShift": null,
          "title": "Network Transmit (TX)",
          "tooltip": {"shared": true, "sort": 0, "value_type": "individual"},
          "type": "graph",
          "xaxis": {"buckets": null, "mode": "time", "name": null, "show": true, "values": []},
          "yaxes": [
            {"format": "Bps", "label": null, "logBase": 1, "max": null, "min": null, "show": true},
            {"format": "short", "label": null, "logBase": 1, "max": null, "min": null, "show": true}
          ]
        }
      ]
    },
    {
      "collapse": false,
      "height": "300px",
      "showTitle": true,
      "title": "Storage I/O",
      "panels": [
        {
          "aliasColors": {},
          "bars": false,
          "dashLength": 10,
          "dashes": false,
          "datasource": "$datasource",
          "fill": 1,
          "id": 10,
          "legend": {"alignAsTable": true, "avg": true, "current": true, "max": true, "min": false, "show": true, "total": false, "values": true},
          "lines": true,
          "linewidth": 1,
          "nullPointMode": "null",
          "percentage": false,
          "pointradius": 5,
          "points": false,
          "renderer": "flot",
          "seriesOverrides": [],
          "spaceLength": 10,
          "span": 6,
          "stack": false,
          "steppedLine": false,
          "targets": [
            {"expr": "rate(kubevirt_vmi_storage_read_traffic_bytes_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])", "format": "time_series", "intervalFactor": 2, "legendFormat": "{{namespace}}/{{name}} [{{drive}}]", "refId": "A"}
          ],
          "thresholds": [],
          "timeFrom": null,
          "timeShift": null,
          "title": "Storage Read",
          "tooltip": {"shared": true, "sort": 0, "value_type": "individual"},
          "type": "graph",
          "xaxis": {"buckets": null, "mode": "time", "name": null, "show": true, "values": []},
          "yaxes": [
            {"format": "Bps", "label": null, "logBase": 1, "max": null, "min": null, "show": true},
            {"format": "short", "label": null, "logBase": 1, "max": null, "min": null, "show": true}
          ]
        },
        {
          "aliasColors": {},
          "bars": false,
          "dashLength": 10,
          "dashes": false,
          "datasource": "$datasource",
          "fill": 1,
          "id": 11,
          "legend": {"alignAsTable": true, "avg": true, "current": true, "max": true, "min": false, "show": true, "total": false, "values": true},
          "lines": true,
          "linewidth": 1,
          "nullPointMode": "null",
          "percentage": false,
          "pointradius": 5,
          "points": false,
          "renderer": "flot",
          "seriesOverrides": [],
          "spaceLength": 10,
          "span": 6,
          "stack": false,
          "steppedLine": false,
          "targets": [
            {"expr": "rate(kubevirt_vmi_storage_write_traffic_bytes_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])", "format": "time_series", "intervalFactor": 2, "legendFormat": "{{namespace}}/{{name}} [{{drive}}]", "refId": "A"}
          ],
          "thresholds": [],
          "timeFrom": null,
          "timeShift": null,
          "title": "Storage Write",
          "tooltip": {"shared": true, "sort": 0, "value_type": "individual"},
          "type": "graph",
          "xaxis": {"buckets": null, "mode": "time", "name": null, "show": true, "values": []},
          "yaxes": [
            {"format": "Bps", "label": null, "logBase": 1, "max": null, "min": null, "show": true},
            {"format": "short", "label": null, "logBase": 1, "max": null, "min": null, "show": true}
          ]
        }
      ]
    }
  ],
  "schemaVersion": 14,
  "style": "dark",
  "tags": ["kubevirt", "vm", "poc", "openshift-virtualization"],
  "templating": {
    "list": [
      {
        "current": {}, "hide": 2, "label": "datasource", "name": "datasource",
        "options": [], "query": "prometheus", "refresh": 1, "regex": "", "type": "datasource"
      },
      {
        "allValue": ".*", "current": {"text": "All", "value": "$__all"}, "datasource": "$datasource",
        "hide": 0, "includeAll": true, "label": "Namespace", "multi": true, "name": "namespace",
        "options": [], "query": "label_values(kubevirt_vmi_info, namespace)", "refresh": 2,
        "regex": "", "sort": 1, "type": "query"
      },
      {
        "allValue": ".*", "current": {"text": "All", "value": "$__all"}, "datasource": "$datasource",
        "hide": 0, "includeAll": true, "label": "VM Name", "multi": true, "name": "vm",
        "options": [], "query": "label_values(kubevirt_vmi_info, name)", "refresh": 2,
        "regex": "", "sort": 1, "type": "query"
      }
    ]
  },
  "time": {"from": "now-1h", "to": "now"},
  "timezone": "browser",
  "title": "KubeVirt VM Overall Status",
  "uid": "poc-vm-overview",
  "version": 1
}
DASHBOARD_EOF

    # ConfigMap YAML 래핑 (bash 변수 ${DASHBOARD_NS} 사용)
    {
        printf 'apiVersion: v1\n'
        printf 'kind: ConfigMap\n'
        printf 'metadata:\n'
        printf '  name: poc-vm-overview-dashboard\n'
        printf '  namespace: %s\n' "${DASHBOARD_NS}"
        printf '  labels:\n'
        printf '    console.openshift.io/dashboard: "true"\n'
        printf 'data:\n'
        printf '  poc-vm-overview.json: |\n'
        sed 's/^/    /' ./poc-vm-overview.json
    } > ./poc-vm-overview-dashboard.yaml

    oc apply -f ./poc-vm-overview-dashboard.yaml
    print_ok "ConfigMap poc-vm-overview-dashboard가 ${DASHBOARD_NS}에 적용되었습니다"
    print_info "  대시보드: 콘솔 → Observe → Dashboards → KubeVirt VM Overall Status"
}

step_dashboard_ocpv() {
    print_step "2/4  OpenShift Virtualization 클러스터 개요 대시보드 배포 (poc-ocpv-overview)"

    cat > ./poc-ocpv-overview.json << 'DASHBOARD_EOF'
{
  "annotations": {"list": []},
  "editable": false,
  "gnetId": null,
  "graphTooltip": 1,
  "hideControls": false,
  "id": null,
  "links": [],
  "refresh": "30s",
  "rows": [
    {
      "collapse": false,
      "height": "300px",
      "showTitle": true,
      "title": "VM Distribution",
      "panels": [
        {
          "aliasColors": {},
          "bars": false,
          "dashLength": 10,
          "dashes": false,
          "datasource": "$datasource",
          "fill": 1,
          "id": 1,
          "legend": {"alignAsTable": true, "avg": false, "current": true, "max": false, "min": false, "show": true, "total": false, "values": true},
          "lines": true,
          "linewidth": 1,
          "nullPointMode": "null",
          "percentage": false,
          "pointradius": 5,
          "points": false,
          "renderer": "flot",
          "seriesOverrides": [],
          "spaceLength": 10,
          "span": 12,
          "stack": true,
          "steppedLine": false,
          "targets": [
            {"expr": "count(kubevirt_vmi_info) by (node)", "format": "time_series", "intervalFactor": 2, "legendFormat": "{{node}}", "refId": "A"}
          ],
          "thresholds": [],
          "timeFrom": null,
          "timeShift": null,
          "title": "VM Count by Node",
          "tooltip": {"shared": true, "sort": 0, "value_type": "individual"},
          "type": "graph",
          "xaxis": {"buckets": null, "mode": "time", "name": null, "show": true, "values": []},
          "yaxes": [
            {"format": "short", "label": null, "logBase": 1, "max": null, "min": "0", "show": true},
            {"format": "short", "label": null, "logBase": 1, "max": null, "min": null, "show": true}
          ]
        }
      ]
    },
    {
      "collapse": false,
      "height": "300px",
      "showTitle": true,
      "title": "VM Phase Breakdown",
      "panels": [
        {
          "aliasColors": {},
          "bars": false,
          "dashLength": 10,
          "dashes": false,
          "datasource": "$datasource",
          "fill": 1,
          "id": 2,
          "legend": {"alignAsTable": true, "avg": false, "current": true, "max": false, "min": false, "show": true, "total": false, "values": true},
          "lines": true,
          "linewidth": 1,
          "nullPointMode": "null",
          "percentage": false,
          "pointradius": 5,
          "points": false,
          "renderer": "flot",
          "seriesOverrides": [],
          "spaceLength": 10,
          "span": 12,
          "stack": true,
          "steppedLine": false,
          "targets": [
            {"expr": "sum(kubevirt_vmi_phase_count) by (phase)", "format": "time_series", "intervalFactor": 2, "legendFormat": "{{phase}}", "refId": "A"}
          ],
          "thresholds": [],
          "timeFrom": null,
          "timeShift": null,
          "title": "VMI Count by Phase (Cluster Total)",
          "tooltip": {"shared": true, "sort": 0, "value_type": "individual"},
          "type": "graph",
          "xaxis": {"buckets": null, "mode": "time", "name": null, "show": true, "values": []},
          "yaxes": [
            {"format": "short", "label": null, "logBase": 1, "max": null, "min": "0", "show": true},
            {"format": "short", "label": null, "logBase": 1, "max": null, "min": null, "show": true}
          ]
        }
      ]
    },
    {
      "collapse": false,
      "height": "150px",
      "showTitle": true,
      "title": "Live Migration Status",
      "panels": [
        {
          "cacheTimeout": null,
          "colorBackground": true,
          "colorValue": false,
          "colors": ["#0066CC", "#0066CC", "#0066CC"],
          "datasource": "$datasource",
          "format": "none",
          "gauge": {"maxValue": 100, "minValue": 0, "show": false, "thresholdLabels": false, "thresholdMarkers": true},
          "id": 3,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [{"name": "value to text", "value": 1}, {"name": "range to text", "value": 2}],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [{"from": "null", "text": "N/A", "to": "null"}],
          "sparkline": {"fillColor": "rgba(31, 118, 189, 0.18)", "full": false, "lineColor": "rgb(31, 120, 193)", "show": false},
          "span": 3,
          "targets": [
            {"expr": "sum(kubevirt_vmi_migrations_in_pending_phase) or vector(0)", "format": "time_series", "intervalFactor": 2, "legendFormat": "", "refId": "A"}
          ],
          "thresholds": "",
          "title": "Pending",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [{"op": "=", "text": "N/A", "value": "null"}],
          "valueName": "current"
        },
        {
          "cacheTimeout": null,
          "colorBackground": true,
          "colorValue": false,
          "colors": ["#E5AB00", "#E5AB00", "#E5AB00"],
          "datasource": "$datasource",
          "format": "none",
          "gauge": {"maxValue": 100, "minValue": 0, "show": false, "thresholdLabels": false, "thresholdMarkers": true},
          "id": 4,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [{"name": "value to text", "value": 1}, {"name": "range to text", "value": 2}],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [{"from": "null", "text": "N/A", "to": "null"}],
          "sparkline": {"fillColor": "rgba(31, 118, 189, 0.18)", "full": false, "lineColor": "rgb(31, 120, 193)", "show": false},
          "span": 3,
          "targets": [
            {"expr": "sum(kubevirt_vmi_migrations_in_scheduling_phase) or vector(0)", "format": "time_series", "intervalFactor": 2, "legendFormat": "", "refId": "A"}
          ],
          "thresholds": "",
          "title": "Scheduling",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [{"op": "=", "text": "N/A", "value": "null"}],
          "valueName": "current"
        },
        {
          "cacheTimeout": null,
          "colorBackground": true,
          "colorValue": false,
          "colors": ["#37872D", "#37872D", "#37872D"],
          "datasource": "$datasource",
          "format": "none",
          "gauge": {"maxValue": 100, "minValue": 0, "show": false, "thresholdLabels": false, "thresholdMarkers": true},
          "id": 5,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [{"name": "value to text", "value": 1}, {"name": "range to text", "value": 2}],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [{"from": "null", "text": "N/A", "to": "null"}],
          "sparkline": {"fillColor": "rgba(31, 118, 189, 0.18)", "full": false, "lineColor": "rgb(31, 120, 193)", "show": false},
          "span": 3,
          "targets": [
            {"expr": "sum(kubevirt_vmi_migrations_in_running_phase) or vector(0)", "format": "time_series", "intervalFactor": 2, "legendFormat": "", "refId": "A"}
          ],
          "thresholds": "",
          "title": "Running",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [{"op": "=", "text": "N/A", "value": "null"}],
          "valueName": "current"
        },
        {
          "cacheTimeout": null,
          "colorBackground": true,
          "colorValue": false,
          "colors": ["#C9190B", "#C9190B", "#C9190B"],
          "datasource": "$datasource",
          "format": "none",
          "gauge": {"maxValue": 100, "minValue": 0, "show": false, "thresholdLabels": false, "thresholdMarkers": true},
          "id": 6,
          "interval": null,
          "links": [],
          "mappingType": 1,
          "mappingTypes": [{"name": "value to text", "value": 1}, {"name": "range to text", "value": 2}],
          "maxDataPoints": 100,
          "nullPointMode": "connected",
          "nullText": null,
          "postfix": "",
          "postfixFontSize": "50%",
          "prefix": "",
          "prefixFontSize": "50%",
          "rangeMaps": [{"from": "null", "text": "N/A", "to": "null"}],
          "sparkline": {"fillColor": "rgba(31, 118, 189, 0.18)", "full": false, "lineColor": "rgb(31, 120, 193)", "show": false},
          "span": 3,
          "targets": [
            {"expr": "sum(kubevirt_vmi_migrations_failed) or vector(0)", "format": "time_series", "intervalFactor": 2, "legendFormat": "", "refId": "A"}
          ],
          "thresholds": "",
          "title": "Failed (Total)",
          "type": "singlestat",
          "valueFontSize": "80%",
          "valueMaps": [{"op": "=", "text": "N/A", "value": "null"}],
          "valueName": "current"
        }
      ]
    }
  ],
  "schemaVersion": 14,
  "style": "dark",
  "tags": ["kubevirt", "poc", "openshift-virtualization"],
  "templating": {
    "list": [
      {
        "current": {}, "hide": 2, "label": "datasource", "name": "datasource",
        "options": [], "query": "prometheus", "refresh": 1, "regex": "", "type": "datasource"
      }
    ]
  },
  "time": {"from": "now-1h", "to": "now"},
  "timezone": "browser",
  "title": "OpenShift Virtualization Cluster Overview",
  "uid": "poc-ocpv-overview",
  "version": 1
}
DASHBOARD_EOF

    {
        printf 'apiVersion: v1\n'
        printf 'kind: ConfigMap\n'
        printf 'metadata:\n'
        printf '  name: poc-ocpv-overview-dashboard\n'
        printf '  namespace: %s\n' "${DASHBOARD_NS}"
        printf '  labels:\n'
        printf '    console.openshift.io/dashboard: "true"\n'
        printf 'data:\n'
        printf '  poc-ocpv-overview.json: |\n'
        sed 's/^/    /' ./poc-ocpv-overview.json
    } > ./poc-ocpv-overview-dashboard.yaml

    oc apply -f ./poc-ocpv-overview-dashboard.yaml
    print_ok "ConfigMap poc-ocpv-overview-dashboard가 ${DASHBOARD_NS}에 적용되었습니다"
    print_info "  대시보드: 콘솔 → Observe → Dashboards → OpenShift Virtualization Cluster Overview"
}

step_operator_dashboards() {
    print_step "3/4  동일한 대시보드를 Grafana Operator 방식으로 배포 (선택 사항)"

    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        print_error "Grafana Operator가 설치되어 있지 않습니다 — 건너뜁니다."
        print_info "  설치 방법은 operators/grafana-operator.md를 참고하세요."
        return
    fi

    ensure_grafana_instance || return
    ensure_polystat_plugin || return

    # Grafana가 클러스터 내장 Thanos Querier에 인증할 수 있도록 ServiceAccount와
    # ClusterRoleBinding을 구성합니다 (cluster-monitoring-view는 읽기 전용입니다).
    if oc get serviceaccount poc-grafana-view -n "$GRAFANA_NS" &>/dev/null; then
        print_ok "ServiceAccount poc-grafana-view가 이미 존재합니다 — 생략"
    else
        oc create serviceaccount poc-grafana-view -n "$GRAFANA_NS" > /dev/null
        print_ok "ServiceAccount poc-grafana-view 생성됨"
    fi

    if oc get clusterrolebinding grafana-cluster-monitoring-view &>/dev/null; then
        print_ok "ClusterRoleBinding grafana-cluster-monitoring-view가 이미 존재합니다 — 생략"
    else
        oc create clusterrolebinding grafana-cluster-monitoring-view \
            --clusterrole=cluster-monitoring-view \
            --serviceaccount="${GRAFANA_NS}:poc-grafana-view" > /dev/null
        print_ok "ClusterRoleBinding grafana-cluster-monitoring-view 생성됨"
    fi

    # Thanos Querier 데이터소스용 장기 Bearer 토큰. 클러스터의
    # service-account-max-token-expiration 설정에 따라 만료 기간이 짧아질 수
    # 있으며, 만료되면 이 스크립트를 다시 실행해 재발급하면 됩니다.
    local token
    token=$(oc create token poc-grafana-view -n "$GRAFANA_NS" --duration=8760h 2>/dev/null || true)
    if [ -z "$token" ]; then
        print_error "ServiceAccount 토큰 발급에 실패했습니다 — datasource/dashboard 등록을 생략합니다."
        return
    fi

    # Bearer 토큰이 포함되므로 파일로 저장하지 않고 oc apply로 바로 전달합니다.
    cat <<EOF | oc apply -f - > /dev/null
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: thanos-querier-datasource
  namespace: ${GRAFANA_NS}
spec:
  instanceSelector:
    matchLabels:
      dashboards: poc-grafana
  datasource:
    name: Thanos-Querier
    type: prometheus
    access: proxy
    url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
    jsonData:
      timeInterval: 30s
      tlsSkipVerify: true
      httpHeaderName1: Authorization
    secureJsonData:
      httpHeaderValue1: "Bearer ${token}"
EOF
    print_ok "GrafanaDatasource thanos-querier-datasource 등록됨"

    cat > ./poc-vm-overview-operator.json << 'DASHBOARD_EOF'
{
  "annotations": {
    "list": [
      {
        "builtIn": 1,
        "datasource": {
          "type": "grafana",
          "uid": "-- Grafana --"
        },
        "enable": true,
        "hide": true,
        "iconColor": "rgba(0,211,255,1)",
        "name": "Annotations & Alerts",
        "type": "dashboard"
      }
    ]
  },
  "description": "KubeVirt VM Overall Status — Grafana Operator 기반 (Thanos Querier)",
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "refresh": "30s",
  "schemaVersion": 39,
  "tags": [
    "kubevirt",
    "vm",
    "poc",
    "openshift-virtualization",
    "grafana-operator"
  ],
  "templating": {
    "list": [
      {
        "current": {
          "selected": false,
          "text": "Thanos-Querier",
          "value": "Thanos-Querier"
        },
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
        "current": {
          "selected": true,
          "text": "All",
          "value": "$__all"
        },
        "datasource": {
          "type": "prometheus",
          "uid": "${datasource}"
        },
        "definition": "label_values(kubevirt_vmi_info, namespace)",
        "hide": 0,
        "includeAll": true,
        "label": "Namespace",
        "multi": true,
        "name": "namespace",
        "options": [],
        "query": {
          "query": "label_values(kubevirt_vmi_info, namespace)",
          "refId": "Q"
        },
        "refresh": 2,
        "regex": "",
        "sort": 1,
        "type": "query"
      },
      {
        "allValue": ".*",
        "current": {
          "selected": true,
          "text": "All",
          "value": "$__all"
        },
        "datasource": {
          "type": "prometheus",
          "uid": "${datasource}"
        },
        "definition": "label_values(kubevirt_vmi_info, name)",
        "hide": 0,
        "includeAll": true,
        "label": "VM Name",
        "multi": true,
        "name": "vm",
        "options": [],
        "query": {
          "query": "label_values(kubevirt_vmi_info, name)",
          "refId": "Q"
        },
        "refresh": 2,
        "regex": "",
        "sort": 1,
        "type": "query"
      },
      {
        "allValue": ".*",
        "current": {
          "selected": true,
          "text": [
            "All"
          ],
          "value": [
            "$__all"
          ]
        },
        "datasource": {
          "type": "prometheus",
          "uid": "${datasource}"
        },
        "definition": "label_values(kubevirt_vmi_info, node)",
        "hide": 0,
        "includeAll": true,
        "label": "Node",
        "multi": true,
        "name": "node",
        "options": [],
        "query": {
          "query": "label_values(kubevirt_vmi_info, node)",
          "refId": "StandardVariableQuery"
        },
        "refresh": 2,
        "regex": "",
        "sort": 1,
        "type": "query"
      }
    ]
  },
  "time": {
    "from": "now-1h",
    "to": "now"
  },
  "timepicker": {},
  "timezone": "browser",
  "title": "KubeVirt VM Overall Status (Operator)",
  "uid": "poc-vm-overview-operator",
  "version": 1,
  "panels": [
    {
      "collapsed": false,
      "gridPos": {
        "h": 1,
        "w": 24,
        "x": 0,
        "y": 0
      },
      "id": 100,
      "title": "VM Status Summary",
      "type": "row"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "${datasource}"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "fixedColor": "green",
            "mode": "fixed"
          },
          "mappings": [],
          "unit": "none"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 3,
        "w": 5,
        "x": 0,
        "y": 1
      },
      "id": 1,
      "options": {
        "colorMode": "background",
        "graphMode": "none",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "textMode": "auto"
      },
      "title": "Running",
      "type": "stat",
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${datasource}"
          },
          "expr": "sum(kubevirt_vmi_phase_count{phase=~\"Running|running\"}) or vector(0)",
          "legendFormat": "",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "${datasource}"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "fixedColor": "yellow",
            "mode": "fixed"
          },
          "mappings": [],
          "unit": "none"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 3,
        "w": 5,
        "x": 5,
        "y": 1
      },
      "id": 2,
      "options": {
        "colorMode": "background",
        "graphMode": "none",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "textMode": "auto"
      },
      "title": "Paused",
      "type": "stat",
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${datasource}"
          },
          "expr": "sum(kubevirt_vmi_phase_count{phase=~\"Paused|paused\"}) or vector(0)",
          "legendFormat": "",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "${datasource}"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "fixedColor": "orange",
            "mode": "fixed"
          },
          "mappings": [],
          "unit": "none"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 3,
        "w": 4,
        "x": 10,
        "y": 1
      },
      "id": 20,
      "options": {
        "colorMode": "background",
        "graphMode": "none",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "textMode": "auto"
      },
      "title": "Stopped",
      "type": "stat",
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${datasource}"
          },
          "expr": "count(kubevirt_vm_info unless on(name, namespace) kubevirt_vmi_info) or vector(0)",
          "legendFormat": "",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "${datasource}"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "fixedColor": "red",
            "mode": "fixed"
          },
          "mappings": [],
          "unit": "none"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 3,
        "w": 5,
        "x": 14,
        "y": 1
      },
      "id": 3,
      "options": {
        "colorMode": "background",
        "graphMode": "none",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "textMode": "auto"
      },
      "title": "Abnormal",
      "type": "stat",
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${datasource}"
          },
          "expr": "sum(kubevirt_vmi_phase_count{phase!~\"Running|running|Paused|paused\"}) or vector(0)",
          "legendFormat": "",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "${datasource}"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "fixedColor": "blue",
            "mode": "fixed"
          },
          "mappings": [],
          "unit": "none"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 3,
        "w": 5,
        "x": 19,
        "y": 1
      },
      "id": 4,
      "options": {
        "colorMode": "background",
        "graphMode": "none",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {
          "calcs": [
            "lastNotNull"
          ],
          "fields": "",
          "values": false
        },
        "textMode": "auto"
      },
      "title": "Total VMs",
      "type": "stat",
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${datasource}"
          },
          "expr": "count(kubevirt_vm_info) or vector(0)",
          "legendFormat": "",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {
        "h": 1,
        "w": 24,
        "x": 0,
        "y": 4
      },
      "id": 105,
      "repeat": "node",
      "repeatDirection": "h",
      "title": "Node: $node — Running VMs",
      "type": "row"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "${datasource}"
      },
      "fieldConfig": {
        "defaults": {},
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 24,
        "x": 0,
        "y": 5
      },
      "id": 30,
      "options": {
        "autoSizeColumns": true,
        "autoSizeRows": true,
        "autoSizePolygons": true,
        "ellipseCharacters": 18,
        "ellipseEnabled": true,
        "globalAutoScaleFonts": true,
        "globalDecimals": 0,
        "globalDisplayMode": "all",
        "globalDisplayTextTriggeredEmpty": "",
        "globalFontSize": 12,
        "globalGradientsEnabled": false,
        "globalOperatorName": "last",
        "globalPolygonBorderColor": "#1a1a1a",
        "globalPolygonBorderSize": 2,
        "globalPolygonSize": 50,
        "globalRegexPattern": "",
        "globalShape": "hexagon_pointed_top",
        "globalShowTimestampEnabled": false,
        "globalShowTooltipColumnHeadersEnabled": true,
        "globalShowValueEnabled": false,
        "globalTextFontAutoColor": "#FFFFFF",
        "globalTextFontAutoColorEnabled": true,
        "globalTextFontColor": "#FFFFFF",
        "globalTextFontFamily": "Roboto",
        "globalTooltipDisplayMode": "all",
        "globalTooltipDisplayTextTriggeredEmpty": "",
        "globalTooltipFontFamily": "Roboto",
        "globalTooltipFontSize": 12,
        "layoutDisplayLimit": 100,
        "layoutNumColumns": 0,
        "layoutNumRows": 0,
        "sortByDirection": 1,
        "sortByField": "name",
        "globalFillColor": "#37872D"
      },
      "title": "Running VMs ($node)",
      "type": "grafana-polystat-panel",
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${datasource}"
          },
          "expr": "count by (name, namespace) (kubevirt_vmi_info{node=~\"$node\"}) * 0 + 1",
          "legendFormat": "{{name}}",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {
        "h": 1,
        "w": 24,
        "x": 0,
        "y": 13
      },
      "id": 106,
      "title": "Stopped VMs",
      "type": "row"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "${datasource}"
      },
      "fieldConfig": {
        "defaults": {},
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 24,
        "x": 0,
        "y": 14
      },
      "id": 31,
      "options": {
        "autoSizeColumns": true,
        "autoSizeRows": true,
        "autoSizePolygons": true,
        "ellipseCharacters": 18,
        "ellipseEnabled": true,
        "globalAutoScaleFonts": true,
        "globalDecimals": 0,
        "globalDisplayMode": "all",
        "globalDisplayTextTriggeredEmpty": "",
        "globalFontSize": 12,
        "globalGradientsEnabled": false,
        "globalOperatorName": "last",
        "globalPolygonBorderColor": "#1a1a1a",
        "globalPolygonBorderSize": 2,
        "globalPolygonSize": 50,
        "globalRegexPattern": "",
        "globalShape": "hexagon_pointed_top",
        "globalShowTimestampEnabled": false,
        "globalShowTooltipColumnHeadersEnabled": true,
        "globalShowValueEnabled": false,
        "globalTextFontAutoColor": "#FFFFFF",
        "globalTextFontAutoColorEnabled": true,
        "globalTextFontColor": "#FFFFFF",
        "globalTextFontFamily": "Roboto",
        "globalTooltipDisplayMode": "all",
        "globalTooltipDisplayTextTriggeredEmpty": "",
        "globalTooltipFontFamily": "Roboto",
        "globalTooltipFontSize": 12,
        "layoutDisplayLimit": 100,
        "layoutNumColumns": 0,
        "layoutNumRows": 0,
        "sortByDirection": 1,
        "sortByField": "name",
        "globalFillColor": "#6C757D"
      },
      "title": "Stopped VMs",
      "type": "grafana-polystat-panel",
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${datasource}"
          },
          "expr": "count by (name, namespace) (kubevirt_vm_info unless on(name, namespace) kubevirt_vmi_info) * 0",
          "legendFormat": "{{name}}",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {
        "h": 1,
        "w": 24,
        "x": 0,
        "y": 22
      },
      "id": 101,
      "title": "CPU",
      "type": "row"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "${datasource}"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "drawStyle": "line",
            "fillOpacity": 10,
            "lineWidth": 1,
            "pointSize": 5,
            "showPoints": "never",
            "spanNulls": false
          },
          "mappings": [],
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 24,
        "x": 0,
        "y": 23
      },
      "id": 5,
      "options": {
        "legend": {
          "calcs": [
            "mean",
            "max",
            "last"
          ],
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "title": "CPU Utilization (vCPU seconds/s)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${datasource}"
          },
          "expr": "rate(kubevirt_vmi_cpu_usage_seconds_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])",
          "legendFormat": "{{namespace}}/{{name}}",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {
        "h": 1,
        "w": 24,
        "x": 0,
        "y": 31
      },
      "id": 102,
      "title": "Memory",
      "type": "row"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "${datasource}"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "drawStyle": "line",
            "fillOpacity": 10,
            "lineWidth": 1,
            "pointSize": 5,
            "showPoints": "never",
            "spanNulls": false
          },
          "mappings": [],
          "unit": "bytes"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 32
      },
      "id": 6,
      "options": {
        "legend": {
          "calcs": [
            "mean",
            "max",
            "last"
          ],
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "title": "Memory Usage (Resident)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${datasource}"
          },
          "expr": "kubevirt_vmi_memory_resident_bytes{namespace=~\"$namespace\", name=~\"$vm\"}",
          "legendFormat": "{{namespace}}/{{name}}",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "${datasource}"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "drawStyle": "line",
            "fillOpacity": 10,
            "lineWidth": 1,
            "pointSize": 5,
            "showPoints": "never",
            "spanNulls": false
          },
          "mappings": [],
          "unit": "percentunit",
          "min": 0,
          "max": 1
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 32
      },
      "id": 7,
      "options": {
        "legend": {
          "calcs": [
            "mean",
            "max",
            "last"
          ],
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "title": "Memory Utilization (%)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${datasource}"
          },
          "expr": "kubevirt_vmi_memory_resident_bytes{namespace=~\"$namespace\", name=~\"$vm\"} / (kubevirt_vmi_memory_resident_bytes{namespace=~\"$namespace\", name=~\"$vm\"} + kubevirt_vmi_memory_available_bytes{namespace=~\"$namespace\", name=~\"$vm\"})",
          "legendFormat": "{{namespace}}/{{name}}",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {
        "h": 1,
        "w": 24,
        "x": 0,
        "y": 40
      },
      "id": 103,
      "title": "Network I/O",
      "type": "row"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "${datasource}"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "drawStyle": "line",
            "fillOpacity": 10,
            "lineWidth": 1,
            "pointSize": 5,
            "showPoints": "never",
            "spanNulls": false
          },
          "mappings": [],
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 41
      },
      "id": 8,
      "options": {
        "legend": {
          "calcs": [
            "mean",
            "max",
            "last"
          ],
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "title": "Network Receive (RX)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${datasource}"
          },
          "expr": "rate(kubevirt_vmi_network_receive_bytes_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])",
          "legendFormat": "{{namespace}}/{{name}} [{{interface}}]",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "${datasource}"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "drawStyle": "line",
            "fillOpacity": 10,
            "lineWidth": 1,
            "pointSize": 5,
            "showPoints": "never",
            "spanNulls": false
          },
          "mappings": [],
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 41
      },
      "id": 9,
      "options": {
        "legend": {
          "calcs": [
            "mean",
            "max",
            "last"
          ],
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "title": "Network Transmit (TX)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${datasource}"
          },
          "expr": "rate(kubevirt_vmi_network_transmit_bytes_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])",
          "legendFormat": "{{namespace}}/{{name}} [{{interface}}]",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {
        "h": 1,
        "w": 24,
        "x": 0,
        "y": 49
      },
      "id": 104,
      "title": "Storage I/O",
      "type": "row"
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "${datasource}"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "drawStyle": "line",
            "fillOpacity": 10,
            "lineWidth": 1,
            "pointSize": 5,
            "showPoints": "never",
            "spanNulls": false
          },
          "mappings": [],
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 0,
        "y": 50
      },
      "id": 10,
      "options": {
        "legend": {
          "calcs": [
            "mean",
            "max",
            "last"
          ],
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "title": "Storage Read",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${datasource}"
          },
          "expr": "rate(kubevirt_vmi_storage_read_traffic_bytes_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])",
          "legendFormat": "{{namespace}}/{{name}} [{{drive}}]",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {
        "type": "prometheus",
        "uid": "${datasource}"
      },
      "fieldConfig": {
        "defaults": {
          "color": {
            "mode": "palette-classic"
          },
          "custom": {
            "drawStyle": "line",
            "fillOpacity": 10,
            "lineWidth": 1,
            "pointSize": 5,
            "showPoints": "never",
            "spanNulls": false
          },
          "mappings": [],
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {
        "h": 8,
        "w": 12,
        "x": 12,
        "y": 50
      },
      "id": 11,
      "options": {
        "legend": {
          "calcs": [
            "mean",
            "max",
            "last"
          ],
          "displayMode": "table",
          "placement": "bottom",
          "showLegend": true
        },
        "tooltip": {
          "mode": "multi",
          "sort": "desc"
        }
      },
      "title": "Storage Write",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {
            "type": "prometheus",
            "uid": "${datasource}"
          },
          "expr": "rate(kubevirt_vmi_storage_write_traffic_bytes_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])",
          "legendFormat": "{{namespace}}/{{name}} [{{drive}}]",
          "refId": "A"
        }
      ]
    }
  ]
}

DASHBOARD_EOF

    {
        printf 'apiVersion: grafana.integreatly.org/v1beta1\n'
        printf 'kind: GrafanaDashboard\n'
        printf 'metadata:\n'
        printf '  name: poc-vm-overview-operator\n'
        printf '  namespace: %s\n' "${GRAFANA_NS}"
        printf 'spec:\n'
        printf '  resyncPeriod: 5m\n'
        printf '  instanceSelector:\n'
        printf '    matchLabels:\n'
        printf '      dashboards: poc-grafana\n'
        printf '  json: |\n'
        sed 's/^/    /' ./poc-vm-overview-operator.json
    } > ./poc-vm-overview-operator-dashboard.yaml

    oc apply -f ./poc-vm-overview-operator-dashboard.yaml
    print_ok "GrafanaDashboard poc-vm-overview-operator 배포됨"

    cat > ./poc-ocpv-overview-operator.json << 'DASHBOARD_EOF'
{
  "annotations": {"list": [{"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": true, "hide": true, "iconColor": "rgba(0,211,255,1)", "name": "Annotations & Alerts", "type": "dashboard"}]},
  "description": "OpenShift Virtualization Cluster Overview — Grafana Operator 기반 (Thanos Querier)",
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "refresh": "30s",
  "schemaVersion": 39,
  "tags": ["kubevirt", "poc", "openshift-virtualization", "grafana-operator"],
  "templating": {
    "list": [
      {"current": {"selected": false, "text": "Thanos-Querier", "value": "Thanos-Querier"}, "hide": 0, "includeAll": false, "label": "Datasource", "multi": false, "name": "datasource", "options": [], "query": "prometheus", "refresh": 1, "type": "datasource"}
    ]
  },
  "time": {"from": "now-1h", "to": "now"},
  "timepicker": {},
  "timezone": "browser",
  "title": "OpenShift Virtualization Cluster Overview (Operator)",
  "uid": "poc-ocpv-overview-operator",
  "version": 1,
  "panels": [
    {"collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0}, "id": 100, "title": "VM Distribution", "type": "row"},
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"mode": "palette-classic"}, "custom": {"drawStyle": "line", "fillOpacity": 10, "lineWidth": 1, "pointSize": 5, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "normal"}}, "mappings": [], "unit": "short"}, "overrides": []},
      "gridPos": {"h": 8, "w": 24, "x": 0, "y": 1},
      "id": 1,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "VM Count by Node",
      "type": "timeseries",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "count(kubevirt_vmi_info) by (node)", "legendFormat": "{{node}}", "refId": "A"}]
    },
    {"collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 9}, "id": 101, "title": "VM Phase Breakdown", "type": "row"},
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"mode": "palette-classic"}, "custom": {"drawStyle": "line", "fillOpacity": 10, "lineWidth": 1, "pointSize": 5, "showPoints": "never", "spanNulls": false, "stacking": {"group": "A", "mode": "normal"}}, "mappings": [], "unit": "short"}, "overrides": []},
      "gridPos": {"h": 8, "w": 24, "x": 0, "y": 10},
      "id": 2,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "VMI Count by Phase (Cluster Total)",
      "type": "timeseries",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "sum(kubevirt_vmi_phase_count) by (phase)", "legendFormat": "{{phase}}", "refId": "A"}]
    },
    {"collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 18}, "id": 102, "title": "Live Migration Status", "type": "row"},
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"fixedColor": "blue", "mode": "fixed"}, "mappings": [], "unit": "none"}, "overrides": []},
      "gridPos": {"h": 4, "w": 6, "x": 0, "y": 19},
      "id": 3,
      "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "center", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
      "title": "Pending",
      "type": "stat",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "sum(kubevirt_vmi_migrations_in_pending_phase) or vector(0)", "legendFormat": "", "refId": "A"}]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"fixedColor": "yellow", "mode": "fixed"}, "mappings": [], "unit": "none"}, "overrides": []},
      "gridPos": {"h": 4, "w": 6, "x": 6, "y": 19},
      "id": 4,
      "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "center", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
      "title": "Scheduling",
      "type": "stat",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "sum(kubevirt_vmi_migrations_in_scheduling_phase) or vector(0)", "legendFormat": "", "refId": "A"}]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"fixedColor": "green", "mode": "fixed"}, "mappings": [], "unit": "none"}, "overrides": []},
      "gridPos": {"h": 4, "w": 6, "x": 12, "y": 19},
      "id": 5,
      "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "center", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
      "title": "Running",
      "type": "stat",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "sum(kubevirt_vmi_migrations_in_running_phase) or vector(0)", "legendFormat": "", "refId": "A"}]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"fixedColor": "red", "mode": "fixed"}, "mappings": [], "unit": "none"}, "overrides": []},
      "gridPos": {"h": 4, "w": 6, "x": 18, "y": 19},
      "id": 6,
      "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "center", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
      "title": "Failed (Total)",
      "type": "stat",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "sum(kubevirt_vmi_migrations_failed) or vector(0)", "legendFormat": "", "refId": "A"}]
    }
  ]
}
DASHBOARD_EOF

    {
        printf 'apiVersion: grafana.integreatly.org/v1beta1\n'
        printf 'kind: GrafanaDashboard\n'
        printf 'metadata:\n'
        printf '  name: poc-ocpv-overview-operator\n'
        printf '  namespace: %s\n' "${GRAFANA_NS}"
        printf 'spec:\n'
        printf '  resyncPeriod: 5m\n'
        printf '  instanceSelector:\n'
        printf '    matchLabels:\n'
        printf '      dashboards: poc-grafana\n'
        printf '  json: |\n'
        sed 's/^/    /' ./poc-ocpv-overview-operator.json
    } > ./poc-ocpv-overview-operator-dashboard.yaml

    oc apply -f ./poc-ocpv-overview-operator-dashboard.yaml
    print_ok "GrafanaDashboard poc-ocpv-overview-operator 배포됨"

    local grafana_route
    grafana_route=$(oc get route poc-grafana-route -n "$GRAFANA_NS" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "$grafana_route" ]; then
        print_info "  대시보드: https://${grafana_route}/d/poc-vm-overview-operator"
        print_info "  대시보드: https://${grafana_route}/d/poc-ocpv-overview-operator"
    fi
}

# Grafana 인스턴스에 grafana-polystat-panel 플러그인을 설치합니다.
# Grafana CR의 GF_INSTALL_PLUGINS 환경변수를 통해 구성하며,
# Grafana Operator가 Pod를 재시작하여 플러그인을 자동 설치합니다.
ensure_polystat_plugin() {
    local grafana_name
    grafana_name=$(oc get grafana -n "$GRAFANA_NS" -l dashboards=poc-grafana \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [ -z "$grafana_name" ]; then
        print_warn "Grafana 인스턴스를 찾지 못했습니다 — Polystat 플러그인을 설치할 수 없습니다."
        return 1
    fi

    local current_plugins
    current_plugins=$(oc get grafana "$grafana_name" -n "$GRAFANA_NS" \
        -o jsonpath='{.spec.deployment.spec.template.spec.containers[?(@.name=="grafana")].env[?(@.name=="GF_INSTALL_PLUGINS")].value}' 2>/dev/null || true)

    if echo "$current_plugins" | grep -q "grafana-polystat-panel"; then
        print_ok "grafana-polystat-panel 플러그인이 이미 설치되어 있습니다"
        return 0
    fi

    local new_plugins="grafana-polystat-panel"
    [ -n "$current_plugins" ] && new_plugins="${current_plugins},grafana-polystat-panel"

    if oc patch grafana "$grafana_name" -n "$GRAFANA_NS" --type=merge \
        -p "{\"spec\":{\"deployment\":{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"grafana\",\"env\":[{\"name\":\"GF_INSTALL_PLUGINS\",\"value\":\"${new_plugins}\"}]}]}}}}}}" > /dev/null; then
        print_ok "grafana-polystat-panel 플러그인 설치 구성 완료"
    else
        print_warn "Grafana CR 패치에 실패했습니다 — Grafana 인스턴스에 grafana-polystat-panel 플러그인을 수동으로 추가하세요"
        return 1
    fi

    print_info "  Grafana Pod가 플러그인 설치 후 재시작됩니다 — 잠시 대기..."
    local deploy_name
    deploy_name=$(oc get deployment -n "$GRAFANA_NS" -l app="${grafana_name}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "${grafana_name}-deployment")
    oc rollout status "deployment/${deploy_name}" -n "$GRAFANA_NS" --timeout=180s 2>/dev/null || true
    return 0
}

step_perses_dashboards() {
    print_step "4/4  동일한 대시보드를 COO + Red Hat build of Perses 방식으로 배포 (선택 사항)"

    if [ "${COO_INSTALLED:-false}" != "true" ] || ! oc get crd uiplugins.observability.openshift.io &>/dev/null; then
        print_warn "Cluster Observability Operator(또는 UIPlugin CRD)를 찾지 못했습니다 — 생략합니다."
        print_info "  설치 방법은 operators/perses-coo.md를 참고하세요."
        return
    fi

    # Perses 대시보드 UI 활성화 (Observe > Dashboards (Perses))
    cat <<EOF | oc apply -f - > /dev/null || { print_warn "UIPlugin monitoring 적용에 실패했습니다 — COO 버전을 확인하세요 (1.5+ 필요)"; return; }
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: monitoring
spec:
  type: Monitoring
  monitoring:
    perses:
      enabled: true
EOF
    print_ok "UIPlugin monitoring (Perses) 활성화됨"

    if ! oc get namespace "$COO_NS" &>/dev/null; then
        print_warn "Namespace ${COO_NS}를 아직 찾을 수 없습니다 — Perses가 아직 기동 중일 수 있습니다. 대시보드/데이터소스 등록을 생략합니다."
        print_info "  'oc get pods -n ${COO_NS} | grep perses'에서 Running 상태가 되면 이 스크립트를 다시 실행하세요."
        return
    fi

    # 클러스터 내장 Thanos Querier를 클러스터 전체 범위 데이터소스로 등록합니다.
    # TLS만 구성됩니다(service-ca) — 쿼리가 "Unauthorized"를 반환하면 Thanos
    # Querier에 cluster-monitoring-view가 부여된 Bearer 토큰 identity가
    # 필요합니다 — operators/perses-coo.md의 문제 해결 항목을 참고하세요.
    if oc get persesglobaldatasource thanos-querier-global-datasource &>/dev/null; then
        print_ok "PersesGlobalDatasource thanos-querier-global-datasource가 이미 존재합니다 — 생략"
    else
        cat <<EOF | oc apply -f - > /dev/null && DS_APPLIED=true || DS_APPLIED=false
apiVersion: perses.dev/v1alpha2
kind: PersesGlobalDatasource
metadata:
  name: thanos-querier-global-datasource
spec:
  config:
    display:
      name: "Thanos Querier"
    default: true
    plugin:
      kind: "PrometheusDatasource"
      spec:
        proxy:
          kind: HTTPProxy
          spec:
            url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
  client:
    tls:
      enable: true
      caCert:
        type: file
        certPath: /ca/service-ca.crt
EOF
        if [ "$DS_APPLIED" = "true" ]; then
            print_ok "PersesGlobalDatasource thanos-querier-global-datasource 등록됨"
        else
            print_warn "PersesGlobalDatasource 생성에 실패했습니다 — operators/perses-coo.md를 참고하세요"
        fi
    fi

    cat > ./poc-vm-overview-perses.yaml <<EOF
apiVersion: perses.dev/v1alpha2
kind: PersesDashboard
metadata:
  name: poc-vm-overview-perses
  namespace: ${COO_NS}
spec:
  config:
    display:
      name: "KubeVirt VM Overall Status (Perses)"
    duration: 1h
    variables:
      - kind: ListVariable
        spec:
          name: namespace
          allowMultiple: true
          allowAllValue: true
          plugin:
            kind: PrometheusLabelValuesVariable
            spec:
              labelName: namespace
              matchers:
                - kubevirt_vmi_info
      - kind: ListVariable
        spec:
          name: vm
          allowMultiple: true
          allowAllValue: true
          plugin:
            kind: PrometheusLabelValuesVariable
            spec:
              labelName: name
              matchers:
                - kubevirt_vmi_info
    panels:
      runningStat:
        kind: Panel
        spec:
          display:
            name: "Running — Cluster Total"
          plugin:
            kind: StatChart
            spec: {}
          queries:
            - kind: TimeSeriesQuery
              spec:
                plugin:
                  kind: PrometheusTimeSeriesQuery
                  spec:
                    query: sum(kubevirt_vmi_phase_count{phase=~"Running|running"}) or vector(0)
      pausedStat:
        kind: Panel
        spec:
          display:
            name: "Paused — Cluster Total"
          plugin:
            kind: StatChart
            spec: {}
          queries:
            - kind: TimeSeriesQuery
              spec:
                plugin:
                  kind: PrometheusTimeSeriesQuery
                  spec:
                    query: sum(kubevirt_vmi_phase_count{phase=~"Paused|paused"}) or vector(0)
      abnormalStat:
        kind: Panel
        spec:
          display:
            name: "Abnormal (Pending/Failed) — Cluster Total"
          plugin:
            kind: StatChart
            spec: {}
          queries:
            - kind: TimeSeriesQuery
              spec:
                plugin:
                  kind: PrometheusTimeSeriesQuery
                  spec:
                    query: sum(kubevirt_vmi_phase_count{phase!~"Running|running|Paused|paused"}) or vector(0)
      totalStat:
        kind: Panel
        spec:
          display:
            name: "Total Active VMI — Cluster Total"
          plugin:
            kind: StatChart
            spec: {}
          queries:
            - kind: TimeSeriesQuery
              spec:
                plugin:
                  kind: PrometheusTimeSeriesQuery
                  spec:
                    query: count(kubevirt_vmi_info) or vector(0)
      cpuChart:
        kind: Panel
        spec:
          display:
            name: "CPU Utilization (vCPU seconds/s)"
          plugin:
            kind: TimeSeriesChart
            spec: {}
          queries:
            - kind: TimeSeriesQuery
              spec:
                plugin:
                  kind: PrometheusTimeSeriesQuery
                  spec:
                    query: rate(kubevirt_vmi_cpu_usage_seconds_total{namespace=~"\$namespace", name=~"\$vm"}[5m])
      memUsageChart:
        kind: Panel
        spec:
          display:
            name: "Memory Usage (Resident)"
          plugin:
            kind: TimeSeriesChart
            spec: {}
          queries:
            - kind: TimeSeriesQuery
              spec:
                plugin:
                  kind: PrometheusTimeSeriesQuery
                  spec:
                    query: kubevirt_vmi_memory_resident_bytes{namespace=~"\$namespace", name=~"\$vm"}
      memUtilChart:
        kind: Panel
        spec:
          display:
            name: "Memory Utilization (%)"
          plugin:
            kind: TimeSeriesChart
            spec: {}
          queries:
            - kind: TimeSeriesQuery
              spec:
                plugin:
                  kind: PrometheusTimeSeriesQuery
                  spec:
                    query: kubevirt_vmi_memory_resident_bytes{namespace=~"\$namespace", name=~"\$vm"} / (kubevirt_vmi_memory_resident_bytes{namespace=~"\$namespace", name=~"\$vm"} + kubevirt_vmi_memory_available_bytes{namespace=~"\$namespace", name=~"\$vm"})
      netRxChart:
        kind: Panel
        spec:
          display:
            name: "Network Receive (RX)"
          plugin:
            kind: TimeSeriesChart
            spec: {}
          queries:
            - kind: TimeSeriesQuery
              spec:
                plugin:
                  kind: PrometheusTimeSeriesQuery
                  spec:
                    query: rate(kubevirt_vmi_network_receive_bytes_total{namespace=~"\$namespace", name=~"\$vm"}[5m])
      netTxChart:
        kind: Panel
        spec:
          display:
            name: "Network Transmit (TX)"
          plugin:
            kind: TimeSeriesChart
            spec: {}
          queries:
            - kind: TimeSeriesQuery
              spec:
                plugin:
                  kind: PrometheusTimeSeriesQuery
                  spec:
                    query: rate(kubevirt_vmi_network_transmit_bytes_total{namespace=~"\$namespace", name=~"\$vm"}[5m])
      diskReadChart:
        kind: Panel
        spec:
          display:
            name: "Storage Read"
          plugin:
            kind: TimeSeriesChart
            spec: {}
          queries:
            - kind: TimeSeriesQuery
              spec:
                plugin:
                  kind: PrometheusTimeSeriesQuery
                  spec:
                    query: rate(kubevirt_vmi_storage_read_traffic_bytes_total{namespace=~"\$namespace", name=~"\$vm"}[5m])
      diskWriteChart:
        kind: Panel
        spec:
          display:
            name: "Storage Write"
          plugin:
            kind: TimeSeriesChart
            spec: {}
          queries:
            - kind: TimeSeriesQuery
              spec:
                plugin:
                  kind: PrometheusTimeSeriesQuery
                  spec:
                    query: rate(kubevirt_vmi_storage_write_traffic_bytes_total{namespace=~"\$namespace", name=~"\$vm"}[5m])
    layouts:
      - kind: Grid
        spec:
          display:
            title: "VM Status Summary"
          items:
            - {x: 0, y: 0, width: 6, height: 4, content: {\$ref: "#/spec/config/panels/runningStat"}}
            - {x: 6, y: 0, width: 6, height: 4, content: {\$ref: "#/spec/config/panels/pausedStat"}}
            - {x: 12, y: 0, width: 6, height: 4, content: {\$ref: "#/spec/config/panels/abnormalStat"}}
            - {x: 18, y: 0, width: 6, height: 4, content: {\$ref: "#/spec/config/panels/totalStat"}}
      - kind: Grid
        spec:
          display:
            title: "CPU"
          items:
            - {x: 0, y: 0, width: 24, height: 8, content: {\$ref: "#/spec/config/panels/cpuChart"}}
      - kind: Grid
        spec:
          display:
            title: "Memory"
          items:
            - {x: 0, y: 0, width: 12, height: 8, content: {\$ref: "#/spec/config/panels/memUsageChart"}}
            - {x: 12, y: 0, width: 12, height: 8, content: {\$ref: "#/spec/config/panels/memUtilChart"}}
      - kind: Grid
        spec:
          display:
            title: "Network I/O"
          items:
            - {x: 0, y: 0, width: 12, height: 8, content: {\$ref: "#/spec/config/panels/netRxChart"}}
            - {x: 12, y: 0, width: 12, height: 8, content: {\$ref: "#/spec/config/panels/netTxChart"}}
      - kind: Grid
        spec:
          display:
            title: "Storage I/O"
          items:
            - {x: 0, y: 0, width: 12, height: 8, content: {\$ref: "#/spec/config/panels/diskReadChart"}}
            - {x: 12, y: 0, width: 12, height: 8, content: {\$ref: "#/spec/config/panels/diskWriteChart"}}
EOF

    oc apply -f ./poc-vm-overview-perses.yaml > /dev/null \
        && print_ok "PersesDashboard poc-vm-overview-perses 배포됨" \
        || print_warn "poc-vm-overview-perses.yaml 적용에 실패했습니다 — 설치된 COO 버전에서 'oc explain persesdashboard.spec.config'로 스키마를 확인하세요"

    cat > ./poc-ocpv-overview-perses.yaml <<EOF
apiVersion: perses.dev/v1alpha2
kind: PersesDashboard
metadata:
  name: poc-ocpv-overview-perses
  namespace: ${COO_NS}
spec:
  config:
    display:
      name: "OpenShift Virtualization Cluster Overview (Perses)"
    duration: 1h
    panels:
      vmByNode:
        kind: Panel
        spec:
          display:
            name: "VM Count by Node"
          plugin:
            kind: TimeSeriesChart
            spec: {}
          queries:
            - kind: TimeSeriesQuery
              spec:
                plugin:
                  kind: PrometheusTimeSeriesQuery
                  spec:
                    query: count(kubevirt_vmi_info) by (node)
      phaseBreakdown:
        kind: Panel
        spec:
          display:
            name: "VMI Count by Phase (Cluster Total)"
          plugin:
            kind: TimeSeriesChart
            spec: {}
          queries:
            - kind: TimeSeriesQuery
              spec:
                plugin:
                  kind: PrometheusTimeSeriesQuery
                  spec:
                    query: sum(kubevirt_vmi_phase_count) by (phase)
      migPendingStat:
        kind: Panel
        spec:
          display:
            name: "Pending"
          plugin:
            kind: StatChart
            spec: {}
          queries:
            - kind: TimeSeriesQuery
              spec:
                plugin:
                  kind: PrometheusTimeSeriesQuery
                  spec:
                    query: sum(kubevirt_vmi_migrations_in_pending_phase) or vector(0)
      migSchedulingStat:
        kind: Panel
        spec:
          display:
            name: "Scheduling"
          plugin:
            kind: StatChart
            spec: {}
          queries:
            - kind: TimeSeriesQuery
              spec:
                plugin:
                  kind: PrometheusTimeSeriesQuery
                  spec:
                    query: sum(kubevirt_vmi_migrations_in_scheduling_phase) or vector(0)
      migRunningStat:
        kind: Panel
        spec:
          display:
            name: "Running"
          plugin:
            kind: StatChart
            spec: {}
          queries:
            - kind: TimeSeriesQuery
              spec:
                plugin:
                  kind: PrometheusTimeSeriesQuery
                  spec:
                    query: sum(kubevirt_vmi_migrations_in_running_phase) or vector(0)
      migFailedStat:
        kind: Panel
        spec:
          display:
            name: "Failed (Total)"
          plugin:
            kind: StatChart
            spec: {}
          queries:
            - kind: TimeSeriesQuery
              spec:
                plugin:
                  kind: PrometheusTimeSeriesQuery
                  spec:
                    query: sum(kubevirt_vmi_migrations_failed) or vector(0)
    layouts:
      - kind: Grid
        spec:
          display:
            title: "VM Distribution"
          items:
            - {x: 0, y: 0, width: 24, height: 8, content: {\$ref: "#/spec/config/panels/vmByNode"}}
      - kind: Grid
        spec:
          display:
            title: "VM Phase Breakdown"
          items:
            - {x: 0, y: 0, width: 24, height: 8, content: {\$ref: "#/spec/config/panels/phaseBreakdown"}}
      - kind: Grid
        spec:
          display:
            title: "Live Migration Status"
          items:
            - {x: 0, y: 0, width: 6, height: 4, content: {\$ref: "#/spec/config/panels/migPendingStat"}}
            - {x: 6, y: 0, width: 6, height: 4, content: {\$ref: "#/spec/config/panels/migSchedulingStat"}}
            - {x: 12, y: 0, width: 6, height: 4, content: {\$ref: "#/spec/config/panels/migRunningStat"}}
            - {x: 18, y: 0, width: 6, height: 4, content: {\$ref: "#/spec/config/panels/migFailedStat"}}
EOF

    oc apply -f ./poc-ocpv-overview-perses.yaml > /dev/null \
        && print_ok "PersesDashboard poc-ocpv-overview-perses 배포됨" \
        || print_warn "poc-ocpv-overview-perses.yaml 적용에 실패했습니다 — 설치된 COO 버전에서 'oc explain persesdashboard.spec.config'로 스키마를 확인하세요"

    # Grafana 사용자 DB 대신 Kubernetes 네이티브 RBAC로 조회 권한을 부여합니다
    cat <<EOF | oc apply -f - > /dev/null \
        && print_ok "RoleBinding poc-perses-dashboard-viewer가 ${COO_NS}에 적용되었습니다" \
        || print_warn "RoleBinding poc-perses-dashboard-viewer 적용에 실패했습니다 — persesdashboard-viewer-role을 수동으로 부여하세요"
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: poc-perses-dashboard-viewer
  namespace: ${COO_NS}
subjects:
  - kind: Group
    name: system:authenticated
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: persesdashboard-viewer-role
  apiGroup: rbac.authorization.k8s.io
EOF
    print_info "  대시보드: 콘솔 → Observe → Dashboards (Perses) → KubeVirt VM Overall Status (Perses)"
    print_info "  대시보드: 콘솔 → Observe → Dashboards (Perses) → OpenShift Virtualization Cluster Overview (Perses)"
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! 커스텀 대시보드가 OpenShift 콘솔에 등록되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  이동 경로   : ${CYAN}Administrator perspective → Observe → Dashboards${NC}"
    echo -e "  대시보드    :"
    echo -e "    - KubeVirt VM Overall Status"
    echo -e "    - OpenShift Virtualization Cluster Overview"
    echo ""
    echo -e "  Grafana Operator, Grafana 인스턴스, Route 모두 필요하지 않습니다 —"
    echo -e "  콘솔이 클러스터 내장 Thanos Querier를 데이터소스로 사용하여"
    echo -e "  이 대시보드를 직접 렌더링합니다."
    echo ""
    echo -e "  ConfigMap 확인:"
    echo -e "    ${CYAN}oc get configmap -n ${DASHBOARD_NS} -l console.openshift.io/dashboard=true${NC}"
    echo ""

    if [ -n "${GRAFANA_NS:-}" ]; then
        local grafana_route
        grafana_route=$(oc get route -n "$GRAFANA_NS" -l app=poc-grafana \
            -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
        if [ -z "$grafana_route" ]; then
            grafana_route=$(oc get route poc-grafana-route -n "$GRAFANA_NS" \
                -o jsonpath='{.spec.host}' 2>/dev/null || true)
        fi

        echo -e "  Grafana Operator 대시보드도 namespace ${GRAFANA_NS}에 배포되었습니다:"
        echo -e "    ${CYAN}oc get grafanadashboard,grafanadatasource -n ${GRAFANA_NS}${NC}"
        if [ -n "$grafana_route" ]; then
            echo ""
            echo -e "  Grafana URL:"
            echo -e "    ${BLUE}https://${grafana_route}${NC}"
            echo -e "    - ${CYAN}https://${grafana_route}/d/poc-vm-overview-operator${NC}"
            echo -e "    - ${CYAN}https://${grafana_route}/d/poc-ocpv-overview-operator${NC}"
            echo -e "    계정: admin / ${GRAFANA_ADMIN_PASSWORD}"
        fi
        echo ""
    fi

    if oc get uiplugin monitoring &>/dev/null; then
        echo -e "  Perses 대시보드도 namespace ${COO_NS}에 배포되었습니다:"
        echo -e "    ${CYAN}oc get persesdashboard,persesglobaldatasource -n ${COO_NS}${NC}"
        echo -e "  Perses UI: ${CYAN}Observe → Dashboards (Perses)${NC} — 자세한 내용은 operators/perses-coo.md 참조."
        echo ""
    fi

    echo -e "  자세한 내용: 12-grafana/12-grafana.md 참조"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 12-grafana 리소스 삭제"
    oc delete configmap poc-vm-overview-dashboard -n "$DASHBOARD_NS" --ignore-not-found 2>/dev/null || true
    oc delete configmap poc-ocpv-overview-dashboard -n "$DASHBOARD_NS" --ignore-not-found 2>/dev/null || true

    detect_grafana_instance
    if [ -n "${GRAFANA_NS:-}" ]; then
        oc delete grafanadashboard poc-vm-overview-operator poc-ocpv-overview-operator -n "$GRAFANA_NS" --ignore-not-found 2>/dev/null || true
        oc delete grafanadatasource thanos-querier-datasource -n "$GRAFANA_NS" --ignore-not-found 2>/dev/null || true
        oc delete serviceaccount poc-grafana-view -n "$GRAFANA_NS" --ignore-not-found 2>/dev/null || true
    fi
    oc delete clusterrolebinding grafana-cluster-monitoring-view --ignore-not-found 2>/dev/null || true

    oc delete persesdashboard poc-vm-overview-perses poc-ocpv-overview-perses -n "$COO_NS" --ignore-not-found 2>/dev/null || true
    oc delete persesglobaldatasource thanos-querier-global-datasource --ignore-not-found 2>/dev/null || true
    oc delete rolebinding poc-perses-dashboard-viewer -n "$COO_NS" --ignore-not-found 2>/dev/null || true
    oc delete uiplugin monitoring --ignore-not-found 2>/dev/null || true

    print_ok "12-grafana 리소스 삭제됨"
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Grafana — OpenShift 콘솔 내장 모니터링 대시보드${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_dashboard_vm
    step_dashboard_ocpv
    step_operator_dashboards
    step_perses_dashboards
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
