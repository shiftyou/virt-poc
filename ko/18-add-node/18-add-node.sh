#!/bin/bash
# =============================================================================
# 18-add-node.sh
#
# 워커 노드 제거 및 재합류 랩
#   1. 대상 노드 식별 (마지막 워커 노드)
#   2. Cordon + Drain (VM 포함)
#   3. kubelet 중지 → Node NotReady → Node 객체 삭제
#   4. kubelet 재시작 → CSR 승인 → 노드 재합류 확인
#   5. Uncordon + 최종 상태 검증
#
# 사용법: ./18-add-node.sh
# =============================================================================

set -euo pipefail
POC_VERSION="v2026.09.16-1"
trap 'echo -e "\n\033[0;31m[오류]\033[0m ${LINENO}번째 줄에서 명령 실패: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

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

TARGET_NODE=""

# =============================================================================
preflight() {
    print_step "사전 점검"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 접근: $(oc whoami) @ $(oc whoami --show-server)"

    local worker_count
    worker_count=$(oc get nodes -l node-role.kubernetes.io/worker \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [ "$worker_count" -lt 2 ]; then
        print_error "워커 노드가 최소 2개 필요합니다. (현재: ${worker_count})"
        print_info "노드 제거 시 나머지 워크로드를 수용할 노드가 있어야 합니다."
        exit 1
    fi
    print_ok "워커 노드 ${worker_count}개 확인됨"
}

# =============================================================================
step_identify() {
    print_step "1/5  노드 상태 확인"

    echo ""
    oc get nodes -o wide
    echo ""

    print_warn "워커 노드를 클러스터에서 제거한 후 kubelet 재시작으로 재합류시킵니다."
    echo ""
    read -r -p "  계속하시겠습니까? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "취소되었습니다."
        exit 0
    fi

    # 워커 노드 목록 표시 및 선택 프롬프트
    local workers
    workers=()
    while IFS= read -r line; do
        workers+=("$line")
    done < <(oc get nodes -l node-role.kubernetes.io/worker \
        --no-headers -o custom-columns=NAME:.metadata.name | sort)

    echo ""
    print_info "워커 노드 목록:"
    echo ""
    local idx=1
    for node in "${workers[@]}"; do
        local node_status
        node_status=$(oc get node "$node" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
        [ "$node_status" = "True" ] && node_status="${GREEN}Ready${NC}" || node_status="${YELLOW}NotReady${NC}"
        printf "    ${CYAN}[%d]${NC}  %-40s  " "$idx" "$node"
        echo -e "$node_status"
        idx=$((idx+1))
    done
    echo ""

    local choice
    read -r -p "  제거할 노드 번호를 선택하세요 [1-${#workers[@]}]: " choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#workers[@]}" ]; then
        print_error "잘못된 선택: ${choice}"
        exit 1
    fi

    TARGET_NODE="${workers[$((choice-1))]}"
    print_ok "선택된 대상 노드: ${TARGET_NODE}"

    local node_ip
    node_ip=$(oc get node "$TARGET_NODE" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

    print_info "대상 노드 : ${TARGET_NODE}"
    print_info "노드 IP   : ${node_ip}"
    print_info "SSH 접근  : ssh core@${node_ip}"
}

# =============================================================================
step_drain() {
    print_step "2/5  Cordon + Drain (${TARGET_NODE})"

    print_info "노드를 스케줄 불가 상태로 변경 중..."
    oc adm cordon "$TARGET_NODE"
    print_ok "Cordon 완료"

    print_info "노드의 Pod/VM을 다른 노드로 이동 중..."
    oc adm drain "$TARGET_NODE" \
        --delete-emptydir-data \
        --ignore-daemonsets \
        --force \
        --timeout=300s
    print_ok "Drain 완료"

    echo ""
    oc get nodes
}

# =============================================================================
step_stop_kubelet() {
    print_step "3/5  kubelet 중지 → Node 객체 삭제"

    local node_ip
    node_ip=$(oc get node "$TARGET_NODE" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

    echo ""
    print_info "다음 명령어를 노드에서 실행하여 kubelet을 중지하세요:"
    echo ""
    echo -e "  ${CYAN}ssh core@${node_ip}${NC}"
    echo -e "  ${CYAN}sudo systemctl stop kubelet${NC}"
    echo ""
    print_warn "kubelet을 중지하면 노드가 NotReady 상태로 전환됩니다."
    echo ""
    read -r -p "  kubelet 중지 완료 후 Enter를 누르세요..."

    # NotReady 대기
    print_info "노드가 NotReady 상태로 전환되기를 대기 중..."
    local retries=30
    local i=0
    while [ "$i" -lt "$retries" ]; do
        local status
        status=$(oc get node "$TARGET_NODE" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "$status" = "False" ] || [ "$status" = "Unknown" ]; then
            echo ""
            print_ok "Node ${TARGET_NODE} → NotReady"
            break
        fi
        printf "  대기 중... (%d/%d)\r" "$((i+1))" "$retries"
        sleep 5
        i=$((i+1))
    done
    echo ""

    oc get nodes
    echo ""

    # Node 객체 삭제
    print_info "클러스터에서 Node 객체를 삭제 중..."
    oc delete node "$TARGET_NODE"
    print_ok "Node 객체 삭제 완료 — 클러스터에서 제거됨"
    echo ""
    oc get nodes
}

# =============================================================================
step_start_kubelet() {
    print_step "4/5  kubelet 재시작 → 노드 재합류"

    local node_ip
    # Node 객체가 삭제되었으므로 이전에 저장한 IP 재사용
    node_ip=$(oc get node "$TARGET_NODE" \
        -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null \
        || echo "<node-ip>")

    echo ""
    print_info "다음 명령어를 노드에서 실행하여 kubelet을 재시작하세요:"
    echo ""
    echo -e "  ${CYAN}ssh core@${node_ip:-<node-ip>}${NC}"
    echo -e "  ${CYAN}sudo systemctl start kubelet${NC}"
    echo ""
    print_info "kubelet이 시작되면 기존 인증서를 사용하여 API 서버에 재등록됩니다."
    print_info "CSR (Certificate Signing Request)이 생성되면 수동으로 승인해야 합니다."
    echo ""
    read -r -p "  kubelet 시작 완료 후 Enter를 누르세요..."

    # 수동 CSR 승인 안내 (최대 3분 대기)
    print_info "CSR 생성 및 노드 재합류 대기 중 (최대 3분)..."
    local retries=36
    local i=0
    local last_pending=""
    while [ "$i" -lt "$retries" ]; do
        local pending_csrs
        pending_csrs=$(oc get csr --no-headers 2>/dev/null \
            | awk '$4 ~ /Pending/ || $NF ~ /Pending/ {print $1}' \
            | tr '\n' ' ' | xargs || true)

        # 새로운 Pending CSR이 나타났을 때만 안내 표시
        if [ -n "$pending_csrs" ] && [ "$pending_csrs" != "$last_pending" ]; then
            echo ""
            print_warn "승인 대기 중인 CSR이 있습니다:"
            echo ""
            oc get csr
            echo ""
            print_info "다음 명령어로 CSR을 승인하세요:"
            echo ""
            echo -e "  ${CYAN}oc adm certificate approve ${pending_csrs}${NC}"
            echo ""
            echo -e "  또는 모든 Pending을 한 번에 승인:"
            echo -e "  ${CYAN}oc get csr -o name | xargs oc adm certificate approve${NC}"
            echo ""
            read -r -p "  CSR 승인 후 Enter를 누르세요..."
            last_pending="$pending_csrs"
        fi

        # 노드가 Ready 상태인지 확인
        if oc get node "$TARGET_NODE" &>/dev/null; then
            local status
            status=$(oc get node "$TARGET_NODE" \
                -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
            if [ "$status" = "True" ]; then
                echo ""
                print_ok "Node ${TARGET_NODE} → Ready"
                break
            fi
        fi

        printf "  노드 재합류 대기 중... (%d/%d)\r" "$((i+1))" "$retries"
        sleep 5
        i=$((i+1))
    done
    echo ""

    oc get nodes
}

# =============================================================================
step_verify() {
    print_step "5/5  Uncordon + 최종 검증"

    if oc get node "$TARGET_NODE" &>/dev/null; then
        oc adm uncordon "$TARGET_NODE"
        print_ok "Uncordon 완료 — 스케줄 가능 상태로 복구됨"
    else
        print_warn "노드가 아직 등록되지 않았습니다. 수동 uncordon이 필요할 수 있습니다:"
        print_cmd "oc adm uncordon ${TARGET_NODE}"
    fi

    echo ""
    oc get nodes -o wide
}

# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! 노드 재합류 랩이 완료되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  최종 노드 상태:"
    echo -e "    ${CYAN}oc get nodes${NC}"
    echo ""
    echo -e "  CSR 상태 확인:"
    echo -e "    ${CYAN}oc get csr${NC}"
    echo ""
    echo -e "  상세 내용: 18-add-node/18-add-node.md"
    echo ""
}

# =============================================================================
main() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  18-add-node: 워커 노드 제거 및 재합류 랩${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}  virt-poc ${POC_VERSION}${NC}"

    preflight
    step_identify
    step_drain
    step_stop_kubelet
    step_start_kubelet
    step_verify
    print_summary
}

main "$@"
