#!/bin/bash
# =============================================================================
# 11-grafana.sh
#
# Grafana Operator + OpenShift built-in Prometheus datasource + dashboards
#   1/5  Create poc-monitoring namespace
#   2/5  Deploy Grafana instance (requires Grafana Operator)
#   3/5  Integrate OpenShift Prometheus DataSource (thanos-querier:9091)
#   4/5  Deploy poc-vm-overview dashboard (KubeVirt VM Overall Status)
#   5/5  Deploy grafana-dashboard-ocp-v (OpenShift Virtualization dashboard from URL)
#
# Usage: ./11-grafana.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-monitoring"

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

step_install_grafana_guide() {
    echo ""
    print_warn "Grafana Community Operator not installed — install using the procedure below then re-run setup.sh."
    echo ""
    echo -e "  ${CYAN}# 1. Install Grafana Operator (community) — scoped to poc-monitoring namespace${NC}"
    echo -e "  ${CYAN}oc apply -f - <<'EOF'${NC}"
    cat <<'YAML'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: grafana-operator-group
  namespace: poc-monitoring
spec:
  targetNamespaces:
    - poc-monitoring
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: grafana-operator
  namespace: poc-monitoring
spec:
  channel: v5
  name: grafana-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
YAML
    echo -e "  ${CYAN}EOF${NC}"
    echo ""
    print_info "After installation, verify:"
    echo -e "  ${CYAN}oc get csv -n poc-monitoring | grep grafana${NC}"
    print_info "After installation, re-run this script."
    echo ""
}

preflight() {
    print_step "Pre-flight checks"

    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift."
        exit 1
    fi
    print_ok "Cluster connection: $(oc whoami) @ $(oc whoami --show-server)"

    # Auto-detect from cluster CSV if not in env.conf
    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        if oc get csv --all-namespaces --no-headers 2>/dev/null \
            | grep -qi "grafana-operator"; then
            GRAFANA_INSTALLED=true
            print_ok "Grafana Community Operator auto-detected (CSV)"
        fi
    fi

    if [ "${GRAFANA_INSTALLED:-false}" != "true" ]; then
        print_error "Grafana Community Operator is not installed."
        step_install_grafana_guide
        exit 77
    fi

    print_ok "Grafana Community Operator confirmed"
}

step_namespace() {
    print_step "1/5  Create namespace (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        local ns_phase
        ns_phase=$(oc get namespace "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

        if [ "$ns_phase" = "Terminating" ]; then
            print_warn "Namespace $NS is in Terminating state — waiting for deletion to complete..."
            local retries=36
            local i=0
            while [ "$i" -lt "$retries" ]; do
                if ! oc get namespace "$NS" &>/dev/null; then
                    print_ok "Namespace deletion complete"
                    break
                fi
                printf "  [%d/%d] Waiting for Terminating...\r" "$((i+1))" "$retries"
                sleep 5
                i=$((i+1))
            done
            echo ""

            if oc get namespace "$NS" &>/dev/null; then
                print_error "Namespace $NS is still in Terminating state."
                print_info "Manual check: oc get namespace $NS -o yaml"
                print_info "Force remove finalizer: oc patch namespace $NS -p '{\"metadata\":{\"finalizers\":[]}}' --type=merge"
                exit 1
            fi

            oc new-project "$NS" > /dev/null
            print_ok "Namespace $NS recreated"
        else
            print_ok "Namespace $NS already exists (Active) — skipping"
        fi
    else
        oc new-project "$NS" > /dev/null
        print_ok "Namespace $NS created"
    fi
}

step_grafana() {
    print_step "2/5  Deploy Grafana instance"

    local grafana_pass="${GRAFANA_ADMIN_PASS:-grafana123}"

    if oc get grafana poc-grafana -n "$NS" &>/dev/null; then
        print_ok "Grafana poc-grafana already exists — skipping"
    else
        cat > ./poc-grafana.yaml <<EOF
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: poc-grafana
  namespace: ${NS}
  labels:
    dashboards: poc-grafana
spec:
  config:
    auth:
      disable_login_form: "false"
    auth.anonymous:
      enabled: "false"
    security:
      admin_user: admin
      admin_password: ${grafana_pass}
EOF
        oc apply -f ./poc-grafana.yaml
        print_ok "Grafana poc-grafana deployed (admin password: ${grafana_pass})"
    fi

    # Wait for Grafana Pod Ready
    print_info "Waiting for Grafana Pod to be ready..."
    local retries=24
    local i=0
    while [ "$i" -lt "$retries" ]; do
        local ready
        ready=$(oc get pods -n "$NS" -l "app=poc-grafana" \
            --no-headers 2>/dev/null | awk '{print $2}' | head -1)
        if [ "${ready}" = "1/1" ]; then
            print_ok "Grafana Pod Ready"
            break
        fi
        printf "  [%d/%d] Waiting... (%s)\r" "$((i+1))" "$retries" "${ready:--}"
        sleep 5
        i=$((i+1))
    done
    echo ""

    # Create OpenShift Route (create Route directly instead of ingress)
    if oc get route poc-grafana-route -n "$NS" &>/dev/null; then
        print_ok "Route poc-grafana-route already exists — skipping"
    else
        cat > ./poc-grafana-route.yaml <<EOF
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: poc-grafana-route
  namespace: ${NS}
  labels:
    app: grafana
spec:
  to:
    kind: Service
    name: poc-grafana-service
  port:
    targetPort: grafana
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
        oc apply -f ./poc-grafana-route.yaml
        print_ok "Route poc-grafana-route created"
    fi

    local grafana_url
    grafana_url=$(oc get route poc-grafana-route -n "$NS" \
        -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    [ -n "$grafana_url" ] && print_ok "Grafana URL: https://${grafana_url}"
    print_info "  Login: admin / ${grafana_pass}"

    # Wait for Grafana SA creation (Grafana Operator creates SA asynchronously)
    print_info "Waiting for ServiceAccount poc-grafana-sa to be created..."
    local sa_retries=24
    local si=0
    while [ "$si" -lt "$sa_retries" ]; do
        if oc get serviceaccount poc-grafana-sa -n "$NS" &>/dev/null; then
            print_ok "ServiceAccount poc-grafana-sa confirmed"
            break
        fi
        printf "  [%d/%d] Waiting for SA...\r" "$((si+1))" "$sa_retries"
        sleep 5
        si=$((si+1))
    done
    echo ""

    # Grant cluster-monitoring-view permission to Grafana SA (oc apply — idempotent)
    print_info "Configuring Prometheus access permissions..."
    cat > ./grafana-monitoring-crb.yaml <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: grafana-cluster-monitoring-view
subjects:
- kind: ServiceAccount
  name: poc-grafana-sa
  namespace: ${NS}
roleRef:
  kind: ClusterRole
  name: cluster-monitoring-view
  apiGroup: rbac.authorization.k8s.io
EOF
    oc apply --server-side -f ./grafana-monitoring-crb.yaml
    print_ok "cluster-monitoring-view ClusterRoleBinding applied"
}

step_datasource() {
    print_step "3/5  Integrate OpenShift Prometheus DataSource"

    # Verify ServiceAccount exists (waited in step_grafana, but ensure once more)
    if ! oc get serviceaccount poc-grafana-sa -n "$NS" &>/dev/null; then
        print_warn "ServiceAccount poc-grafana-sa not found — skipping DataSource step."
        print_info "Manual check: oc get sa -n ${NS}"
        return
    fi

    # Generate ServiceAccount token (retry 3 times)
    TOKEN=""
    local t=0
    while [ "$t" -lt 3 ] && [ -z "$TOKEN" ]; do
        TOKEN=$(oc create token poc-grafana-sa -n "$NS" --duration=8760h 2>/dev/null || true)
        [ -z "$TOKEN" ] && sleep 5
        t=$((t+1))
    done
    if [ -z "$TOKEN" ]; then
        print_warn "Grafana SA token creation failed — Grafana Pod may still be starting."
        print_info "Run manually: oc create token poc-grafana-sa -n ${NS} --duration=8760h"
        return
    fi

    cat > ./prometheus-datasource.yaml <<EOF
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDatasource
metadata:
  name: prometheus-datasource
  namespace: ${NS}
spec:
  instanceSelector:
    matchLabels:
      dashboards: poc-grafana
  datasource:
    name: Prometheus
    type: prometheus
    access: proxy
    url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
    isDefault: true
    jsonData:
      httpHeaderName1: Authorization
      timeInterval: 5s
      tlsSkipVerify: true
    secureJsonData:
      httpHeaderValue1: Bearer ${TOKEN}
EOF
    oc apply -f ./prometheus-datasource.yaml
    print_ok "Prometheus DataSource integrated"
}

step_dashboard_vm() {
    print_step "4/5  Deploy VM overall status dashboard (poc-vm-overview)"

    # Delete existing CR then recreate — prevents oc apply unchanged and ensures recovery after Grafana UI deletion
    if oc get grafanadashboard poc-vm-overview -n "$NS" &>/dev/null; then
        print_info "GrafanaDashboard poc-vm-overview: deleting existing CR and recreating..."
        oc delete grafanadashboard poc-vm-overview -n "$NS" --wait=false 2>/dev/null || true
        sleep 2
    fi

    # Dashboard JSON (use single-quoted heredoc to prevent $-expansion)
    cat > ./poc-vm-dashboard.json << 'DASHBOARD_EOF'
{
  "annotations": {
    "list": [
      {
        "builtIn": 1,
        "datasource": {"type": "grafana", "uid": "-- Grafana --"},
        "enable": true,
        "hide": true,
        "iconColor": "rgba(0, 211, 255, 1)",
        "name": "Annotations & Alerts",
        "type": "dashboard"
      }
    ]
  },
  "description": "OpenShift Virtualization overall VM operations monitoring",
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "refresh": "30s",
  "schemaVersion": 39,
  "tags": ["kubevirt", "vm", "poc", "openshift-virtualization"],
  "templating": {
    "list": [
      {
        "current": {"selected": false, "text": "Prometheus", "value": "Prometheus"},
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
        "definition": "label_values(kubevirt_vmi_info, namespace)",
        "hide": 0,
        "includeAll": true,
        "label": "Namespace",
        "multi": true,
        "name": "namespace",
        "options": [],
        "query": {"query": "label_values(kubevirt_vmi_info, namespace)", "refId": "Q"},
        "refresh": 2,
        "regex": "",
        "sort": 1,
        "type": "query"
      },
      {
        "allValue": ".*",
        "current": {"selected": true, "text": "All", "value": "$__all"},
        "datasource": {"type": "prometheus", "uid": "${datasource}"},
        "definition": "label_values(kubevirt_vmi_info, name)",
        "hide": 0,
        "includeAll": true,
        "label": "VM Name",
        "multi": true,
        "name": "vm",
        "options": [],
        "query": {"query": "label_values(kubevirt_vmi_info, name)", "refId": "Q"},
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
  "title": "KubeVirt VM Overall Status",
  "uid": "poc-vm-overview",
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
          "color": {"fixedColor": "green", "mode": "fixed"},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {"h": 4, "w": 6, "x": 0, "y": 1},
      "id": 1,
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false},
        "textMode": "auto"
      },
      "title": "Running — Cluster Total",
      "type": "stat",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "sum(kubevirt_vmi_phase_count{phase=~\"Running|running\"}) or vector(0)",
          "legendFormat": "Running",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"fixedColor": "yellow", "mode": "fixed"},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "yellow", "value": null}]},
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {"h": 4, "w": 6, "x": 6, "y": 1},
      "id": 2,
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false},
        "textMode": "auto"
      },
      "title": "Paused — Cluster Total",
      "type": "stat",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "sum(kubevirt_vmi_phase_count{phase=~\"Paused|paused\"}) or vector(0)",
          "legendFormat": "Paused",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"fixedColor": "red", "mode": "fixed"},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "red", "value": null}]},
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {"h": 4, "w": 6, "x": 12, "y": 1},
      "id": 3,
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false},
        "textMode": "auto"
      },
      "title": "Abnormal VMI (Pending / Failed) — Cluster Total",
      "type": "stat",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "sum(kubevirt_vmi_phase_count{phase!~\"Running|running|Paused|paused\"}) or vector(0)",
          "legendFormat": "Abnormal (Pending/Failed etc.)",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"fixedColor": "blue", "mode": "fixed"},
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "blue", "value": null}]},
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {"h": 4, "w": 6, "x": 18, "y": 1},
      "id": 4,
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false},
        "textMode": "auto"
      },
      "title": "Total Active VMI — Cluster Total",
      "type": "stat",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "count(kubevirt_vmi_info) or vector(0)",
          "legendFormat": "Total",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 5},
      "id": 101,
      "title": "VM Inventory",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "thresholds"},
          "custom": {
            "align": "auto",
            "cellOptions": {"type": "auto"},
            "filterable": true,
            "inspect": false
          },
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]}
        },
        "overrides": [
          {
            "matcher": {"id": "byName", "options": "ready"},
            "properties": [
              {
                "id": "mappings",
                "value": [
                  {"options": {"true":  {"color": "green", "index": 0, "text": "Ready"}},  "type": "value"},
                  {"options": {"false": {"color": "red",   "index": 1, "text": "Not Ready"}}, "type": "value"}
                ]
              },
              {"id": "custom.cellOptions", "value": {"type": "color-text"}}
            ]
          },
          {"matcher": {"id": "byName", "options": "Value"},    "properties": [{"id": "custom.hidden", "value": true}]},
          {"matcher": {"id": "byName", "options": "Time"},     "properties": [{"id": "custom.hidden", "value": true}]},
          {"matcher": {"id": "byName", "options": "__name__"}, "properties": [{"id": "custom.hidden", "value": true}]},
          {"matcher": {"id": "byName", "options": "job"},      "properties": [{"id": "custom.hidden", "value": true}]},
          {"matcher": {"id": "byName", "options": "instance"}, "properties": [{"id": "custom.hidden", "value": true}]},
          {"matcher": {"id": "byName", "options": "endpoint"}, "properties": [{"id": "custom.hidden", "value": true}]},
          {"matcher": {"id": "byName", "options": "service"},  "properties": [{"id": "custom.hidden", "value": true}]},
          {"matcher": {"id": "byName", "options": "pod"},      "properties": [{"id": "custom.hidden", "value": true}]},
          {"matcher": {"id": "byName", "options": "container"},"properties": [{"id": "custom.hidden", "value": true}]},
          {"matcher": {"id": "byName", "options": "namespace"}, "properties": [{"id": "displayName", "value": "Namespace"}]},
          {"matcher": {"id": "byName", "options": "name"},      "properties": [{"id": "displayName", "value": "VM Name"}]},
          {"matcher": {"id": "byName", "options": "node"},      "properties": [{"id": "displayName", "value": "Node"}]},
          {"matcher": {"id": "byName", "options": "ready"},     "properties": [{"id": "displayName", "value": "Ready Status"}]},
          {"matcher": {"id": "byName", "options": "os"},        "properties": [{"id": "displayName", "value": "OS"}]},
          {"matcher": {"id": "byName", "options": "workload"},  "properties": [{"id": "displayName", "value": "Workload"}]}
        ]
      },
      "gridPos": {"h": 10, "w": 24, "x": 0, "y": 6},
      "id": 5,
      "options": {
        "cellHeight": "sm",
        "footer": {"countRows": false, "fields": "", "reducer": ["sum"], "show": false},
        "showHeader": true,
        "sortBy": [{"desc": false, "displayName": "Namespace"}]
      },
      "title": "VM List (Cluster Total)",
      "transformations": [
        {"id": "merge", "options": {}}
      ],
      "type": "table",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "kubevirt_vmi_info",
          "instant": true,
          "format": "table",
          "legendFormat": "",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 14},
      "id": 102,
      "title": "CPU",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {
            "axisBorderShow": false, "axisCenteredZero": false, "axisColorMode": "text",
            "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0,
            "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none",
            "hideFrom": {"legend": false, "tooltip": false, "viz": false},
            "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5,
            "scaleDistribution": {"type": "linear"}, "showPoints": "never",
            "spanNulls": false, "stacking": {"group": "A", "mode": "none"},
            "thresholdsStyle": {"mode": "off"}
          },
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "short"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 24, "x": 0, "y": 15},
      "id": 6,
      "options": {
        "legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true},
        "tooltip": {"mode": "multi", "sort": "desc"}
      },
      "title": "CPU Utilization (vCPU seconds/s)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "rate(kubevirt_vmi_cpu_usage_seconds_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])",
          "legendFormat": "{{namespace}}/{{name}}",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 23},
      "id": 103,
      "title": "Memory",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {
            "axisBorderShow": false, "axisCenteredZero": false, "axisColorMode": "text",
            "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0,
            "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none",
            "hideFrom": {"legend": false, "tooltip": false, "viz": false},
            "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5,
            "scaleDistribution": {"type": "linear"}, "showPoints": "never",
            "spanNulls": false, "stacking": {"group": "A", "mode": "none"},
            "thresholdsStyle": {"mode": "off"}
          },
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "bytes"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 24},
      "id": 7,
      "options": {
        "legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true},
        "tooltip": {"mode": "multi", "sort": "desc"}
      },
      "title": "Memory Usage (Resident)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "kubevirt_vmi_memory_resident_bytes{namespace=~\"$namespace\", name=~\"$vm\"}",
          "legendFormat": "{{namespace}}/{{name}}",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {
            "axisBorderShow": false, "axisCenteredZero": false, "axisColorMode": "text",
            "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0,
            "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none",
            "hideFrom": {"legend": false, "tooltip": false, "viz": false},
            "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5,
            "scaleDistribution": {"type": "linear"}, "showPoints": "never",
            "spanNulls": false, "stacking": {"group": "A", "mode": "none"},
            "thresholdsStyle": {"mode": "off"}
          },
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}, {"color": "red", "value": 0.9}]},
          "unit": "percentunit",
          "min": 0,
          "max": 1
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 24},
      "id": 8,
      "options": {
        "legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true},
        "tooltip": {"mode": "multi", "sort": "desc"}
      },
      "title": "Memory Utilization (%)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "kubevirt_vmi_memory_resident_bytes{namespace=~\"$namespace\", name=~\"$vm\"} / (kubevirt_vmi_memory_resident_bytes{namespace=~\"$namespace\", name=~\"$vm\"} + kubevirt_vmi_memory_available_bytes{namespace=~\"$namespace\", name=~\"$vm\"})",
          "legendFormat": "{{namespace}}/{{name}}",
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
          "custom": {
            "axisBorderShow": false, "axisCenteredZero": false, "axisColorMode": "text",
            "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0,
            "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none",
            "hideFrom": {"legend": false, "tooltip": false, "viz": false},
            "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5,
            "scaleDistribution": {"type": "linear"}, "showPoints": "never",
            "spanNulls": false, "stacking": {"group": "A", "mode": "none"},
            "thresholdsStyle": {"mode": "off"}
          },
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 33},
      "id": 9,
      "options": {
        "legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true},
        "tooltip": {"mode": "multi", "sort": "desc"}
      },
      "title": "Network Receive (RX)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "rate(kubevirt_vmi_network_receive_bytes_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])",
          "legendFormat": "{{namespace}}/{{name}} [{{interface}}]",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {
            "axisBorderShow": false, "axisCenteredZero": false, "axisColorMode": "text",
            "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0,
            "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none",
            "hideFrom": {"legend": false, "tooltip": false, "viz": false},
            "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5,
            "scaleDistribution": {"type": "linear"}, "showPoints": "never",
            "spanNulls": false, "stacking": {"group": "A", "mode": "none"},
            "thresholdsStyle": {"mode": "off"}
          },
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 33},
      "id": 10,
      "options": {
        "legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true},
        "tooltip": {"mode": "multi", "sort": "desc"}
      },
      "title": "Network Transmit (TX)",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "rate(kubevirt_vmi_network_transmit_bytes_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])",
          "legendFormat": "{{namespace}}/{{name}} [{{interface}}]",
          "refId": "A"
        }
      ]
    },
    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 41},
      "id": 105,
      "title": "Storage I/O",
      "type": "row"
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {
            "axisBorderShow": false, "axisCenteredZero": false, "axisColorMode": "text",
            "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0,
            "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none",
            "hideFrom": {"legend": false, "tooltip": false, "viz": false},
            "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5,
            "scaleDistribution": {"type": "linear"}, "showPoints": "never",
            "spanNulls": false, "stacking": {"group": "A", "mode": "none"},
            "thresholdsStyle": {"mode": "off"}
          },
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 42},
      "id": 11,
      "options": {
        "legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true},
        "tooltip": {"mode": "multi", "sort": "desc"}
      },
      "title": "Storage Read",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "rate(kubevirt_vmi_storage_read_traffic_bytes_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])",
          "legendFormat": "{{namespace}}/{{name}} [{{drive}}]",
          "refId": "A"
        }
      ]
    },
    {
      "datasource": {"type": "prometheus", "uid": "${datasource}"},
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {
            "axisBorderShow": false, "axisCenteredZero": false, "axisColorMode": "text",
            "axisLabel": "", "axisPlacement": "auto", "barAlignment": 0,
            "drawStyle": "line", "fillOpacity": 10, "gradientMode": "none",
            "hideFrom": {"legend": false, "tooltip": false, "viz": false},
            "lineInterpolation": "linear", "lineWidth": 1, "pointSize": 5,
            "scaleDistribution": {"type": "linear"}, "showPoints": "never",
            "spanNulls": false, "stacking": {"group": "A", "mode": "none"},
            "thresholdsStyle": {"mode": "off"}
          },
          "mappings": [],
          "thresholds": {"mode": "absolute", "steps": [{"color": "green", "value": null}]},
          "unit": "Bps"
        },
        "overrides": []
      },
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 42},
      "id": 12,
      "options": {
        "legend": {"calcs": ["mean", "max", "last"], "displayMode": "table", "placement": "bottom", "showLegend": true},
        "tooltip": {"mode": "multi", "sort": "desc"}
      },
      "title": "Storage Write",
      "type": "timeseries",
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "${datasource}"},
          "expr": "rate(kubevirt_vmi_storage_write_traffic_bytes_total{namespace=~\"$namespace\", name=~\"$vm\"}[5m])",
          "legendFormat": "{{namespace}}/{{name}} [{{drive}}]",
          "refId": "A"
        }
      ]
    }
  ]
}
DASHBOARD_EOF

    # Create YAML wrapper (using bash variable ${NS})
    {
        printf 'apiVersion: grafana.integreatly.org/v1beta1\n'
        printf 'kind: GrafanaDashboard\n'
        printf 'metadata:\n'
        printf '  name: poc-vm-overview\n'
        printf '  namespace: %s\n' "${NS}"
        printf '  labels:\n'
        printf '    app: poc-grafana\n'
        printf 'spec:\n'
        printf '  resyncPeriod: 5m\n'
        printf '  instanceSelector:\n'
        printf '    matchLabels:\n'
        printf '      dashboards: poc-grafana\n'
        printf '  json: |\n'
        sed 's/^/    /' ./poc-vm-dashboard.json
    } > ./poc-vm-dashboard.yaml

    oc create -f ./poc-vm-dashboard.yaml
    print_ok "GrafanaDashboard poc-vm-overview deployed"

    # Wait for Grafana Operator synchronization (up to 90 seconds)
    print_info "  Waiting for Grafana dashboard synchronization..."
    local synced=false
    for i in $(seq 1 18); do
        sleep 5
        local conditions
        conditions=$(oc get grafanadashboard poc-vm-overview -n "${NS}" -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || true)
        if echo "${conditions}" | grep -q "Synchronized"; then
            synced=true
            break
        fi
        printf "    Waiting... (%ds)\n" $((i * 5))
    done

    if [ "${synced}" = "true" ]; then
        print_ok "  Dashboard synchronization complete"
    else
        print_warn "  Synchronization could not be confirmed — check directly in Grafana (resyncPeriod: 5m)"
    fi
    print_info "  Dashboard: Grafana → Dashboards → KubeVirt VM Overall Status"
}

step_dashboard_ocpv() {
    print_step "5/5  Deploy OpenShift Virtualization dashboard (grafana-dashboard-ocp-v)"

    # Delete existing CR then recreate
    if oc get grafanadashboard grafana-dashboard-ocp-v -n "$NS" &>/dev/null; then
        print_info "GrafanaDashboard grafana-dashboard-ocp-v: deleting existing CR and recreating..."
        oc delete grafanadashboard grafana-dashboard-ocp-v -n "$NS" --wait=false 2>/dev/null || true
        sleep 2
    fi

    cat > ./grafana-dashboard-ocp-v.yaml <<EOF
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaDashboard
metadata:
  name: grafana-dashboard-ocp-v
  namespace: ${NS}
  labels:
    app: poc-grafana
spec:
  resyncPeriod: 5m
  instanceSelector:
    matchLabels:
      dashboards: poc-grafana
  url: https://raw.githubusercontent.com/leoaaraujo/articles/master/openshift-virtualization-monitoring/files/ocp-v-dashboard.json
EOF
    oc apply -f ./grafana-dashboard-ocp-v.yaml
    print_ok "GrafanaDashboard grafana-dashboard-ocp-v deployed"

    # Wait for Grafana Operator synchronization (up to 90 seconds)
    print_info "  Waiting for Grafana dashboard synchronization..."
    local synced=false
    for i in $(seq 1 18); do
        sleep 5
        local conditions
        conditions=$(oc get grafanadashboard grafana-dashboard-ocp-v -n "${NS}" -o jsonpath='{.status.conditions[*].type}' 2>/dev/null || true)
        if echo "${conditions}" | grep -q "Synchronized"; then
            synced=true
            break
        fi
        printf "    Waiting... (%ds)\n" $((i * 5))
    done

    if [ "${synced}" = "true" ]; then
        print_ok "  Dashboard synchronization complete"
    else
        print_warn "  Synchronization could not be confirmed — check directly in Grafana (resyncPeriod: 5m)"
    fi
    print_info "  Dashboard: Grafana → Dashboards → Openshift Virtualization → ocp-v"
}

print_summary() {
    local grafana_route
    grafana_route=$(oc get route poc-grafana-route -n "$NS" \
        -o jsonpath='{.spec.host}' 2>/dev/null || echo "")

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! Grafana monitoring environment is ready.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if [ -n "$grafana_route" ]; then
        echo -e "  Grafana URL  : ${CYAN}https://${grafana_route}${NC}"
        echo -e "  Credentials  : admin / ${GRAFANA_ADMIN_PASS:-grafana123}"
        echo -e "  VM Dashboard : ${CYAN}https://${grafana_route}/d/poc-vm-overview${NC}"
        echo -e "  OCP-V Dashboard: ${CYAN}https://${grafana_route}/d/ocp-v${NC}"
    else
        echo -e "  Grafana Route: ${CYAN}oc get route -n ${NS}${NC}"
    fi
    echo ""

    echo -e "  Check Pod status:"
    echo -e "    ${CYAN}oc get pods -n ${NS}${NC}"
    echo ""
    echo -e "  For details: refer to 11-grafana/11-grafana.md"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Delete 11-grafana resources"
    oc delete project poc-monitoring --ignore-not-found 2>/dev/null || true
    oc delete clusterrolebinding grafana-cluster-monitoring-view --ignore-not-found 2>/dev/null || true
    print_ok "11-grafana resources deleted"
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Grafana — OpenShift Prometheus DataSource + Dashboards${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_grafana
    step_datasource
    step_dashboard_vm
    step_dashboard_ocpv
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
