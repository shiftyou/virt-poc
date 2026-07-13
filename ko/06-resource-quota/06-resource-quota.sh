#!/bin/bash
# =============================================================================
# 06-resource-quota.sh
#
# ResourceQuota 실습 환경 구성
#   1. poc-resource-quota namespace 생성
#   2. CPU / Memory / Pod / PVC 등 ResourceQuota 적용
#   3. 2개 VM 배포 (Quota 내 통과) → 3번째 VM 생성 시도 → Quota 초과로 거부
#
# 사용법: ./06-resource-quota.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# env.conf 자동 로드 (단독 실행 시)
ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-resource-quota"

# VM 리소스: 750m / 1500m 각각 → 2개 VM=1500m (통과), 3개 VM=2250m (초과)
VM_CPU_REQUEST="750m"
VM_CPU_LIMIT="1500m"
VM_MEM_REQUEST="1Gi"
VM_MEM_LIMIT="2Gi"

source "${SCRIPT_DIR}/../utils/common.sh"

# spec.running (deprecated) -> spec.runStrategy 마이그레이션
# admission webhook 경고 제거를 위해 oc patch vm 전에 호출
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

    # OpenShift Virtualization Operator 확인
    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator가 설치되지 않았습니다 → 건너뜀."
        print_warn "  설치 가이드: operators/kubevirt-hyperconverged-operator.md"
        exit 77
    fi

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 연결: $(oc whoami) @ $(oc whoami --show-server)"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_error "poc Template을 찾을 수 없습니다. 먼저 01-template을 실행하세요."
        exit 1
    fi
    print_ok "poc Template 확인됨"

    print_info "  NS : ${NS}"
}

# =============================================================================
# Step 1: Namespace 생성
# =============================================================================
step_namespace() {
    print_step "1/4  Namespace 생성 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "Namespace $NS 이미 존재합니다 — 건너뜀"
    else
        oc new-project "$NS" > /dev/null
        print_ok "Namespace $NS 생성됨"
    fi
}

# =============================================================================
# Step 2: ResourceQuota 적용
#   requests.cpu: "2" → 2개 VM (각 750m=1500m) 통과, 3번째 (2250m) 초과
# =============================================================================
step_quota() {
    print_step "2/4  ResourceQuota 적용 (${NS})"

    cat > resourcequota-poc.yaml <<'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: poc-quota
  namespace: poc-resource-quota
spec:
  hard:
    # Pod 수
    pods: "10"
    # CPU — requests.cpu: "2" → 2개 VM 각 750m (1500m) 통과, 3개 VM (2250m) 초과
    requests.cpu: "2"
    limits.cpu: "4"
    # Memory
    requests.memory: 4Gi
    limits.memory: 8Gi
    # PersistentVolumeClaim 수 및 용량
    persistentvolumeclaims: "10"
    requests.storage: 100Gi
    # Service
    services: "10"
    services.loadbalancers: "2"
    services.nodeports: "0"
    # ConfigMap / Secret
    configmaps: "20"
    secrets: "20"
EOF
    echo "생성된 파일: resourcequota-poc.yaml"
    oc apply -f resourcequota-poc.yaml

    print_ok "ResourceQuota poc-quota 적용됨"
    print_info "  requests.cpu 제한: 2 core (2개 VM x 750m=1500m 통과, 3개 VM=2250m 초과)"
}

# =============================================================================
# Step 3: ConsoleYAMLSample 등록
# =============================================================================
step_consoleyamlsamples() {
    print_step "3/4  ConsoleYAMLSample 등록"

    cat > consoleyamlsample-resourcequota.yaml <<'EOF'
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-resource-quota
spec:
  title: "POC ResourceQuota Configuration"
  description: "Limits resource usage such as CPU, Memory, Pod, and PVC in a namespace. Apply after creating the namespace. New resource creation is rejected when limits are exceeded."
  targetResource:
    apiVersion: v1
    kind: ResourceQuota
  yaml: |
    apiVersion: v1
    kind: ResourceQuota
    metadata:
      name: poc-quota
      namespace: poc-resource-quota    # Change to target namespace
    spec:
      hard:
        pods: "10"
        requests.cpu: "2"
        limits.cpu: "4"
        requests.memory: 4Gi
        limits.memory: 8Gi
        persistentvolumeclaims: "10"
        requests.storage: 100Gi
        services: "10"
        services.loadbalancers: "2"
        services.nodeports: "0"
        configmaps: "20"
        secrets: "20"
EOF
    echo "생성된 파일: consoleyamlsample-resourcequota.yaml"
    oc apply -f consoleyamlsample-resourcequota.yaml
    print_ok "ConsoleYAMLSample poc-resource-quota 등록됨"
}

# =============================================================================
# Step 4: VM 배포 및 Quota 초과 시연
#   - poc-quota-vm-1, poc-quota-vm-2: 생성 성공 (requests.cpu 합계 1500m < 2000m)
#   - poc-quota-vm-3: 생성 시도 → Quota 초과로 거부 (2250m > 2000m)
# =============================================================================
step_vms() {
    print_step "4/4  VM 배포 및 ResourceQuota 초과 시연"

    # VM 1, 2: 정상 생성
    for VM in poc-quota-vm-1 poc-quota-vm-2; do
        if oc get vm "$VM" -n "$NS" &>/dev/null; then
            print_ok "VM $VM 이미 존재합니다 — 건너뜀"
            continue
        fi

        oc process -n openshift poc -p NAME="$VM" | \
        sed 's/runStrategy: Always/runStrategy: Halted/' | sed 's/  running: false/  runStrategy: Halted/' > "${VM}.yaml"
        echo "생성된 파일: ${VM}.yaml"
        oc apply -n "$NS" -f "${VM}.yaml"

        ensure_runstrategy "$VM" "$NS"
        oc patch vm "$VM" -n "$NS" --type=merge -p "{
          \"spec\": {
            \"template\": {
              \"spec\": {
                \"evictionStrategy\": \"LiveMigrate\",
                \"domain\": {
                  \"resources\": {
                    \"requests\": {
                      \"cpu\": \"${VM_CPU_REQUEST}\",
                      \"memory\": \"${VM_MEM_REQUEST}\"
                    },
                    \"limits\": {
                      \"cpu\": \"${VM_CPU_LIMIT}\",
                      \"memory\": \"${VM_MEM_LIMIT}\"
                    }
                  }
                }
              }
            }
          }
        }"

        virtctl start "$VM" -n "$NS" 2>/dev/null || true
        print_ok "VM $VM 생성됨 (cpu request: ${VM_CPU_REQUEST})"
    done

    # VM 3: Quota 초과 시연
    VM3="poc-quota-vm-3"
    if oc get vm "$VM3" -n "$NS" &>/dev/null; then
        print_warn "VM $VM3 이미 존재합니다 — Quota 초과 시연을 건너뜁니다"
        return
    fi

    print_info ""
    print_info "━━━ Quota 초과 시연 ━━━"
    print_info "현재 requests.cpu 사용량: $(oc get resourcequota poc-quota -n "$NS" \
        -o jsonpath='{.status.used.requests\.cpu}' 2>/dev/null || echo '?') / 2"
    print_info "VM $VM3 생성 시도 (requests.cpu ${VM_CPU_REQUEST} 추가 → 초과 예상)"

    oc process -n openshift poc -p NAME="$VM3" | \
        sed 's/runStrategy: Always/runStrategy: Halted/' | sed 's/  running: false/  runStrategy: Halted/' > "${VM3}.yaml"
    echo "생성된 파일: ${VM3}.yaml"

    # Quota 초과는 virt-launcher Pod 생성 시 발생 → VM 오브젝트는 생성되지만 Pod 시작 불가
    oc apply -n "$NS" -f "${VM3}.yaml"

    ensure_runstrategy "$VM3" "$NS"
    oc patch vm "$VM3" -n "$NS" --type=merge -p "{
      \"spec\": {
        \"template\": {
          \"spec\": {
            \"evictionStrategy\": \"LiveMigrate\",
            \"domain\": {
              \"resources\": {
                \"requests\": {
                  \"cpu\": \"${VM_CPU_REQUEST}\",
                  \"memory\": \"${VM_MEM_REQUEST}\"
                },
                \"limits\": {
                  \"cpu\": \"${VM_CPU_LIMIT}\",
                  \"memory\": \"${VM_MEM_LIMIT}\"
                }
              }
            }
          }
        }
      }
    }"

    virtctl start "$VM3" -n "$NS" 2>/dev/null || true

    print_warn "VM $VM3 오브젝트 생성됨 — 시작 시 Quota 초과로 virt-launcher Pod가 거부됩니다."
    print_info "  확인: oc get events -n ${NS} --field-selector reason=FailedCreate"
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! ResourceQuota 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ResourceQuota 상태:"
    echo -e "    ${CYAN}oc describe resourcequota poc-quota -n ${NS}${NC}"
    echo ""
    echo -e "  VM 상태:"
    echo -e "    ${CYAN}oc get vm -n ${NS}${NC}"
    echo ""
    echo -e "  Quota 초과 이벤트 확인:"
    echo -e "    ${CYAN}oc get events -n ${NS} --field-selector reason=FailedCreate${NC}"
    echo ""
    echo -e "  예상 결과:"
    echo -e "    poc-quota-vm-1  → Running  (cpu request: ${VM_CPU_REQUEST})"
    echo -e "    poc-quota-vm-2  → Running  (cpu request: ${VM_CPU_REQUEST})"
    echo -e "    poc-quota-vm-3  → Pending  (Quota 초과로 virt-launcher Pod 거부됨)"
    echo ""
    echo -e "  자세한 내용: 06-resource-quota/06-resource-quota.md 참조"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 06-resource-quota 리소스 삭제"
    oc delete project poc-resource-quota --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-resource-quota --ignore-not-found 2>/dev/null || true
    print_ok "06-resource-quota 리소스 삭제됨"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  ResourceQuota 실습 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_quota
    step_consoleyamlsamples
    step_vms
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
