#!/bin/bash
# =============================================================================
# 12-grafana.sh
#
# OpenShift Console built-in Monitoring Dashboards (no Grafana Operator required)
#   1/4  Deploy poc-vm-overview dashboard (KubeVirt VM Overall Status)
#   2/4  Deploy poc-ocpv-overview dashboard (OpenShift Virtualization Cluster Overview)
#   3/4  Deploy the same dashboards via Grafana Operator (optional, auto-skipped
#        if the Grafana Operator itself is not installed — a poc-grafana
#        Grafana instance is created automatically if one doesn't exist yet)
#        plugin, requires Grafana Operator — installed in step 3/4)
#   4/4  Deploy the same dashboards via Cluster Observability Operator (COO) +
#        Red Hat build of Perses (optional, auto-skipped if COO / the UIPlugin
#        CRD is not found) — see operators/perses-coo.md
#
# Dashboards 1/4 and 2/4 are registered as ConfigMaps in openshift-config-managed
# with the label console.openshift.io/dashboard: "true". The OpenShift web
# console renders them directly under Observe > Dashboards (Administrator
# perspective) using the in-cluster Thanos Querier — no Grafana instance
# is required for this path.
#
# Usage: ./12-grafana.sh
# =============================================================================

set -euo pipefail
trap 'echo -e "\n\033[0;31m[ERROR]\033[0m Command failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

if [ -f "${SCRIPT_DIR}/../utils/common.sh" ]; then
    source "${SCRIPT_DIR}/../utils/common.sh"
else
    # ── standalone mode: inline common helpers ──
    RED='\033[0;31m'; GREEN='\033[0;32m'; DIM='\033[2m'
    POC_VERSION=$(cat "${SCRIPT_DIR}/../../VERSION" 2>/dev/null || echo "dev")
    YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
    print_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
    print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
    print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
    print_error() { echo -e "${RED}[ERR ]${NC} $1"; }
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
            echo -n -e "${YELLOW}  $prompt${NC} [default: ****]: "; read -s input_val; echo
        else
            echo -n -e "${YELLOW}  $prompt${NC} [default: ${default}]: "; read input_val
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
            print_info "YAML to apply:"; cat "$file"
            read -r -p "Apply this YAML to the cluster? [y/N]: " confirm
            [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { print_warn "Cancelled."; return 1; }
        fi
        oc apply -f "$file"
    }
    detect_worker_nodes() {
        WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        TEST_NODE=$(echo "$WORKER_NODES" | awk '{print $1}')
        [ -z "$WORKER_NODES" ] && { print_error "No worker nodes found."; exit 1; }
        print_info "Worker nodes: ${WORKER_NODES}"
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
        else print_warn "Garage Service (app=garage) not detected — skipping Garage config."; fi
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
            print_info "ODF MCG credentials : from noobaa-admin secret"
        else print_warn "ODF MCG credentials not detected (no noobaa-admin secret)"; fi
    }
fi

DASHBOARD_NS="openshift-config-managed"
COO_NS="openshift-cluster-observability-operator"
GRAFANA_DEFAULT_NS="poc-grafana"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-grafana123}"
GRAFANA_NS=""

# Looks up the namespace of the Grafana instance labeled dashboards=poc-grafana
# (see operators/grafana-operator.md) and stores it in the global GRAFANA_NS.
detect_grafana_instance() {
    GRAFANA_NS=$(oc get grafana --all-namespaces -l dashboards=poc-grafana \
        -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
}

# Ensures a Grafana instance labeled dashboards=poc-grafana exists, creating one
# in GRAFANA_DEFAULT_NS (matching operators/grafana-operator.md) if not found.
# Sets GRAFANA_NS on success; returns non-zero if no instance could be created.
ensure_grafana_instance() {
    detect_grafana_instance
    if [ -n "${GRAFANA_NS:-}" ]; then
        print_ok "Grafana instance detected in namespace ${GRAFANA_NS}"
        return 0
    fi

    print_info "No Grafana instance labeled dashboards=poc-grafana found — creating one in namespace ${GRAFANA_DEFAULT_NS}."

    if oc get namespace "$GRAFANA_DEFAULT_NS" &>/dev/null; then
        print_ok "Namespace ${GRAFANA_DEFAULT_NS} already exists — skipping"
    else
        oc new-project "$GRAFANA_DEFAULT_NS" > /dev/null
        print_ok "Namespace ${GRAFANA_DEFAULT_NS} created"
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
  deployment:
    spec:
      template:
        spec:
          volumes:
          - name: grafana-plugins
            emptyDir: {}
          containers:
          - name: grafana
            volumeMounts:
            - name: grafana-plugins
              mountPath: /var/lib/grafana/plugins
  route:
    spec:
      tls:
        termination: edge
EOF
    then
        print_ok "Grafana instance poc-grafana created in namespace ${GRAFANA_DEFAULT_NS} (admin / ${GRAFANA_ADMIN_PASSWORD})"
    else
        print_error "Failed to create the Grafana instance."
        print_info "  Check that the Grafana Operator's OperatorGroup watches namespace ${GRAFANA_DEFAULT_NS} — see operators/grafana-operator.md."
        return 1
    fi

    detect_grafana_instance
    if [ -z "${GRAFANA_NS:-}" ]; then
        print_error "Grafana instance was applied but is not showing up yet."
        print_info "  Rerun this script once 'oc get grafana -n ${GRAFANA_DEFAULT_NS}' shows it."
        return 1
    fi
    return 0
}

preflight() {
    print_step "Pre-flight checks"

    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift."
        exit 1
    fi
    print_ok "Cluster connection: $(oc whoami) @ $(oc whoami --show-server)"

    if ! oc auth can-i create configmap -n "$DASHBOARD_NS" &>/dev/null; then
        print_error "No permission to create ConfigMaps in ${DASHBOARD_NS}."
        print_info "Registering custom console monitoring dashboards requires cluster-admin."
        exit 1
    fi
    print_ok "Permission to write dashboards to ${DASHBOARD_NS} confirmed"

    # Auto-detect from cluster CSV if not in env.conf
    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        if oc get csv --all-namespaces --no-headers 2>/dev/null \
            | grep -qi "grafana-operator"; then
            GRAFANA_INSTALLED=true
            print_ok "Grafana Community Operator auto-detected (CSV)"
        fi
    fi

    if [ "${GRAFANA_INSTALLED:-false}" = "true" ]; then
        detect_grafana_instance
        if [ -n "${GRAFANA_NS:-}" ]; then
            print_ok "Grafana instance found in namespace ${GRAFANA_NS} — step 3/4 will deploy operator-based dashboards."
        else
            print_info "Grafana Operator installed but no Grafana instance found — step 3/4 will create one (namespace ${GRAFANA_DEFAULT_NS}) and deploy dashboards into it."
        fi
    else
        print_error "Grafana Operator not installed — step 3/4 will be skipped."
        print_info "  See operators/grafana-operator.md for installation."
    fi

    # Auto-detect Cluster Observability Operator (Red Hat catalog) from cluster CSV if not in env.conf
    if [ "${COO_INSTALLED:-false}" != "true" ]; then
        if oc get csv --all-namespaces --no-headers 2>/dev/null \
            | grep -qi "cluster-observability-operator"; then
            COO_INSTALLED=true
            print_ok "Cluster Observability Operator auto-detected (CSV)"
        fi
    fi

    if [ "${COO_INSTALLED:-false}" = "true" ] && oc get crd uiplugins.observability.openshift.io &>/dev/null; then
        print_ok "Cluster Observability Operator + UIPlugin CRD confirmed — step 4/4 will deploy Perses-based dashboards."
    else
        print_warn "Cluster Observability Operator (or its UIPlugin CRD) not found — step 4/4 will be skipped."
        print_info "  See operators/perses-coo.md for installation (requires OpenShift 4.15+ / COO 1.5+)."
    fi
}

step_dashboard_vm() {
    print_step "1/4  Deploy KubeVirt VM Overall Status dashboard (poc-vm-overview)"

    # Dashboard JSON (single-quoted heredoc — \$datasource/\$namespace/\$vm are
    # Grafana-style template variables understood by the console renderer,
    # not bash variables, so expansion must stay disabled here)
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

    # Wrap into a ConfigMap YAML (uses bash variable ${DASHBOARD_NS})
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
    print_ok "ConfigMap poc-vm-overview-dashboard applied in ${DASHBOARD_NS}"
    print_info "  Dashboard: Console → Observe → Dashboards → KubeVirt VM Overall Status"
}

step_dashboard_ocpv() {
    print_step "2/4  Deploy OpenShift Virtualization Cluster Overview dashboard (poc-ocpv-overview)"

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
    print_ok "ConfigMap poc-ocpv-overview-dashboard applied in ${DASHBOARD_NS}"
    print_info "  Dashboard: Console → Observe → Dashboards → OpenShift Virtualization Cluster Overview"
}

step_operator_dashboards() {
    print_step "3/4  Deploy the same dashboards via Grafana Operator (optional)"

    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        print_error "Grafana Operator not installed — skipping."
        print_info "  See operators/grafana-operator.md for installation."
        return
    fi

    ensure_grafana_instance || return
    ensure_polystat_plugin || return

    # ServiceAccount + ClusterRoleBinding so Grafana can authenticate to the
    # in-cluster Thanos Querier (cluster-monitoring-view is read-only).
    if oc get serviceaccount poc-grafana-view -n "$GRAFANA_NS" &>/dev/null; then
        print_ok "ServiceAccount poc-grafana-view already exists — skipping"
    else
        oc create serviceaccount poc-grafana-view -n "$GRAFANA_NS" > /dev/null
        print_ok "ServiceAccount poc-grafana-view created"
    fi

    if oc get clusterrolebinding grafana-cluster-monitoring-view &>/dev/null; then
        print_ok "ClusterRoleBinding grafana-cluster-monitoring-view already exists — skipping"
    else
        oc create clusterrolebinding grafana-cluster-monitoring-view \
            --clusterrole=cluster-monitoring-view \
            --serviceaccount="${GRAFANA_NS}:poc-grafana-view" > /dev/null
        print_ok "ClusterRoleBinding grafana-cluster-monitoring-view created"
    fi

    # Long-lived Bearer token for the Thanos Querier datasource. Subject to the
    # cluster's service-account-max-token-expiration — rerun this script to
    # regenerate if the cluster enforces a shorter limit or after expiry.
    local token
    token=$(oc create token poc-grafana-view -n "$GRAFANA_NS" --duration=8760h 2>/dev/null || true)
    if [ -z "$token" ]; then
        print_error "Failed to generate ServiceAccount token — skipping datasource/dashboard registration."
        return
    fi

    # Piped directly into oc apply (never written to disk) since it carries the Bearer token.
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
    print_ok "GrafanaDatasource thanos-querier-datasource registered"

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
  "description": "KubeVirt VM Overall Status — Grafana Operator based (Thanos Querier)",
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
    print_ok "GrafanaDashboard poc-vm-overview-operator deployed"

    cat > ./poc-ocpv-overview-operator.json << 'DASHBOARD_EOF'
{
  "annotations": {"list": [{"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": true, "hide": true, "iconColor": "rgba(0,211,255,1)", "name": "Annotations & Alerts", "type": "dashboard"}]},
  "description": "OpenShift Virtualization Cluster Overview — Grafana Operator based (Thanos Querier)",
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
    print_ok "GrafanaDashboard poc-ocpv-overview-operator deployed"

    cat > ./poc-vm-statusmap-operator.json << 'DASHBOARD_EOF'
{
  "annotations": {"list": [{"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": true, "hide": true, "iconColor": "rgba(0,211,255,1)", "name": "Annotations & Alerts", "type": "dashboard"}]},
  "description": "KubeVirt VM Status Map — Node-level VM hexagon layout (Grafana Operator + Polystat)",
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "refresh": "30s",
  "schemaVersion": 39,
  "tags": ["kubevirt", "vm", "poc", "openshift-virtualization", "grafana-operator", "statusmap"],
  "templating": {
    "list": [
      {"current": {"selected": false, "text": "Thanos-Querier", "value": "Thanos-Querier"}, "hide": 0, "includeAll": false, "label": "Datasource", "multi": false, "name": "datasource", "options": [], "query": "prometheus", "refresh": 1, "type": "datasource"},
      {"allValue": ".*", "current": {"selected": true, "text": "All", "value": "$__all"}, "datasource": {"type": "prometheus", "uid": "${datasource}"}, "definition": "label_values(kubevirt_vmi_info, node)", "hide": 0, "includeAll": true, "label": "Node", "multi": true, "name": "node", "options": [], "query": {"query": "label_values(kubevirt_vmi_info, node)", "refId": "Q"}, "refresh": 2, "regex": "", "sort": 1, "type": "query"}
    ]
  },
  "time": {"from": "now-5m", "to": "now"},
  "timepicker": {},
  "timezone": "browser",
  "title": "KubeVirt VM Status Map (Operator)",
  "uid": "poc-vm-statusmap-operator",
  "version": 1,
  "panels": [
    {"collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0}, "id": 100, "title": "VM Status Summary", "type": "row"},
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"fixedColor": "green", "mode": "fixed"}, "mappings": [], "unit": "none"}, "overrides": []},
      "gridPos": {"h": 3, "w": 6, "x": 0, "y": 1},
      "id": 1,
      "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "center", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
      "title": "Running",
      "type": "stat",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "sum(kubevirt_vmi_phase_count{phase=~\"Running|running\"}) or vector(0)", "legendFormat": "", "refId": "A"}]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"fixedColor": "yellow", "mode": "fixed"}, "mappings": [], "unit": "none"}, "overrides": []},
      "gridPos": {"h": 3, "w": 6, "x": 6, "y": 1},
      "id": 2,
      "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "center", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
      "title": "Paused",
      "type": "stat",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "sum(kubevirt_vmi_phase_count{phase=~\"Paused|paused\"}) or vector(0)", "legendFormat": "", "refId": "A"}]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"fixedColor": "red", "mode": "fixed"}, "mappings": [], "unit": "none"}, "overrides": []},
      "gridPos": {"h": 3, "w": 6, "x": 12, "y": 1},
      "id": 3,
      "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "center", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
      "title": "Abnormal",
      "type": "stat",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "sum(kubevirt_vmi_phase_count{phase!~\"Running|running|Paused|paused\"}) or vector(0)", "legendFormat": "", "refId": "A"}]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"fixedColor": "blue", "mode": "fixed"}, "mappings": [], "unit": "none"}, "overrides": []},
      "gridPos": {"h": 3, "w": 6, "x": 18, "y": 1},
      "id": 4,
      "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "center", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
      "title": "Total VMI",
      "type": "stat",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "count(kubevirt_vmi_info) or vector(0)", "legendFormat": "", "refId": "A"}]
    },
    {"collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 4}, "id": 101, "title": "VM Status Map by Node", "type": "row"},
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "#C9190B", "value": null},
              {"color": "#37872D", "value": 1}
            ]
          }
        },
        "overrides": []
      },
      "gridPos": {"h": 12, "w": 12, "x": 0, "y": 5},
      "id": 10,
      "maxPerRow": 2,
      "options": {
        "autoSizeColumns": true, "autoSizeRows": true, "autoSizePolygons": true,
        "ellipseCharacters": 18, "ellipseEnabled": true,
        "globalAutoScaleFonts": true, "globalDecimals": 0, "globalDisplayMode": "all",
        "globalDisplayTextTriggeredEmpty": "", "globalFillColor": "#37872D",
        "globalFontSize": 12, "globalGradientsEnabled": false, "globalOperatorName": "last",
        "globalPolygonBorderColor": "#1a1a1a", "globalPolygonBorderSize": 2, "globalPolygonSize": 50,
        "globalRegexPattern": "", "globalShape": "hexagon_pointed_top",
        "globalShowTimestampEnabled": false, "globalShowTooltipColumnHeadersEnabled": true,
        "globalShowValueEnabled": false, "globalTextFontAutoColor": "#FFFFFF",
        "globalTextFontAutoColorEnabled": true, "globalTextFontColor": "#FFFFFF",
        "globalTextFontFamily": "Roboto", "globalTooltipDisplayMode": "all",
        "globalTooltipDisplayTextTriggeredEmpty": "", "globalTooltipFontFamily": "Roboto",
        "globalTooltipFontSize": 12, "layoutDisplayLimit": 100,
        "layoutNumColumns": 0, "layoutNumRows": 0,
        "sortByDirection": 1, "sortByField": "name"
      },
      "repeat": "node",
      "repeatDirection": "h",
      "title": "$node",
      "type": "grafana-polystat-panel",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "count by (name, namespace) (kubevirt_vmi_info{node=~\"$node\"})",
          "legendFormat": "{{name}}",
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
        printf '  name: poc-vm-statusmap-operator\n'
        printf '  namespace: %s\n' "${GRAFANA_NS}"
        printf 'spec:\n'
        printf '  resyncPeriod: 5m\n'
        printf '  instanceSelector:\n'
        printf '    matchLabels:\n'
        printf '      dashboards: poc-grafana\n'
        printf '  json: |\n'
        sed 's/^/    /' ./poc-vm-statusmap-operator.json
    } > ./poc-vm-statusmap-operator-dashboard.yaml

    oc apply -f ./poc-vm-statusmap-operator-dashboard.yaml
    print_ok "GrafanaDashboard poc-vm-statusmap-operator deployed (honeycomb VM status map)"

    local grafana_route
    grafana_route=$(oc get route poc-grafana-route -n "$GRAFANA_NS" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "$grafana_route" ]; then
        print_info "  Dashboard: https://${grafana_route}/d/poc-vm-overview-operator"
        print_info "  Dashboard: https://${grafana_route}/d/poc-ocpv-overview-operator"
        print_info "  Dashboard: https://${grafana_route}/d/poc-vm-statusmap-operator  (honeycomb)"
    fi
}

wait_grafana_ready() {
    local ns="$1" label="$2" retries=12 i=0
    while [ $i -lt $retries ]; do
        local phase
        phase=$(oc get pods -n "$ns" -l "$label" \
            -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
        local ready
        ready=$(oc get pods -n "$ns" -l "$label" \
            -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || true)
        if [ "$phase" = "Running" ] && [ "$ready" = "true" ]; then
            return 0
        fi
        sleep 5
        i=$((i+1))
    done
    return 1
}

ensure_polystat_plugin() {
    local grafana_name
    grafana_name=$(oc get grafana -n "$GRAFANA_NS" -l dashboards=poc-grafana \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [ -z "$grafana_name" ]; then
        print_warn "No Grafana instance found — cannot install the Polystat plugin."
        return 1
    fi

    local grafana_label="app=${grafana_name}"
    local grafana_pod container_name

    print_info "Waiting for Grafana Pod to be ready... (up to 60s)"
    wait_grafana_ready "$GRAFANA_NS" "$grafana_label"
    grafana_pod=$(oc get pods -n "$GRAFANA_NS" -l "$grafana_label" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    container_name=$(oc get pod "$grafana_pod" -n "$GRAFANA_NS" \
        -o jsonpath='{.spec.containers[0].name}' 2>/dev/null || echo "grafana")

    if [ -n "$grafana_pod" ]; then
        local installed
        installed=$(oc exec "$grafana_pod" -n "$GRAFANA_NS" -c "$container_name" -- \
            ls /var/lib/grafana/plugins/grafana-polystat-panel/plugin.json 2>/dev/null || true)
        if [ -n "$installed" ]; then
            print_ok "grafana-polystat-panel plugin is already installed"
            return 0
        fi
    fi

    local current_plugins
    current_plugins=$(oc get grafana "$grafana_name" -n "$GRAFANA_NS" \
        -o jsonpath='{.spec.deployment.spec.template.spec.containers[0].env[?(@.name=="GF_INSTALL_PLUGINS")].value}' 2>/dev/null || true)

    if ! echo "$current_plugins" | grep -q "grafana-polystat-panel"; then
        local new_plugins="grafana-polystat-panel"
        [ -n "$current_plugins" ] && new_plugins="${current_plugins},grafana-polystat-panel"

        oc patch grafana "$grafana_name" -n "$GRAFANA_NS" --type=merge \
            -p "{\"spec\":{\"deployment\":{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"${container_name}\",\"env\":[{\"name\":\"GF_INSTALL_PLUGINS\",\"value\":\"${new_plugins}\"}]}]}}}}}}" > /dev/null 2>&1 || true

        print_info "Grafana pod will restart to install the plugin — waiting... (up to 60s)"
        local deploy_name
        deploy_name=$(oc get deployment -n "$GRAFANA_NS" -l "$grafana_label" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "${grafana_name}-deployment")
        oc rollout status "deployment/${deploy_name}" -n "$GRAFANA_NS" --timeout=60s 2>/dev/null || true
    fi

    wait_grafana_ready "$GRAFANA_NS" "$grafana_label"
    grafana_pod=$(oc get pods -n "$GRAFANA_NS" -l "$grafana_label" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    container_name=$(oc get pod "$grafana_pod" -n "$GRAFANA_NS" \
        -o jsonpath='{.spec.containers[0].name}' 2>/dev/null || echo "grafana")

    local installed
    installed=$(oc exec "$grafana_pod" -n "$GRAFANA_NS" -c "$container_name" -- \
        ls /var/lib/grafana/plugins/grafana-polystat-panel/plugin.json 2>/dev/null || true)

    if [ -n "$installed" ]; then
        print_ok "grafana-polystat-panel plugin installed (online)"
        return 0
    fi

    print_warn "Online plugin install failed (airgap?) — installing from local zip..."

    print_info "Removing GF_INSTALL_PLUGINS env var (prevents crash in airgap)..."
    oc patch grafana "$grafana_name" -n "$GRAFANA_NS" --type=json \
        -p '[{"op":"remove","path":"/spec/deployment/spec/template/spec/containers/0/env"}]' 2>/dev/null || true
    sleep 5

    local zip_file="${SCRIPT_DIR}/grafana-polystat-panel.zip"
    if [ ! -f "$zip_file" ]; then
        print_error "Local plugin zip not found: ${zip_file}"
        return 1
    fi

    print_info "Waiting for Grafana Pod to be ready... (up to 60s)"
    local cp_ok=false retry
    for retry in $(seq 1 12); do
        grafana_pod=$(oc get pods -n "$GRAFANA_NS" -l "$grafana_label" \
            -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null \
            | awk -F'\t' '$2=="Running" && $3=="true" {print $1; exit}')
        if [ -n "$grafana_pod" ]; then
            container_name=$(oc get pod "$grafana_pod" -n "$GRAFANA_NS" \
                -o jsonpath='{.spec.containers[0].name}' 2>/dev/null || echo "grafana")
            if oc exec "$grafana_pod" -n "$GRAFANA_NS" -c "$container_name" -- true 2>/dev/null; then
                cp_ok=true
                break
            fi
        fi
        printf "  [%d/12] Waiting for pod connection...\r" "$retry"
        sleep 5
    done
    echo ""

    if [ "$cp_ok" != "true" ]; then
        print_error "Cannot connect to Grafana Pod."
        return 1
    fi
    print_ok "Grafana Pod ready: ${grafana_pod} (container: ${container_name})"

    oc cp "$zip_file" "$GRAFANA_NS/$grafana_pod:/tmp/grafana-polystat-panel.zip" -c "$container_name"
    oc exec "$grafana_pod" -n "$GRAFANA_NS" -c "$container_name" -- \
        unzip -o -q /tmp/grafana-polystat-panel.zip -d /var/lib/grafana/plugins/
    oc exec "$grafana_pod" -n "$GRAFANA_NS" -c "$container_name" -- \
        rm -f /tmp/grafana-polystat-panel.zip

    print_info "Restarting Grafana container to load the plugin... (emptyDir volume preserved)"
    oc exec "$grafana_pod" -n "$GRAFANA_NS" -c "$container_name" -- kill 1 2>/dev/null || true
    sleep 10
    print_info "Waiting for container restart... (up to 3min, may take longer with CrashLoopBackOff)"
    local restart_ok=false ri
    for ri in $(seq 1 36); do
        if oc exec "$grafana_pod" -n "$GRAFANA_NS" -c "$container_name" -- \
            ls /var/lib/grafana/plugins/grafana-polystat-panel/plugin.json 2>/dev/null | grep -q plugin.json; then
            restart_ok=true
            break
        fi
        printf "  [%d/36] Waiting for container restart...\r" "$ri"
        sleep 5
    done
    echo ""
    if [ "$restart_ok" = "true" ]; then
        print_ok "grafana-polystat-panel plugin installed (airgap)"
    else
        print_warn "Container restart timed out — plugin will load once Grafana is ready."
    fi
    return 0
}

step_perses_dashboards() {
    print_step "4/4  Deploy the same dashboards via COO + Red Hat build of Perses (optional)"

    if [ "${COO_INSTALLED:-false}" != "true" ] || ! oc get crd uiplugins.observability.openshift.io &>/dev/null; then
        print_warn "Cluster Observability Operator (or its UIPlugin CRD) not found — skipping."
        print_info "  See operators/perses-coo.md for installation."
        return
    fi

    # Enable the Perses dashboarding UI (Observe > Dashboards (Perses))
    cat <<EOF | oc apply -f - > /dev/null || { print_warn "Failed to apply UIPlugin monitoring — check COO version (needs 1.5+)"; return; }
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
    print_ok "UIPlugin monitoring (Perses) enabled"

    if ! oc get namespace "$COO_NS" &>/dev/null; then
        print_warn "Namespace ${COO_NS} not found yet — Perses may still be starting. Skipping dashboard/datasource registration for now."
        print_info "  Re-run this script once 'oc get pods -n ${COO_NS} | grep perses' shows Running."
        return
    fi

    # Register the in-cluster Thanos Querier as a cluster-wide datasource.
    # TLS-only (service-ca); if queries come back "Unauthorized", Thanos Querier
    # needs a bearer-token identity bound to cluster-monitoring-view — see the
    # troubleshooting note in operators/perses-coo.md.
    if oc get persesglobaldatasource thanos-querier-global-datasource &>/dev/null; then
        print_ok "PersesGlobalDatasource thanos-querier-global-datasource already exists — skipping"
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
            print_ok "PersesGlobalDatasource thanos-querier-global-datasource registered"
        else
            print_warn "Failed to create PersesGlobalDatasource — see operators/perses-coo.md"
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
        && print_ok "PersesDashboard poc-vm-overview-perses deployed" \
        || print_warn "Failed to apply poc-vm-overview-perses.yaml — check 'oc explain persesdashboard.spec.config' against your COO version"

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
        && print_ok "PersesDashboard poc-ocpv-overview-perses deployed" \
        || print_warn "Failed to apply poc-ocpv-overview-perses.yaml — check 'oc explain persesdashboard.spec.config' against your COO version"

    # Grant view access via native Kubernetes RBAC (no separate Grafana user DB)
    cat <<EOF | oc apply -f - > /dev/null \
        && print_ok "RoleBinding poc-perses-dashboard-viewer applied in ${COO_NS}" \
        || print_warn "Failed to apply RoleBinding poc-perses-dashboard-viewer — grant persesdashboard-viewer-role manually"
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
    print_info "  Dashboard: Console → Observe → Dashboards (Perses) → KubeVirt VM Overall Status (Perses)"
    print_info "  Dashboard: Console → Observe → Dashboards (Perses) → OpenShift Virtualization Cluster Overview (Perses)"
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! Custom dashboards registered in the OpenShift console.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Navigate to : ${CYAN}Administrator perspective → Observe → Dashboards${NC}"
    echo -e "  Dashboards  :"
    echo -e "    - KubeVirt VM Overall Status"
    echo -e "    - OpenShift Virtualization Cluster Overview"
    echo ""
    echo -e "  No Grafana Operator, Grafana instance, or Route is required —"
    echo -e "  the console renders these dashboards directly using the"
    echo -e "  in-cluster Thanos Querier as the data source."
    echo ""
    echo -e "  Check ConfigMaps:"
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

        echo -e "  Grafana Operator dashboards also deployed in namespace ${GRAFANA_NS}:"
        echo -e "    ${CYAN}oc get grafanadashboard,grafanadatasource -n ${GRAFANA_NS}${NC}"
        if [ -n "$grafana_route" ]; then
            echo ""
            echo -e "  Grafana URL:"
            echo -e "    ${BLUE}https://${grafana_route}${NC}"
            echo -e "    - ${CYAN}https://${grafana_route}/d/poc-vm-overview-operator${NC}"
            echo -e "    - ${CYAN}https://${grafana_route}/d/poc-ocpv-overview-operator${NC}"
            echo -e "    - ${CYAN}https://${grafana_route}/d/poc-vm-statusmap-operator${NC}  (honeycomb)"
            echo -e "    Credentials: admin / ${GRAFANA_ADMIN_PASSWORD}"
        fi
        echo ""
    fi

    if oc get uiplugin monitoring &>/dev/null; then
        echo -e "  Perses dashboards also deployed in namespace ${COO_NS}:"
        echo -e "    ${CYAN}oc get persesdashboard,persesglobaldatasource -n ${COO_NS}${NC}"
        echo -e "  Perses UI: ${CYAN}Observe → Dashboards (Perses)${NC} — see operators/perses-coo.md for details."
        echo ""
    fi

    echo -e "  For details: refer to 12-grafana/12-grafana.md"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Delete 12-grafana resources"
    oc delete configmap poc-vm-overview-dashboard -n "$DASHBOARD_NS" --ignore-not-found 2>/dev/null || true
    oc delete configmap poc-ocpv-overview-dashboard -n "$DASHBOARD_NS" --ignore-not-found 2>/dev/null || true

    detect_grafana_instance
    if [ -n "${GRAFANA_NS:-}" ]; then
        oc delete grafanadashboard poc-vm-overview-operator poc-ocpv-overview-operator poc-vm-statusmap-operator -n "$GRAFANA_NS" --ignore-not-found 2>/dev/null || true
        oc delete grafanadatasource thanos-querier-datasource -n "$GRAFANA_NS" --ignore-not-found 2>/dev/null || true
        oc delete serviceaccount poc-grafana-view -n "$GRAFANA_NS" --ignore-not-found 2>/dev/null || true
        oc delete grafana poc-grafana -n "$GRAFANA_NS" --ignore-not-found 2>/dev/null || true
        print_info "Grafana instance deleted (namespace: ${GRAFANA_NS})"
        if [ "$GRAFANA_NS" = "$GRAFANA_DEFAULT_NS" ]; then
            oc delete namespace "$GRAFANA_DEFAULT_NS" --ignore-not-found 2>/dev/null || true
            print_info "Namespace ${GRAFANA_DEFAULT_NS} deleted"
        fi
    fi
    oc delete clusterrolebinding grafana-cluster-monitoring-view --ignore-not-found 2>/dev/null || true

    oc delete persesdashboard poc-vm-overview-perses poc-ocpv-overview-perses -n "$COO_NS" --ignore-not-found 2>/dev/null || true
    oc delete persesglobaldatasource thanos-querier-global-datasource --ignore-not-found 2>/dev/null || true
    oc delete rolebinding poc-perses-dashboard-viewer -n "$COO_NS" --ignore-not-found 2>/dev/null || true
    oc delete uiplugin monitoring --ignore-not-found 2>/dev/null || true

    print_ok "12-grafana resources deleted"
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Grafana — OpenShift Console Built-in Monitoring Dashboards${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}  virt-poc ${POC_VERSION}${NC}"

    preflight
    step_dashboard_vm
    step_dashboard_ocpv
    step_operator_dashboards
    step_perses_dashboards
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
