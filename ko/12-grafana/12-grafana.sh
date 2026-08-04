#!/bin/bash
# =============================================================================
# 12-grafana.sh
#
# OpenShift 콘솔 내장 모니터링 대시보드 (Grafana Operator 불필요)
#   1/2  poc-vm-overview 대시보드 배포 (KubeVirt VM 전체 상태)
#   2/2  poc-ocpv-overview 대시보드 배포 (OpenShift Virtualization 클러스터 개요)
#
# 대시보드는 openshift-config-managed Namespace에 console.openshift.io/dashboard:
# "true" 라벨을 가진 ConfigMap으로 등록됩니다. OpenShift 웹 콘솔이 이를 직접
# 인식하여 Observe > Dashboards(Administrator perspective)에 렌더링하며,
# 데이터소스는 클러스터 내장 Thanos Querier를 사용합니다 — Grafana 인스턴스는
# 전혀 배포하지 않습니다.
#
# Usage: ./12-grafana.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

source "${SCRIPT_DIR}/../utils/common.sh"

DASHBOARD_NS="openshift-config-managed"

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
}

step_dashboard_vm() {
    print_step "1/2  KubeVirt VM 전체 상태 대시보드 배포 (poc-vm-overview)"

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
    print_step "2/2  OpenShift Virtualization 클러스터 개요 대시보드 배포 (poc-ocpv-overview)"

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
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
