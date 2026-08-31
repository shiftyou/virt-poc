#!/bin/bash
# =============================================================================
# 07-descheduler.sh
#
# Descheduler 실습 환경 구성
#   1. poc-descheduler namespace 생성
#   2. poc template을 사용하여 3개 VM 배포
#      - vm-1, vm-2, vm-3 : nodeSelector로 NODE1에 배치 → Running 후 nodeSelector 제거
#      - vm-fixed         : NODE1에 고정 + descheduler 축출 제외
#   3. KubeDescheduler — LifecycleAndUtilization / High / namespace 범위
#   4. TEST_NODE의 CPU/Memory 상태 분석 → trigger VM 리소스 계산
#   5. TEST_NODE에 trigger VM 배포 → 노드 임계값 초과 → Descheduler 트리거
#
# 사용법: ./07-descheduler.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# env.conf 자동 로드 (단독 실행 시)
ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-descheduler"
DESCHEDULER_NS="openshift-kube-descheduler-operator"

# 초기 VM CPU request (각 250m)
VM_CPU_REQUEST="250m"
VM_MEM_REQUEST="512Mi"

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
        print_warn "OpenShift Virtualization Operator가 설치되지 않았습니다 → 건너뜀."
        print_warn "  설치 가이드: operators/kubevirt-hyperconverged-operator.md"
        exit 77
    fi
    print_ok "OpenShift Virtualization Operator 확인됨"

    if [ "${DESCHEDULER_INSTALLED:-false}" != "true" ]; then
        print_warn "Kube Descheduler Operator가 설치되지 않았습니다 → 건너뜀."
        print_warn "  설치 가이드: operators/descheduler-operator.md"
        exit 77
    fi
    print_ok "Kube Descheduler Operator 확인됨"

    print_info "  NS    : ${NS}"
    print_info "  NODE1 : ${NODE1}"
}

# =============================================================================
# Step 1: Namespace 생성
# =============================================================================
step_namespace() {
    print_step "1/5  Namespace 생성 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "Namespace $NS 이미 존재합니다 — 건너뜀"
    else
        oc new-project "$NS" > /dev/null
        print_ok "Namespace $NS 생성됨"
    fi
}

# =============================================================================
# Step 2: 4개 VM 배포
# =============================================================================
step_vms() {
    print_step "2/5  4개 VM 배포"

    # vm-1, vm-2, vm-3: descheduler 대상 / vm-fixed: nodeSelector 고정 + 축출 제외
    for VM in poc-descheduler-vm-1 poc-descheduler-vm-2 poc-descheduler-vm-3 poc-descheduler-vm-fixed; do
        if oc get vm "$VM" -n "$NS" &>/dev/null; then
            print_ok "VM $VM 이미 존재합니다 — 건너뜀"
            continue
        fi

        # poc template에서 VM 생성
        oc process -n openshift poc -p NAME="$VM" | \
        sed 's/runStrategy: Halted/runStrategy: Always/' > "${VM}.yaml"
        echo "생성된 파일: ${VM}.yaml"
        oc apply -n "$NS" -f "${VM}.yaml"

        ensure_runstrategy "$VM" "$NS"

        if [ "$VM" = "poc-descheduler-vm-fixed" ]; then
            # vm-fixed: NODE1에 고정 + descheduler 축출 제외
            oc patch vm "$VM" -n "$NS" --type=merge -p "{
              \"spec\": {
                \"template\": {
                  \"metadata\": {
                    \"annotations\": {
                      \"descheduler.alpha.kubernetes.io/evict\": \"false\"
                    }
                  },
                  \"spec\": {
                    \"nodeSelector\": {\"kubernetes.io/hostname\": \"${NODE1}\"},
                    \"evictionStrategy\": \"LiveMigrate\"
                  }
                }
              }
            }"
            print_info "  → nodeSelector: ${NODE1} 고정, descheduler 축출 제외"
            virtctl start "$VM" -n "$NS" 2>/dev/null || true
            print_ok "VM $VM 배포됨 (nodeSelector 유지)"
            continue
        fi

        # vm-1, vm-2, vm-3: nodeSelector로 NODE1에 배치 + descheduler 축출 허용
        oc patch vm "$VM" -n "$NS" --type=merge -p "{
          \"spec\": {
            \"template\": {
              \"metadata\": {
                \"annotations\": {
                  \"descheduler.alpha.kubernetes.io/evict\": \"true\"
                }
              },
              \"spec\": {
                \"nodeSelector\": {\"kubernetes.io/hostname\": \"${NODE1}\"},
                \"evictionStrategy\": \"LiveMigrate\"
              }
            }
          }
        }"
        print_info "  → nodeSelector: ${NODE1} 설정, descheduler 축출 허용"

        virtctl start "$VM" -n "$NS" 2>/dev/null || true
        print_ok "VM $VM 배포됨"

        # Running 상태가 되면 nodeSelector 제거 (descheduler가 자유롭게 대상으로 지정 가능)
        print_info "  → Running 상태 대기 후 nodeSelector 제거 중..."
        local retries=36
        local i=0
        while [ $i -lt $retries ]; do
            local phase
            phase=$(oc get vmi "$VM" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
            if [ "$phase" = "Running" ]; then
                print_ok "  VMI $VM Running"
                break
            fi
            printf "  [%d/%d] %s 대기 중... (%s)\r" "$((i+1))" "$retries" "$VM" "${phase:-Pending}"
            sleep 5
            i=$((i+1))
        done
        echo ""
        ensure_runstrategy "$VM" "$NS"
        oc patch vm "$VM" -n "$NS" --type=merge -p '{
          "spec": {
            "template": {
              "spec": {
                "nodeSelector": null
              }
            }
          }
        }'
        print_ok "  → nodeSelector 제거됨 (descheduler가 자유롭게 대상 지정 가능)"
    done
}

# =============================================================================
# Step 3: KubeDescheduler 구성 (LifecycleAndUtilization / High / namespace 범위)
# =============================================================================
step_descheduler() {
    print_step "3/5  KubeDescheduler 구성"

    # KubeDescheduler가 이미 존재하는 경우, 이 스크립트가 생성한 것이 아님을 알림
    if oc get kubedescheduler cluster -n openshift-kube-descheduler-operator &>/dev/null; then
        print_warn "KubeDescheduler 'cluster'가 이미 존재합니다."
        print_warn "  → 기존 구성을 유지하고 poc-descheduler namespace만 추가합니다."
        oc patch kubedescheduler cluster -n openshift-kube-descheduler-operator \
            --type=json \
            -p='[{"op":"add","path":"/spec/profileCustomizations/namespaces/included/-","value":"poc-descheduler"}]' \
            2>/dev/null || true
        touch .kubedescheduler-preexisted
        print_ok "기존 KubeDescheduler에 poc-descheduler namespace 추가됨"
        return
    fi

    cat > kubedescheduler.yaml <<'EOF'
apiVersion: operator.openshift.io/v1
kind: KubeDescheduler
metadata:
  name: cluster
  namespace: openshift-kube-descheduler-operator
spec:
  mode: Automatic
  managementState: Managed
  deschedulingIntervalSeconds: 60
  profiles:
    - LifecycleAndUtilization
  profileCustomizations:
    devLowNodeUtilizationThresholds: High
    namespaces:
      included:
        - poc-descheduler
EOF
    echo "생성된 파일: kubedescheduler.yaml"
    if ! oc apply -f kubedescheduler.yaml; then
        print_error "KubeDescheduler 적용 실패"
        exit 1
    fi

    # 적용 후 상태 확인 — 모든 *Degraded 조건이 False이면 정상
    # (KubeDescheduler는 *Degraded 조건만 보고하며 Available 조건은 없음)
    print_info "KubeDescheduler 상태 확인 중..."
    local retries=12
    local i=0
    local healthy=false
    while [ $i -lt $retries ]; do
        local degraded_true
        degraded_true=$(oc get kubedescheduler cluster \
            -n "$DESCHEDULER_NS" \
            -o jsonpath='{range .status.conditions[*]}{.type}{" "}{.status}{"\n"}{end}' \
            2>/dev/null | grep -i "Degraded" | grep "True" || true)
        if [ -z "$degraded_true" ]; then
            healthy=true
            print_ok "KubeDescheduler 정상 (Degraded 조건 없음)"
            break
        fi
        printf "  [%d/%d] 대기 중...\r" "$((i+1))" "$retries"
        sleep 5
        i=$((i+1))
    done
    echo ""

    # 최종 상태 출력 (TYPE / STATUS / REASON / MESSAGE)
    echo ""
    printf "  %-30s %-8s %-20s %s\n" "TYPE" "STATUS" "REASON" "MESSAGE"
    printf "  %-30s %-8s %-20s %s\n" "------------------------------" "--------" "--------------------" "-------"
    oc get kubedescheduler cluster \
        -n "$DESCHEDULER_NS" \
        -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\t"}{.reason}{"\t"}{.message}{"\n"}{end}' \
        2>/dev/null | \
        while IFS=$'\t' read -r type status reason message; do
            printf "  %-30s %-8s %-20s %s\n" "$type" "$status" "$reason" "$message"
        done || true
    echo ""

    if [ "$healthy" != "true" ]; then
        print_warn "KubeDescheduler 준비 시간 초과. 위 상태를 확인하세요."
    fi

    print_info "  managementState: Managed"
    print_info "  Profile        : LifecycleAndUtilization"
    print_info "  임계값         : High (저사용 <40%, 과사용 >70%)"
    print_info "  간격           : 60초"
    print_info "  Namespace      : ${NS}"
}

# =============================================================================
# Step 5: 노드 리소스 분석 → trigger VM 계산 및 배포
# =============================================================================
step_trigger_vm() {
    print_step "4/5  trigger VM 배포 (노드 임계값 초과)"

    print_info "${NODE1} 리소스 상태 분석 중..."

    # Allocatable CPU → millicores
    ALLOC_CPU_RAW=$(oc get node "$NODE1" -o jsonpath='{.status.allocatable.cpu}')
    if [[ "$ALLOC_CPU_RAW" == *m ]]; then
        ALLOC_CPU="${ALLOC_CPU_RAW%m}"
    else
        ALLOC_CPU=$(awk "BEGIN{printf \"%d\", ${ALLOC_CPU_RAW}*1000}")
    fi

    # Allocatable Memory → MiB
    ALLOC_MEM_RAW=$(oc get node "$NODE1" -o jsonpath='{.status.allocatable.memory}')
    ALLOC_MEM_MIB=$(echo "$ALLOC_MEM_RAW" | awk '
        /Ki$/ { printf "%d", $0/1024; next }
        /Mi$/ { printf "%d", $0; next }
        /Gi$/ { printf "%d", $0*1024; next }
    ')

    # 노드의 현재 CPU request 합계 (millicores)
    USED_CPU=$(oc get pods --all-namespaces \
        --field-selector="spec.nodeName=${NODE1}" \
        -o jsonpath='{range .items[*].spec.containers[*]}{.resources.requests.cpu}{"\n"}{end}' \
        2>/dev/null | awk '
        /^[0-9]+m$/ { sum += substr($0,1,length($0)-1); next }
        /^[0-9]+(\.[0-9]+)?$/ { sum += $0*1000; next }
        END { print int(sum) }')

    # 노드의 현재 Memory request 합계 (MiB)
    USED_MEM_MIB=$(oc get pods --all-namespaces \
        --field-selector="spec.nodeName=${NODE1}" \
        -o jsonpath='{range .items[*].spec.containers[*]}{.resources.requests.memory}{"\n"}{end}' \
        2>/dev/null | awk '
        /^[0-9]+Ki$/ { sum += substr($0,1,length($0)-2)/1024; next }
        /^[0-9]+Mi$/ { sum += substr($0,1,length($0)-2); next }
        /^[0-9]+Gi$/ { sum += substr($0,1,length($0)-2)*1024; next }
        /^[0-9]+$/ { sum += $0/1048576; next }
        END { print int(sum) }')

    CPU_PCT=$((USED_CPU * 100 / ALLOC_CPU))
    MEM_PCT=$((USED_MEM_MIB * 100 / ALLOC_MEM_MIB))

    print_info "  할당 가능 CPU  : ${ALLOC_CPU}m"
    print_info "  할당 가능 Mem  : ${ALLOC_MEM_MIB}Mi"
    print_info "  사용 중 CPU request: ${USED_CPU}m  (${CPU_PCT}%)"
    print_info "  사용 중 Mem request: ${USED_MEM_MIB}Mi (${MEM_PCT}%)"
    print_info "  Descheduler 임계값: 과사용 > 70%"

    # 71%를 초과하기 위해 필요한 추가 CPU request 계산
    THRESHOLD_CPU=$((ALLOC_CPU * 71 / 100))
    NEEDED_CPU=$((THRESHOLD_CPU - USED_CPU))

    THRESHOLD_MEM=$((ALLOC_MEM_MIB * 71 / 100))
    NEEDED_MEM=$((THRESHOLD_MEM - USED_MEM_MIB))

    if [ "$NEEDED_CPU" -le 0 ]; then
        print_warn "이미 CPU 71%를 초과했습니다 — 소형 trigger VM을 배포합니다"
        TRIGGER_CPU="250m"
    else
        TRIGGER_CPU="${NEEDED_CPU}m"
    fi

    if [ "$NEEDED_MEM" -le 0 ]; then
        TRIGGER_MEM="256Mi"
    else
        TRIGGER_MEM="${NEEDED_MEM}Mi"
    fi

    print_ok "trigger VM 리소스 계산됨"
    print_info "  TRIGGER_CPU : ${TRIGGER_CPU}  (노드 ${NODE1} CPU를 71% 이상으로)"
    print_info "  TRIGGER_MEM : ${TRIGGER_MEM}"

    local TRIGGER_YAML="${SCRIPT_DIR}/poc-descheduler-vm-trigger.yaml"
    local TRIGGER_BASE="${SCRIPT_DIR}/poc-descheduler-vm-trigger-base.yaml"

    # 기본 yaml 생성 (클러스터에 적용하지 않음)
    oc process -n openshift poc -p NAME="poc-descheduler-vm-trigger" | \
        sed 's/runStrategy: Halted/runStrategy: Always/' > "${TRIGGER_BASE}"

    # nodeSelector + evictionStrategy + resources를 dry-run으로 병합 → 최종 yaml 저장
    oc patch -f "${TRIGGER_BASE}" --dry-run=client --type=merge \
        -p "{
          \"spec\": {
            \"template\": {
              \"spec\": {
                \"nodeSelector\": {\"kubernetes.io/hostname\": \"${NODE1}\"},
                \"evictionStrategy\": \"LiveMigrate\",
                \"domain\": {
                  \"resources\": {
                    \"requests\": {
                      \"cpu\": \"${TRIGGER_CPU}\",
                      \"memory\": \"${TRIGGER_MEM}\"
                    }
                  }
                }
              }
            }
          }
        }" -o yaml > "${TRIGGER_YAML}" 2>/dev/null || mv "${TRIGGER_BASE}" "${TRIGGER_YAML}"

    rm -f "${TRIGGER_BASE}"
    echo "생성된 파일: ${TRIGGER_YAML}"
    print_ok "trigger VM yaml 저장됨 — 준비가 되면 수동으로 적용하세요:"
    print_info "  oc apply -n ${NS} -f ${TRIGGER_YAML}"
    print_info "  virtctl start poc-descheduler-vm-trigger -n ${NS}"
}

# =============================================================================
# Step 5: ConsoleYAMLSample 등록
# =============================================================================
step_consoleyamlsamples() {
    print_step "5/5  ConsoleYAMLSample 등록"

    cat > consoleyamlsample-kubedescheduler.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-kubedescheduler
spec:
  title: "POC KubeDescheduler Configuration"
  description: "Automatically relocates VMs from overloaded nodes using the LifecycleAndUtilization profile. High threshold: underutilized<40%, overutilized>70%. Apply after installing the Kube Descheduler Operator."
  targetResource:
    apiVersion: operator.openshift.io/v1
    kind: KubeDescheduler
  yaml: |
    apiVersion: operator.openshift.io/v1
    kind: KubeDescheduler
    metadata:
      name: cluster
      namespace: openshift-kube-descheduler-operator
    spec:
      managementState: Managed
      deschedulingIntervalSeconds: 60
      profiles:
        - LifecycleAndUtilization
      profileCustomizations:
        devLowNodeUtilizationThresholds: High
        namespaces:
          included:
            - ${NS}    # 대상 namespace로 변경
EOF
    echo "생성된 파일: consoleyamlsample-kubedescheduler.yaml"
    oc apply -f consoleyamlsample-kubedescheduler.yaml
    print_ok "ConsoleYAMLSample poc-kubedescheduler 등록됨"
}

# =============================================================================
# 완료 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! Descheduler 실습 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  VM 노드 배치 확인:"
    echo -e "    ${CYAN}oc get vmi -n ${NS} -o wide${NC}"
    echo ""
    echo -e "  Descheduler 동작 확인 (60초 후):"
    echo -e "    ${CYAN}oc get vmi -n ${NS} -o wide --watch${NC}"
    echo ""
    echo -e "  trigger VM 수동 적용 (준비가 되면):"
    echo -e "    ${CYAN}oc apply -n ${NS} -f ${SCRIPT_DIR}/poc-descheduler-vm-trigger.yaml${NC}"
    echo -e "    ${CYAN}virtctl start poc-descheduler-vm-trigger -n ${NS}${NC}"
    echo ""
    echo -e "  예상 결과 (trigger VM 적용 후 60초 이내):"
    echo -e "    poc-descheduler-vm-1       → 다른 노드로 마이그레이션됨"
    echo -e "    poc-descheduler-vm-2       → 다른 노드로 마이그레이션됨"
    echo -e "    poc-descheduler-vm-3       → 다른 노드로 마이그레이션됨"
    echo -e "    poc-descheduler-vm-fixed   → ${NODE1}에 유지 (축출 제외)"
    echo -e "    poc-descheduler-vm-trigger → ${NODE1}에 유지 (가장 최근 배포)"
    echo ""
    echo -e "  자세한 내용: 07-descheduler/07-descheduler.md 참조"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 07-descheduler 리소스 삭제"
    oc delete project poc-descheduler --ignore-not-found 2>/dev/null || true

    local _pre="${SCRIPT_DIR}/.kubedescheduler-preexisted"
    if [ -f "$_pre" ]; then
        # 이 스크립트 실행 전에 이미 존재했음 — poc-descheduler 항목만 제거
        print_info "KubeDescheduler가 기존에 존재했습니다 — 삭제하지 않습니다."
        print_info "  → poc-descheduler namespace 항목만 제거합니다."
        local _idx
        _idx=$(oc get kubedescheduler cluster -n openshift-kube-descheduler-operator \
            -o json 2>/dev/null | \
            python3 -c "import json,sys; d=json.load(sys.stdin); \
                ns=d['spec'].get('profileCustomizations',{}).get('namespaces',{}).get('included',[]); \
                print(ns.index('poc-descheduler') if 'poc-descheduler' in ns else -1)" 2>/dev/null || echo -1)
        if [ "$_idx" != "-1" ] && [ "$_idx" != "" ]; then
            oc patch kubedescheduler cluster -n openshift-kube-descheduler-operator \
                --type=json \
                -p="[{\"op\":\"remove\",\"path\":\"/spec/profileCustomizations/namespaces/included/${_idx}\"}]" \
                2>/dev/null && print_ok "poc-descheduler 항목 제거됨" || true
        fi
        rm -f "$_pre"
    else
        oc delete kubedescheduler cluster -n openshift-kube-descheduler-operator --ignore-not-found 2>/dev/null || true
    fi

    oc delete consoleyamlsample poc-kubedescheduler --ignore-not-found 2>/dev/null || true
    print_ok "07-descheduler 리소스 삭제됨"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Descheduler 실습 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_vms
    step_descheduler
    step_trigger_vm
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
