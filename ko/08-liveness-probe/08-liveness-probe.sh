#!/bin/bash
# =============================================================================
# 08-liveness-probe.sh
#
# VM Liveness Probe 실습 환경 구성
#   1. poc-liveness-probe namespace 생성
#   2. poc 템플릿을 사용하여 VM 생성
#   3. VM에 HTTP Liveness Probe (포트 80) 구성
#
# 사용법: ./08-liveness-probe.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-liveness-probe"
VM_NAME="poc-liveness-vm"

source "${SCRIPT_DIR}/../utils/common.sh"

# spec.running (deprecated) -> spec.runStrategy 마이그레이션
# admission webhook 경고를 제거하기 위해 oc patch vm 전에 호출
ensure_runstrategy() {
    local vm="$1" ns="$2"
    local running
    running=$(oc get vm "$vm" -n "$ns" \
        -o jsonpath='{.spec.running}' 2>/dev/null || true)
    [ -z "$running" ] && return 0
    local rs="Halted"
    [ "$running" = "true" ] && rs="Always"
    oc patch vm "$vm" -n "$ns" --type=json -p "[
      {\"op\":\"remove\",\"path\":\"/spec/running\"},
      {\"op\":\"add\",\"path\":\"/spec/runStrategy\",\"value\":\"${rs}\"}
    ]" &>/dev/null || true
}

# =============================================================================
# 사전 점검
# =============================================================================
preflight() {
    print_step "사전 점검"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 연결: $(oc whoami) @ $(oc whoami --show-server)"

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
}

# =============================================================================
# 1단계: namespace 생성
# =============================================================================
step_namespace() {
    print_step "1/3  namespace 생성 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "Namespace $NS 이미 존재합니다 — 건너뜀"
    else
        oc new-project "$NS" > /dev/null
        print_ok "Namespace $NS 생성됨"
    fi
}

# =============================================================================
# 2단계: VM 생성 (poc 템플릿 + Liveness Probe)
# =============================================================================
step_vm() {
    print_step "2/3  VM 생성 (poc 템플릿 + HTTP Liveness Probe 포트 80)"

    if oc get vm "$VM_NAME" -n "$NS" &>/dev/null; then
        print_ok "VM $VM_NAME 이미 존재합니다 — 건너뜀"
        return
    fi

    # poc 템플릿에서 VM 생성
    oc process -n openshift poc -p NAME="$VM_NAME" | \
        sed 's/runStrategy: Always/runStrategy: Halted/' | sed 's/  running: false/  runStrategy: Halted/' > "${VM_NAME}.yaml"
    echo "생성된 파일: ${VM_NAME}.yaml"
    oc apply -n "$NS" -f "${VM_NAME}.yaml"
    print_ok "VM $VM_NAME 생성됨"

    # HTTP Liveness Probe (포트 80) 패치
    # spec.template.spec.readinessProbe / livenessProbe → KubeVirt VMI 레벨에서 지원
    ensure_runstrategy "$VM_NAME" "$NS"
    oc patch vm "$VM_NAME" -n "$NS" --type=merge -p '{
      "spec": {
        "template": {
          "spec": {
            "readinessProbe": {
              "httpGet": {
                "port": 80
              },
              "initialDelaySeconds": 120,
              "periodSeconds": 20,
              "timeoutSeconds": 10,
              "failureThreshold": 3,
              "successThreshold": 3
            },
            "livenessProbe": {
              "httpGet": {
                "port": 80
              },
              "initialDelaySeconds": 120,
              "periodSeconds": 20,
              "timeoutSeconds": 10,
              "failureThreshold": 3
            }
          }
        }
      }
    }'
    print_ok "Liveness/Readiness Probe 구성 완료 (포트 80)"
    print_info "  initialDelaySeconds: 120  (VM 부팅 시간 확보)"
    print_info "  periodSeconds      : 20"
    print_info "  failureThreshold   : 3    (3회 실패 시 VM 재시작)"

    virtctl start "$VM_NAME" -n "$NS" 2>/dev/null || true
    print_ok "VM $VM_NAME 시작됨"
}

# =============================================================================
# 3단계: Probe 검증을 위한 Service 안내
# =============================================================================
step_consoleyamlsamples() {
    print_step "4/4  ConsoleYAMLSample 등록"

    cat > consoleyamlsample-liveness-vm.yaml <<'EOF'
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-liveness-vm
spec:
  title: "POC VM Liveness/Readiness Probe"
  description: "A VirtualMachine example with HTTP Liveness/Readiness Probe configured. Performs periodic health checks on port 80, and restarts the VM after 3 consecutive failures."
  targetResource:
    apiVersion: kubevirt.io/v1
    kind: VirtualMachine
  yaml: |
    apiVersion: kubevirt.io/v1
    kind: VirtualMachine
    metadata:
      name: poc-liveness-vm
      namespace: poc-liveness-probe
    spec:
      runStrategy: Always
      template:
        spec:
          readinessProbe:
            httpGet:
              port: 80
            initialDelaySeconds: 120
            periodSeconds: 20
            timeoutSeconds: 10
            failureThreshold: 3
            successThreshold: 3
          livenessProbe:
            httpGet:
              port: 80
            initialDelaySeconds: 120
            periodSeconds: 20
            timeoutSeconds: 10
            failureThreshold: 3
          domain:
            cpu:
              cores: 1
            memory:
              guest: 2Gi
            devices:
              disks:
                - name: rootdisk
                  disk:
                    bus: virtio
          volumes:
            - name: rootdisk
              dataVolume:
                name: poc-liveness-vm
      dataVolumeTemplates:
        - metadata:
            name: poc-liveness-vm
          spec:
            pvc:
              accessModes:
                - ReadWriteMany
              resources:
                requests:
                  storage: 30Gi
            sourceRef:
              kind: DataSource
              name: poc
              namespace: openshift-virtualization-os-images
EOF
    oc apply -f consoleyamlsample-liveness-vm.yaml
    print_ok "ConsoleYAMLSample poc-liveness-vm 등록됨"
}

step_service() {
    print_step "3/4  VM 내부 httpd 포트 안내"

    print_info "KubeVirt Probe는 virt-probe를 사용하여 VMI 내부 IP에 직접 연결합니다."
    print_info "httpGet.port는 VM 내부 포트를 지정합니다 (Service 불필요)."
    echo ""
    print_info "Probe가 성공하려면 VM 내부에서 포트 80 HTTP 서버가 실행 중이어야 합니다."
    print_info "poc 골든 이미지에 httpd가 설치되어 있으면 자동으로 통과합니다."
    echo ""
    print_info "httpd가 설치되어 있지 않으면, VM에 접속한 후 간단한 서버를 실행하세요:"
    echo -e "    ${CYAN}virtctl console $VM_NAME -n $NS${NC}"
    echo -e "    ${CYAN}# VM 내부에서:${NC}"
    echo -e "    ${CYAN}nohup python3 -m http.server 80 &>/dev/null &${NC}"
    echo -e "    ${CYAN}# python3이 설치되어 있지 않은 경우: nohup nc -lk -p 80 -e /bin/echo &>/dev/null &${NC}"
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! Liveness Probe 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  VM 상태 확인:"
    echo -e "    ${CYAN}oc get vm,vmi -n ${NS}${NC}"
    echo ""
    echo -e "  Probe 상태 확인:"
    echo -e "    ${CYAN}oc get vmi $VM_NAME -n $NS -o jsonpath='{range .status.conditions[*]}{.type}: {.status}  {.message}{\"\\n\"}{end}'${NC}"
    echo ""
    echo -e "  VM 콘솔 접속:"
    echo -e "    ${CYAN}virtctl console $VM_NAME -n $NS${NC}"
    echo ""
    echo -e "  자세한 내용: ${CYAN}08-liveness-probe/08-liveness-probe.md${NC} 참조"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 08-liveness-probe 리소스 삭제"
    oc delete project poc-liveness-probe --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-liveness-vm --ignore-not-found 2>/dev/null || true
    print_ok "08-liveness-probe 리소스 삭제됨"
}

# =============================================================================
# 메인
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  VM Liveness Probe 실습 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_vm
    step_service
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
