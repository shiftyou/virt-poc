#!/bin/bash
# =============================================================================
# 10-node-exporter.sh
#
# OpenShift에 node-exporter Service 등록
#   1. poc 템플릿을 사용하여 VM 생성 (monitor=metrics 레이블 포함)
#   2. node-exporter-service.yaml 적용
#   3. ServiceMonitor (Prometheus 스크랩 구성) 등록
#   4. Endpoints 확인 안내
#
# 사용법: ./10-node-exporter.sh
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
    print_step "사전 점검"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 연결: $(oc whoami) @ $(oc whoami --show-server)"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "Namespace $NS 이미 존재합니다 — 건너뜀"
    else
        oc new-project "$NS" > /dev/null
        print_ok "Namespace $NS 생성됨"
    fi

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator가 설치되어 있지 않습니다 → 건너뜀."
        print_warn "  설치 가이드: operators/kubevirt-hyperconverged-operator.md"
        exit 77
    fi
    print_ok "OpenShift Virtualization Operator 확인됨"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_error "poc Template을 찾을 수 없습니다. 먼저 01-template을 실행하세요."
        exit 1
    fi
    print_ok "poc Template 확인됨"

    if ! command -v virtctl &>/dev/null; then
        print_error "virtctl을 찾을 수 없습니다."
        exit 1
    fi
    print_ok "virtctl 확인됨"

}

step_vm() {
    print_step "1/3  VM 생성 (${VM_NAME})"

    if oc get vm "$VM_NAME" -n "$NS" &>/dev/null; then
        print_ok "VM $VM_NAME 이미 존재합니다 — 건너뜀"
    else
        oc process -n openshift poc -p NAME="$VM_NAME" > "${VM_NAME}.yaml"
        echo "생성된 파일: ${VM_NAME}.yaml"
        oc apply -n "$NS" -f "${VM_NAME}.yaml"
        print_ok "VM $VM_NAME 생성됨"
    fi

    # virt-launcher Pod에 monitor=metrics 레이블을 전파하기 위해 spec.template.metadata.labels 설정
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
    }' 2>/dev/null && print_ok "레이블 monitor=metrics 구성됨" || true

    virtctl start "$VM_NAME" -n "$NS" 2>/dev/null || true
    print_info "VM 시작 요청됨 (Running 상태까지 시간이 걸릴 수 있습니다)"
    print_info "  ${CYAN}oc get vmi $VM_NAME -n $NS${NC}"
}

step_apply_service() {
    print_step "2/4  node-exporter Service 적용"

    # user-workload-monitoring에서 namespace를 수집하기 위한 namespace 레이블 필요
    oc label namespace "$NS" openshift.io/cluster-monitoring=true --overwrite 2>/dev/null || true
    print_ok "Namespace 모니터링 레이블 구성됨"

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
    echo "생성된 파일: vm-ne-svc.yaml"
    oc apply -f ./vm-ne-svc.yaml
    print_ok "node-exporter-service 적용됨"
}

step_service_monitor() {
    print_step "3/4  ServiceMonitor 등록"

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
    echo "생성된 파일: servicemonitor-node-exporter.yaml"
    oc apply -f servicemonitor-node-exporter.yaml
    print_ok "ServiceMonitor node-exporter-monitor 등록됨"
}

step_consoleyamlsamples() {
    print_step "5/5  ConsoleYAMLSample 등록"

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
    print_ok "ConsoleYAMLSample poc-servicemonitor-node-exporter 등록됨"
}

step_check_endpoints() {
    print_step "4/5  Endpoints 확인"

    local ep_count
    ep_count=$(oc get endpoints node-exporter-service -n "$NS" \
        -o jsonpath='{.subsets[*].addresses}' 2>/dev/null | wc -w | tr -d ' ')

    if [ "$ep_count" -gt 0 ] 2>/dev/null; then
        print_ok "Endpoints 등록됨 (${ep_count}개)"
        oc get endpoints node-exporter-service -n "$NS"
    else
        print_warn "Endpoints가 아직 사용할 수 없습니다."
        print_info "VM Pod에 레이블이 있는지 확인하세요:"
        echo -e "    ${CYAN}oc get pods -n ${NS} --show-labels | grep monitor${NC}"
        echo -e "    ${CYAN}oc label pod <pod-name> -n ${NS} monitor=metrics${NC}"
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! node-exporter Service가 등록되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  VM 상태 확인:"
    echo -e "    ${CYAN}oc get vmi ${VM_NAME} -n ${NS}${NC}"
    echo ""
    echo -e "  Service 상태 확인:"
    echo -e "    ${CYAN}oc get svc node-exporter-service -n ${NS}${NC}"
    echo ""
    echo -e "  Endpoints 확인:"
    echo -e "    ${CYAN}oc get endpoints node-exporter-service -n ${NS}${NC}"
    echo ""
    echo -e "  ServiceMonitor 확인:"
    echo -e "    ${CYAN}oc get servicemonitor -n ${NS}${NC}"
    echo ""
    echo -e "  Prometheus 스크랩 대상 확인 (user-workload):"
    echo -e "    ${CYAN}oc get pods -n openshift-user-workload-monitoring${NC}"
    echo ""
    echo -e "  PromQL 예시 (OpenShift Console → Observe → Metrics, 각 쿼리를 개별 입력):"
    echo -e "    ${CYAN}node_memory_MemAvailable_bytes${NC}"
    echo -e "    ${CYAN}rate(node_cpu_seconds_total[5m])${NC}"
    echo -e "    ${CYAN}node_load1${NC}"
    echo ""
    echo -e "  메트릭 접근 (port-forward):"
    echo -e "    ${CYAN}oc port-forward svc/node-exporter-service 9100:9100 -n ${NS}${NC}"
    echo -e "    ${CYAN}curl http://localhost:9100/metrics${NC}"
    echo ""
    echo -e "  VM에 node_exporter 설치:"
    echo -e "    ${CYAN}bash node-exporter-install.sh${NC}"
    echo ""
    echo -e "  자세한 내용: 10-node-exporter/10-node-exporter.md 참조"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 10-node-exporter 리소스 삭제"
    oc delete project poc-node-exporter --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-servicemonitor-node-exporter --ignore-not-found 2>/dev/null || true
    print_ok "10-node-exporter 리소스 삭제됨"
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Node Exporter Service 등록${NC}"
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
