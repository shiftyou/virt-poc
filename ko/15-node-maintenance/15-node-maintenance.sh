#!/bin/bash
# =============================================================================
# 15-node-maintenance.sh
#
# 노드 유지보수 랩 환경 구성
#   1. poc-maintenance namespace 생성
#   2. poc 템플릿으로 VM 2대 배포 → Live Migration으로 TEST_NODE에 통합
#   3. NodeMaintenance 생성 → cordon + drain → VM 자동 Migration 검증
#
# 사용법: ./15-node-maintenance.sh
# =============================================================================

set -euo pipefail
POC_VERSION="v2026.09.16-1"
trap 'echo -e "\n\033[0;31m[오류]\033[0m ${LINENO}번째 줄에서 명령 실패: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# env.conf 자동 로드 (단독 실행 시)
ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-maintenance"

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
    auto_detect_operators() { :; }
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

# spec.running(deprecated) -> spec.runStrategy 마이그레이션
# oc patch vm 전에 호출하여 admission webhook 경고 제거
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
    auto_detect_operators

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

    detect_worker_nodes
    NODE1="${TEST_NODE}"
    print_ok "대상 노드: $NODE1"

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator가 설치되어 있지 않습니다 → 건너뜀."
        print_warn "  설치 가이드: operators/kubevirt-hyperconverged-operator.md"
        exit 77
    fi
    print_ok "OpenShift Virtualization Operator 확인됨"

    # Node Maintenance Operator 설치 확인 (env.conf: NMO_INSTALLED)
    if [ "${NMO_INSTALLED:-false}" != "true" ]; then
        if ! oc get csv -A 2>/dev/null | grep -qi "node-maintenance"; then
            print_warn "Node Maintenance Operator가 설치되어 있지 않습니다 → 건너뜀."
            print_warn "  설치 가이드: operators/node-maintenance-operator.md"
            exit 77
        fi
    fi
    print_ok "Node Maintenance Operator 확인됨"

    # 워커 노드 최소 2개 확인
    local worker_count
    worker_count=$(oc get node -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$worker_count" -lt 2 ]; then
        print_error "워커 노드가 최소 2개 필요합니다. (현재: ${worker_count})"
        exit 1
    fi
    print_ok "워커 노드: ${worker_count}개 확인됨"

    print_info "  NS    : ${NS}"
    print_info "  NODE1 : ${NODE1}"
}

# =============================================================================
# Step 1: namespace 생성
# =============================================================================
step_namespace() {
    print_step "1/3  namespace 생성 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "Namespace ${NS}이(가) 이미 존재합니다 — 건너뜀"
    else
        oc new-project "$NS" > /dev/null
        print_ok "Namespace $NS 생성 완료"
    fi
}

# =============================================================================
# Step 2: VM 2대 배포 → TEST_NODE로 Live Migration
# =============================================================================
step_vms() {
    print_step "2/4  VM 2대 배포 → ${NODE1}(으)로 Live Migration"

    for VM in poc-maintenance-vm-1 poc-maintenance-vm-2; do
        if oc get vm "$VM" -n "$NS" &>/dev/null; then
            print_ok "VM ${VM}이(가) 이미 존재합니다 — 건너뜀"
            continue
        fi

        oc process -n openshift poc -p NAME="$VM" | \
        sed 's/runStrategy: Always/runStrategy: Halted/' | sed 's/  running: false/  runStrategy: Halted/' > "${VM}.yaml"
        echo "생성된 파일: ${VM}.yaml"
        oc apply -n "$NS" -f "${VM}.yaml"

        # evictionStrategy: LiveMigrate 설정
        ensure_runstrategy "$VM" "$NS"
        oc patch vm "$VM" -n "$NS" --type=merge -p '{
          "spec": {
            "template": {
              "spec": {
                "evictionStrategy": "LiveMigrate"
              }
            }
          }
        }'

        virtctl start "$VM" -n "$NS" 2>/dev/null || true
        print_ok "VM $VM 배포 완료"
    done

    # Running 상태 대기
    print_info "VM Running 상태 대기 중..."
    for VM in poc-maintenance-vm-1 poc-maintenance-vm-2; do
        local retries=36
        local i=0
        while [ $i -lt $retries ]; do
            local phase
            phase=$(oc get vmi "$VM" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
            if [ "$phase" = "Running" ]; then
                print_ok "VMI $VM Running 상태"
                break
            fi
            printf "  [%d/%d] %s 대기 중... (%s)\r" "$((i+1))" "$retries" "$VM" "${phase:-Pending}"
            sleep 5
            i=$((i+1))
        done
        echo ""
    done

    # TEST_NODE로 Live Migration
    for VM in poc-maintenance-vm-1 poc-maintenance-vm-2; do
        local current_node
        current_node=$(oc get vmi "$VM" -n "$NS" -o jsonpath='{.status.nodeName}' 2>/dev/null || true)

        if [ "$current_node" = "$NODE1" ]; then
            print_ok "VM ${VM}이(가) 이미 ${NODE1}에 있습니다 — Migration 건너뜀"
            continue
        fi

        print_info "VM $VM Migration 시작: ${current_node} → ${NODE1}"

        # 임시 nodeSelector 설정
        ensure_runstrategy "$VM" "$NS"
        oc patch vm "$VM" -n "$NS" --type=merge -p "{
          \"spec\": {
            \"template\": {
              \"spec\": {
                \"nodeSelector\": {\"kubernetes.io/hostname\": \"${NODE1}\"}
              }
            }
          }
        }"

        local VMIM_NAME="migrate-${VM}-to-node1"
        cat > "vmim-${VM}.yaml" <<EOF
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceMigration
metadata:
  name: ${VMIM_NAME}
  namespace: ${NS}
spec:
  vmiName: ${VM}
EOF
        echo "생성된 파일: vmim-${VM}.yaml"
        print_info "  다음 명령어로 직접 적용하세요:"
        echo -e "    ${CYAN}oc apply -f vmim-${VM}.yaml${NC}"
    done

    echo ""
    print_info "현재 VM 배치 현황:"
    oc get vmi -n "$NS" \
      -o custom-columns=NAME:.metadata.name,NODE:.status.nodeName,PHASE:.status.phase \
      2>/dev/null || true
}

# =============================================================================
# Step 3: NodeMaintenance 생성 → Migration 검증
# =============================================================================
step_consoleyamlsamples() {
    print_step "4/4  ConsoleYAMLSample 등록"

    cat > consoleyamlsample-nodemaintenance.yaml <<'EOF'
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-nodemaintenance
spec:
  title: "POC NodeMaintenance"
  description: "Example NodeMaintenance CR for putting a node into maintenance mode. When created, the node is cordoned and VMs are automatically Live Migrated."
  targetResource:
    apiVersion: nodemaintenance.medik8s.io/v1beta1
    kind: NodeMaintenance
  yaml: |
    apiVersion: nodemaintenance.medik8s.io/v1beta1
    kind: NodeMaintenance
    metadata:
      name: maintenance-worker-0
    spec:
      nodeName: worker-0
      reason: "POC maintenance lab"
EOF
    oc apply -f consoleyamlsample-nodemaintenance.yaml
    print_ok "ConsoleYAMLSample poc-nodemaintenance 등록 완료"
}

step_maintenance() {
    print_step "3/4  NodeMaintenance 생성 (${NODE1})"

    if oc get nodemaintenance "maintenance-${NODE1}" &>/dev/null; then
        print_ok "NodeMaintenance maintenance-${NODE1}이(가) 이미 존재합니다 — 건너뜀"
        return
    fi

    cat > "nodemaintenance-${NODE1}.yaml" <<EOF
apiVersion: nodemaintenance.medik8s.io/v1beta1
kind: NodeMaintenance
metadata:
  name: maintenance-${NODE1}
spec:
  nodeName: ${NODE1}
  reason: "POC maintenance lab"
EOF
    echo "생성된 파일: nodemaintenance-${NODE1}.yaml"
    print_ok "NodeMaintenance YAML 생성 완료 (미적용)"
    print_info "다음 명령어로 직접 적용하세요:"
    echo -e "    ${CYAN}oc apply -f nodemaintenance-${NODE1}.yaml${NC}"
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! 노드 유지보수 랩 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  VM Migration 확인:"
    echo -e "    ${CYAN}oc get vmi -n ${NS} -o wide${NC}"
    echo ""
    echo -e "  NodeMaintenance 상태:"
    echo -e "    ${CYAN}oc get nodemaintenance${NC}"
    echo ""
    echo -e "  유지보수 종료 (노드 복구):"
    echo -e "    ${CYAN}oc delete nodemaintenance maintenance-${NODE1}${NC}"
    echo ""
    echo -e "  상세 내용: 15-node-maintenance/15-node-maintenance.md"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 15-node-maintenance 리소스 삭제"
    oc delete project poc-maintenance --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-nodemaintenance --ignore-not-found 2>/dev/null || true
    print_ok "15-node-maintenance 리소스 삭제 완료"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  노드 유지보수 랩 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}  virt-poc ${POC_VERSION}${NC}"

    preflight
    step_namespace
    step_vms
    step_maintenance
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
