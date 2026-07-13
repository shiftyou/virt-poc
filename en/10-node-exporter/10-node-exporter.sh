#!/bin/bash
# =============================================================================
# 10-node-exporter.sh
#
# Register node-exporter Service in OpenShift
#   1. Create VM using poc template (with monitor=metrics label)
#   2. Apply node-exporter-service.yaml
#   3. Register ServiceMonitor (Prometheus scrape configuration)
#   4. Guidance for checking Endpoints
#
# Usage: ./10-node-exporter.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-node-exporter"
VM_NAME="poc-node-exporter-vm"

source "${SCRIPT_DIR}/../utils/common.sh"

preflight() {
    print_step "Pre-flight checks"

    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift."
        exit 1
    fi
    print_ok "Cluster connection: $(oc whoami) @ $(oc whoami --show-server)"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "Namespace $NS already exists — skipping"
    else
        oc new-project "$NS" > /dev/null
        print_ok "Namespace $NS created"
    fi

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator not installed → skipping."
        print_warn "  Installation guide: operators/kubevirt-hyperconverged-operator.md"
        exit 77
    fi
    print_ok "OpenShift Virtualization Operator confirmed"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_error "poc Template not found. Run 01-template first."
        exit 1
    fi
    print_ok "poc Template confirmed"

    if ! command -v virtctl &>/dev/null; then
        print_error "virtctl not found."
        exit 1
    fi
    print_ok "virtctl confirmed"

}

step_vm() {
    print_step "1/3  Create VM (${VM_NAME})"

    if oc get vm "$VM_NAME" -n "$NS" &>/dev/null; then
        print_ok "VM $VM_NAME already exists — skipping"
    else
        oc process -n openshift poc -p NAME="$VM_NAME" > "${VM_NAME}.yaml"
        echo "Generated file: ${VM_NAME}.yaml"
        oc apply -n "$NS" -f "${VM_NAME}.yaml"
        print_ok "VM $VM_NAME created"
    fi

    # Set spec.template.metadata.labels to propagate monitor=metrics label to virt-launcher Pod
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
    }' 2>/dev/null && print_ok "Label monitor=metrics configured" || true

    virtctl start "$VM_NAME" -n "$NS" 2>/dev/null || true
    print_info "VM start requested (may take time to reach Running state)"
    print_info "  ${CYAN}oc get vmi $VM_NAME -n $NS${NC}"
}

step_apply_service() {
    print_step "2/4  Apply node-exporter Service"

    # Namespace label required for user-workload-monitoring to collect the namespace
    oc label namespace "$NS" openshift.io/cluster-monitoring=true --overwrite 2>/dev/null || true
    print_ok "Namespace monitoring label configured"

    cat > ./vm-ne-svc.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: node-exporter-service
  namespace: ${NS}
  labels:
    monitor: metrics
spec:
  selector:
    monitor: metrics
  ports:
    - name: metrics
      port: 9100
      targetPort: 9100
      protocol: TCP
EOF
    echo "Generated file: vm-ne-svc.yaml"
    oc apply -f ./vm-ne-svc.yaml
    print_ok "node-exporter-service applied"
}

step_service_monitor() {
    print_step "3/4  Register ServiceMonitor"

    cat > servicemonitor-node-exporter.yaml <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: node-exporter-monitor
  namespace: ${NS}
  labels:
    monitor: metrics
spec:
  selector:
    matchLabels:
      monitor: metrics
  endpoints:
    - port: metrics
      interval: 30s
      path: /metrics
      relabelings:
        - targetLabel: job
          replacement: vm_prometheus-metric
        - sourceLabels: [__meta_kubernetes_endpoint_hostname]
          targetLabel: vmname
        - sourceLabels: [__address__]
          targetLabel: instance
EOF
    echo "Generated file: servicemonitor-node-exporter.yaml"
    oc apply -f servicemonitor-node-exporter.yaml
    print_ok "ServiceMonitor node-exporter-monitor registered"
}

step_consoleyamlsamples() {
    print_step "5/5  Register ConsoleYAMLSample"

    cat > consoleyamlsample-servicemonitor.yaml <<'EOF'
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-servicemonitor-node-exporter
spec:
  title: "POC ServiceMonitor node-exporter"
  description: "A ServiceMonitor example for registering so that Prometheus can collect node_exporter metrics from inside a VM. Automatically scrapes Services with the servicetype=metrics label."
  targetResource:
    apiVersion: monitoring.coreos.com/v1
    kind: ServiceMonitor
  yaml: |
    apiVersion: monitoring.coreos.com/v1
    kind: ServiceMonitor
    metadata:
      name: node-exporter-monitor
      namespace: poc-node-exporter
      labels:
        servicetype: metrics
    spec:
      selector:
        matchLabels:
          servicetype: metrics
      endpoints:
        - port: metric
          interval: 30s
          path: /metrics
          relabelings:
            - targetLabel: job
              replacement: vm_prometheus-metric
            - sourceLabels: [__meta_kubernetes_endpoint_hostname]
              targetLabel: vmname
            - sourceLabels: [__address__]
              targetLabel: instance
EOF
    oc apply -f consoleyamlsample-servicemonitor.yaml
    print_ok "ConsoleYAMLSample poc-servicemonitor-node-exporter registered"
}

step_check_endpoints() {
    print_step "4/5  Check Endpoints"

    local ep_count
    ep_count=$(oc get endpoints node-exporter-service -n "$NS" \
        -o jsonpath='{.subsets[*].addresses}' 2>/dev/null | wc -w | tr -d ' ')

    if [ "$ep_count" -gt 0 ] 2>/dev/null; then
        print_ok "Endpoints registered (${ep_count})"
        oc get endpoints node-exporter-service -n "$NS"
    else
        print_warn "Endpoints not yet available."
        print_info "Check if the VM Pod has the label:"
        echo -e "    ${CYAN}oc get pods -n ${NS} --show-labels | grep monitor${NC}"
        echo -e "    ${CYAN}oc label pod <pod-name> -n ${NS} monitor=metrics${NC}"
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! node-exporter Service has been registered.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Check VM status:"
    echo -e "    ${CYAN}oc get vmi ${VM_NAME} -n ${NS}${NC}"
    echo ""
    echo -e "  Check Service status:"
    echo -e "    ${CYAN}oc get svc node-exporter-service -n ${NS}${NC}"
    echo ""
    echo -e "  Check Endpoints:"
    echo -e "    ${CYAN}oc get endpoints node-exporter-service -n ${NS}${NC}"
    echo ""
    echo -e "  Check ServiceMonitor:"
    echo -e "    ${CYAN}oc get servicemonitor -n ${NS}${NC}"
    echo ""
    echo -e "  Check Prometheus scrape targets (user-workload):"
    echo -e "    ${CYAN}oc get pods -n openshift-user-workload-monitoring${NC}"
    echo ""
    echo -e "  PromQL examples (OpenShift Console → Observe → Metrics, enter each query separately):"
    echo -e "    ${CYAN}node_memory_MemAvailable_bytes${NC}"
    echo -e "    ${CYAN}rate(node_cpu_seconds_total[5m])${NC}"
    echo -e "    ${CYAN}node_load1${NC}"
    echo ""
    echo -e "  Access metrics (port-forward):"
    echo -e "    ${CYAN}oc port-forward svc/node-exporter-service 9100:9100 -n ${NS}${NC}"
    echo -e "    ${CYAN}curl http://localhost:9100/metrics${NC}"
    echo ""
    echo -e "  Install node_exporter on VM:"
    echo -e "    ${CYAN}bash node-exporter-install.sh${NC}"
    echo ""
    echo -e "  For details: refer to 10-node-exporter/10-node-exporter.md"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Delete 10-node-exporter resources"
    oc delete project poc-node-exporter --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-servicemonitor-node-exporter --ignore-not-found 2>/dev/null || true
    print_ok "10-node-exporter resources deleted"
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Register Node Exporter Service${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_vm
    step_apply_service
    step_service_monitor
    step_consoleyamlsamples
    step_check_endpoints
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
