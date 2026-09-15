#!/bin/bash
# =============================================================================
# 19-hyperconverged.sh
#
# HyperConverged 설정 랩
#   1. 현재 HyperConverged 설정 표시
#   2. CPU Overcommit 비율 확인 및 가이드 제공
#
# 사용법: ./19-hyperconverged.sh
# =============================================================================

set -euo pipefail
trap 'echo -e "\n\033[0;31m[오류]\033[0m ${LINENO}번째 줄에서 명령 실패: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

HCO_NS="openshift-cnv"
HCO_NAME="kubevirt-hyperconverged"

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

preflight() {
    print_step "사전 점검"
    auto_detect_operators

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 접근: $(oc whoami) @ $(oc whoami --show-server)"

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator가 설치되어 있지 않습니다 → 건너뜀."
        exit 77
    fi

    if ! oc get hyperconverged "$HCO_NAME" -n "$HCO_NS" &>/dev/null; then
        print_error "HyperConverged CR '$HCO_NAME'을(를) 찾을 수 없습니다."
        exit 1
    fi
    print_ok "HyperConverged CR 확인됨"
}

step_show_current() {
    print_step "1/2  현재 HyperConverged 설정"

    echo ""
    echo -e "  ${CYAN}── CPU Overcommit ──${NC}"
    local cpu_ratio
    cpu_ratio=$(oc get hyperconverged "$HCO_NAME" -n "$HCO_NS" \
        -o jsonpath='{.spec.resourceRequirements.vmiCPUAllocationRatio}' 2>/dev/null || echo "10(기본값)")
    echo -e "  vmiCPUAllocationRatio: ${YELLOW}${cpu_ratio}${NC}  (vCPU:pCPU = ${cpu_ratio}:1)"

    echo ""
    echo -e "  ${CYAN}── Live Migration ──${NC}"
    oc get hyperconverged "$HCO_NAME" -n "$HCO_NS" \
        -o jsonpath='{range .spec.liveMigrationConfig}{@}{"\n"}{end}' 2>/dev/null || \
        echo "  (기본값 사용 중)"

    echo ""
    echo -e "  ${CYAN}── HyperConverged 상태 ──${NC}"
    oc get hyperconverged "$HCO_NAME" -n "$HCO_NS" \
        --no-headers \
        -o custom-columns="NAME:.metadata.name,AGE:.metadata.creationTimestamp,PHASE:.status.phase"
    echo ""
}

step_guide() {
    print_step "2/2  설정 변경 가이드"

    echo ""
    echo -e "  ${CYAN}CPU Overcommit 변경 예시:${NC}"
    echo -e "    # 4:1로 변경"
    echo -e "    ${YELLOW}oc patch hyperconverged ${HCO_NAME} -n ${HCO_NS} \\${NC}"
    echo -e "    ${YELLOW}  --type=merge \\${NC}"
    echo -e "    ${YELLOW}  -p '{\"spec\":{\"resourceRequirements\":{\"vmiCPUAllocationRatio\":4}}}'${NC}"
    echo ""
    echo -e "  ${CYAN}Live Migration 동시 실행 수 변경:${NC}"
    echo -e "    ${YELLOW}oc patch hyperconverged ${HCO_NAME} -n ${HCO_NS} \\${NC}"
    echo -e "    ${YELLOW}  --type=merge \\${NC}"
    echo -e "    ${YELLOW}  -p '{\"spec\":{\"liveMigrationConfig\":{\"parallelMigrationsPerCluster\":5}}}'${NC}"
    echo ""
    echo -e "  상세 내용: ${CYAN}19-hyperconverged/19-hyperconverged.md${NC}"
    echo ""
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  HyperConverged 설정 랩${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_show_current
    step_guide
}

main
