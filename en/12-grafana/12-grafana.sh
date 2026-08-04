#!/bin/bash
# =============================================================================
# 12-grafana.sh
#
# OpenShift Console built-in Monitoring Dashboards (no Grafana Operator required)
#   1/3  Deploy poc-vm-overview dashboard (KubeVirt VM Overall Status)
#   2/3  Deploy poc-ocpv-overview dashboard (OpenShift Virtualization Cluster Overview)
#   3/3  Deploy the same dashboards via Grafana Operator (optional, auto-skipped
#        if the Grafana Operator / a poc-grafana Grafana instance is not found)
#
# Dashboards 1/3 and 2/3 are registered as ConfigMaps in openshift-config-managed
# with the label console.openshift.io/dashboard: "true". The OpenShift web
# console renders them directly under Observe > Dashboards (Administrator
# perspective) using the in-cluster Thanos Querier — no Grafana instance
# is required for this path.
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
GRAFANA_NS=""

# Looks up the namespace of the Grafana instance labeled dashboards=poc-grafana
# (see operators/grafana-operator.md) and stores it in the global GRAFANA_NS.
detect_grafana_instance() {
    GRAFANA_NS=$(oc get grafana --all-namespaces -l dashboards=poc-grafana \
        -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
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
            print_ok "Grafana instance found in namespace ${GRAFANA_NS} — step 3/3 will deploy operator-based dashboards."
        else
            print_warn "Grafana Operator installed but no Grafana instance labeled dashboards=poc-grafana found — step 3/3 will be skipped."
            print_info "  See operators/grafana-operator.md to create one."
        fi
    else
        print_warn "Grafana Operator not installed — step 3/3 (operator-based dashboards) will be skipped."
        print_info "  See operators/grafana-operator.md for installation."
    fi
}

step_dashboard_vm() {
    print_step "1/3  Deploy KubeVirt VM Overall Status dashboard (poc-vm-overview)"

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
    print_step "2/3  Deploy OpenShift Virtualization Cluster Overview dashboard (poc-ocpv-overview)"

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
    print_step "3/3  Deploy the same dashboards via Grafana Operator (optional)"

    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        print_warn "Grafana Operator not installed — skipping."
        print_info "  See operators/grafana-operator.md for installation."
        return
    fi

    detect_grafana_instance
    if [ -z "${GRAFANA_NS:-}" ]; then
        print_warn "No Grafana instance labeled dashboards=poc-grafana found — skipping."
        print_info "  See operators/grafana-operator.md to create one."
        return
    fi
    print_ok "Grafana instance detected in namespace ${GRAFANA_NS}"

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
  "annotations": {"list": [{"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": true, "hide": true, "iconColor": "rgba(0,211,255,1)", "name": "Annotations & Alerts", "type": "dashboard"}]},
  "description": "KubeVirt VM Overall Status — Grafana Operator based (Thanos Querier)",
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "refresh": "30s",
  "schemaVersion": 39,
  "tags": ["kubevirt", "vm", "poc", "openshift-virtualization", "grafana-operator"],
  "templating": {
    "list": [
      {"current": {"selected": false, "text": "Thanos-Querier", "value": "Thanos-Querier"}, "hide": 0, "includeAll": false, "label": "Datasource", "multi": false, "name": "datasource", "options": [], "query": "prometheus", "refresh": 1, "type": "datasource"},
      {"allValue": ".*", "current": {"selected": true, "text": "All", "value": "$__all"}, "datasource": {"type": "prometheus", "uid": "${datasource}"}, "definition": "label_values(kubevirt_vmi_info, namespace)", "hide": 0, "includeAll": true, "label": "Namespace", "multi": true, "name": "namespace", "options": [], "query": {"query": "label_values(kubevirt_vmi_info, namespace)", "refId": "Q"}, "refresh": 2, "regex": "", "sort": 1, "type": "query"},
      {"allValue": ".*", "current": {"selected": true, "text": "All", "value": "$__all"}, "datasource": {"type": "prometheus", "uid": "${datasource}"}, "definition": "label_values(kubevirt_vmi_info, name)", "hide": 0, "includeAll": true, "label": "VM Name", "multi": true, "name": "vm", "options": [], "query": {"query": "label_values(kubevirt_vmi_info, name)", "refId": "Q"}, "refresh": 2, "regex": "", "sort": 1, "type": "query"}
    ]
  },
  "time": {"from": "now-1h", "to": "now"},
  "timepicker": {},
  "timezone": "browser",
  "title": "KubeVirt VM Overall Status (Operator)",
  "uid": "poc-vm-overview-operator",
  "version": 1,
  "panels": [
    {"collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0}, "id": 100, "title": "VM Status Summary", "type": "row"},
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"fixedColor": "green", "mode": "fixed"}, "mappings": [], "unit": "none"}, "overrides": []},
      "gridPos": {"h": 4, "w": 6, "x": 0, "y": 1},
      "id": 1,
      "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "center", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
      "title": "Running — Cluster Total",
      "type": "stat",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "sum(kubevirt_vmi_phase_count{phase=~\"Running|running\"}) or vector(0)", "legendFormat": "", "refId": "A"}]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"fixedColor": "yellow", "mode": "fixed"}, "mappings": [], "unit": "none"}, "overrides": []},
      "gridPos": {"h": 4, "w": 6, "x": 6, "y": 1},
      "id": 2,
      "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "center", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
      "title": "Paused — Cluster Total",
      "type": "stat",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "sum(kubevirt_vmi_phase_count{phase=~\"Paused|paused\"}) or vector(0)", "legendFormat": "", "refId": "A"}]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"fixedColor": "red", "mode": "fixed"}, "mappings": [], "unit": "none"}, "overrides": []},
      "gridPos": {"h": 4, "w": 6, "x": 12, "y": 1},
      "id": 3,
      "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "center", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
      "title": "Abnormal (Pending/Failed) — Cluster Total",
      "type": "stat",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "sum(kubevirt_vmi_phase_count{phase!~\"Running|running|Paused|paused\"}) or vector(0)", "legendFormat": "", "refId": "A"}]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"fixedColor": "blue", "mode": "fixed"}, "mappings": [], "unit": "none"}, "overrides": []},
      "gridPos": {"h": 4, "w": 6, "x": 18, "y": 1},
      "id": 4,
      "options": {"colorMode": "background", "graphMode": "none", "justifyMode": "center", "orientation": "auto", "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false}, "textMode": "auto"},
      "title": "Total Active VMI — Cluster Total",
      "type": "stat",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "count(kubevirt_vmi_info) or vector(0)", "legendFormat": "", "refId": "A"}]
    },
    {"collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 5}, "id": 101, "title": "CPU", "type": "row"},
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"mode": "palette-classic"}, "custom": {"drawStyle": "line", "fillOpacity": 10, "lineWidth": 1, "pointSize": 5, "showPoints": "never", "spanNulls": false}, "mappings": [], "unit": "short"}, "overrides": []},
      "gridPos": {"h": 8, "w": 24, "x": 0, "y": 6},
      "id": 5,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "CPU Utilization (vCPU seconds/s)",
      "type": "timeseries",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "rate(kubevirt_vmi_cpu_usage_seconds_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])", "legendFormat": "{{namespace}}/{{name}}", "refId": "A"}]
    },
    {"collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 14}, "id": 102, "title": "Memory", "type": "row"},
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"mode": "palette-classic"}, "custom": {"drawStyle": "line", "fillOpacity": 10, "lineWidth": 1, "pointSize": 5, "showPoints": "never", "spanNulls": false}, "mappings": [], "unit": "bytes"}, "overrides": []},
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 15},
      "id": 6,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "Memory Usage (Resident)",
      "type": "timeseries",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "kubevirt_vmi_memory_resident_bytes{namespace=~\"$namespace\", name=~\"$vm\"}", "legendFormat": "{{namespace}}/{{name}}", "refId": "A"}]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"mode": "palette-classic"}, "custom": {"drawStyle": "line", "fillOpacity": 10, "lineWidth": 1, "pointSize": 5, "showPoints": "never", "spanNulls": false}, "mappings": [], "unit": "percentunit", "min": 0, "max": 1}, "overrides": []},
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 15},
      "id": 7,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "Memory Utilization (%)",
      "type": "timeseries",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "kubevirt_vmi_memory_resident_bytes{namespace=~\"$namespace\", name=~\"$vm\"} / (kubevirt_vmi_memory_resident_bytes{namespace=~\"$namespace\", name=~\"$vm\"} + kubevirt_vmi_memory_available_bytes{namespace=~\"$namespace\", name=~\"$vm\"})", "legendFormat": "{{namespace}}/{{name}}", "refId": "A"}]
    },
    {"collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 23}, "id": 103, "title": "Network I/O", "type": "row"},
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"mode": "palette-classic"}, "custom": {"drawStyle": "line", "fillOpacity": 10, "lineWidth": 1, "pointSize": 5, "showPoints": "never", "spanNulls": false}, "mappings": [], "unit": "Bps"}, "overrides": []},
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 24},
      "id": 8,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "Network Receive (RX)",
      "type": "timeseries",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "rate(kubevirt_vmi_network_receive_bytes_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])", "legendFormat": "{{namespace}}/{{name}} [{{interface}}]", "refId": "A"}]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"mode": "palette-classic"}, "custom": {"drawStyle": "line", "fillOpacity": 10, "lineWidth": 1, "pointSize": 5, "showPoints": "never", "spanNulls": false}, "mappings": [], "unit": "Bps"}, "overrides": []},
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 24},
      "id": 9,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "Network Transmit (TX)",
      "type": "timeseries",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "rate(kubevirt_vmi_network_transmit_bytes_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])", "legendFormat": "{{namespace}}/{{name}} [{{interface}}]", "refId": "A"}]
    },
    {"collapsed": false, "gridPos": {"h": 1, "w": 24, "x": 0, "y": 32}, "id": 104, "title": "Storage I/O", "type": "row"},
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"mode": "palette-classic"}, "custom": {"drawStyle": "line", "fillOpacity": 10, "lineWidth": 1, "pointSize": 5, "showPoints": "never", "spanNulls": false}, "mappings": [], "unit": "Bps"}, "overrides": []},
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 33},
      "id": 10,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "Storage Read",
      "type": "timeseries",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "rate(kubevirt_vmi_storage_read_traffic_bytes_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])", "legendFormat": "{{namespace}}/{{name}} [{{drive}}]", "refId": "A"}]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {"defaults": {"color": {"mode": "palette-classic"}, "custom": {"drawStyle": "line", "fillOpacity": 10, "lineWidth": 1, "pointSize": 5, "showPoints": "never", "spanNulls": false}, "mappings": [], "unit": "Bps"}, "overrides": []},
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 33},
      "id": 11,
      "options": {"legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true}, "tooltip": {"mode": "multi", "sort": "desc"}},
      "title": "Storage Write",
      "type": "timeseries",
      "targets": [{"datasource": {"type": "prometheus", "uid": "${datasource}"}, "expr": "rate(kubevirt_vmi_storage_write_traffic_bytes_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])", "legendFormat": "{{namespace}}/{{name}} [{{drive}}]", "refId": "A"}]
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

    local grafana_route
    grafana_route=$(oc get route poc-grafana-route -n "$GRAFANA_NS" -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    if [ -n "$grafana_route" ]; then
        print_info "  Dashboard: https://${grafana_route}/d/poc-vm-overview-operator"
        print_info "  Dashboard: https://${grafana_route}/d/poc-ocpv-overview-operator"
    fi
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
        echo -e "  Grafana Operator dashboards also deployed in namespace ${GRAFANA_NS}:"
        echo -e "    ${CYAN}oc get grafanadashboard,grafanadatasource -n ${GRAFANA_NS}${NC}"
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
        oc delete grafanadashboard poc-vm-overview-operator poc-ocpv-overview-operator -n "$GRAFANA_NS" --ignore-not-found 2>/dev/null || true
        oc delete grafanadatasource thanos-querier-datasource -n "$GRAFANA_NS" --ignore-not-found 2>/dev/null || true
        oc delete serviceaccount poc-grafana-view -n "$GRAFANA_NS" --ignore-not-found 2>/dev/null || true
    fi
    oc delete clusterrolebinding grafana-cluster-monitoring-view --ignore-not-found 2>/dev/null || true

    print_ok "12-grafana resources deleted"
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Grafana — OpenShift Console Built-in Monitoring Dashboards${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_dashboard_vm
    step_dashboard_ocpv
    step_operator_dashboards
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
