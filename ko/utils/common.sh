#!/bin/bash
# =============================================================================
# utils/common.sh
#
# virt-poc 모든 lab 스크립트의 공통 함수 모음.
# 인라인 color/print 헬퍼를 직접 정의하지 말고 이 파일을 source 하세요.
#
#   source "${SCRIPT_DIR}/../utils/common.sh"
#
# 제공 기능:
#   색상 상수, print_info/ok/warn/error/step/header,
#   ask(), save_to_env(), load_or_ask(),
#   detect_worker_nodes(), auto_detect_garage(), auto_detect_odf(),
#   confirm_and_apply()
# =============================================================================

# 이중 source 방지
[ -n "${_COMMON_SH_LOADED:-}" ] && return 0
_COMMON_SH_LOADED=1

# ---------------------------------------------------------------------------
# 색상 상수
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
DIM='\033[2m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# 출력 헬퍼
# ---------------------------------------------------------------------------
print_info()  { echo -e "${BLUE}[정보]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[경고]${NC} $1"; }
print_error() { echo -e "${RED}[오류]${NC} $1"; }
print_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

print_header() {
    echo ""
    echo -e "${CYAN}================================================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}================================================================${NC}"
    echo ""
}

print_step_header() {
    local num="$1"
    local title="$2"
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  ${num}  ${title}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
# ask() — 기본값이 있는 대화형 프롬프트
# ---------------------------------------------------------------------------
ask() {
    local prompt="$1"
    local default="$2"
    local var_name="$3"
    local is_secret="${4:-false}"

    if [ "$is_secret" = "true" ]; then
        echo -n -e "${YELLOW}  $prompt${NC} [기본값: ****]: "
        read -s input_val
        echo ""
    else
        echo -n -e "${YELLOW}  $prompt${NC} [기본값: ${default}]: "
        read input_val
    fi

    if [ -z "$input_val" ]; then
        input_val="$default"
    fi

    eval "$var_name='$input_val'"
}

# ---------------------------------------------------------------------------
# save_to_env() — env.conf에 변수를 업데이트하거나 추가
#   save_to_env KEY VALUE [ENV_FILE]
# ---------------------------------------------------------------------------
save_to_env() {
    local key="$1"
    local value="$2"
    local env_file="${3:-${ENV_FILE:-}}"

    if [ -z "$env_file" ]; then
        local caller_dir
        caller_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
        env_file="${caller_dir}/../env.conf"
    fi

    [ ! -f "$env_file" ] && return 0

    if grep -q "^${key}=" "$env_file" 2>/dev/null; then
        if [[ "$OSTYPE" == darwin* ]]; then
            sed -i '' "s|^${key}=.*|${key}=${value}|" "$env_file"
        else
            sed -i "s|^${key}=.*|${key}=${value}|" "$env_file"
        fi
    else
        echo "${key}=${value}" >> "$env_file"
    fi
}

# ---------------------------------------------------------------------------
# load_or_ask() — env.conf의 기존 값 사용 또는 입력 후 저장
#   load_or_ask VAR_NAME "prompt" "default" [is_secret]
# ---------------------------------------------------------------------------
load_or_ask() {
    local var_name="$1"
    local prompt="$2"
    local default="$3"
    local is_secret="${4:-false}"

    local current_val
    eval "current_val=\${${var_name}:-}"

    if [ -n "$current_val" ]; then
        return 0
    fi

    ask "$prompt" "$default" "$var_name" "$is_secret"
    eval "local _val=\$$var_name"
    save_to_env "$var_name" "$_val"
}

# ---------------------------------------------------------------------------
# confirm_and_apply() — YAML 미리보기 후 적용
#   confirm_and_apply FILE [auto]
#   auto=true → 확인 없이 적용; 기본값 → 사용자에게 확인
# ---------------------------------------------------------------------------
confirm_and_apply() {
    local file="$1"
    local auto="${2:-true}"
    echo ""
    print_info "적용할 YAML:"
    echo "────────────────────────────────────────"
    cat "$file"
    echo "────────────────────────────────────────"
    if [ "$auto" != "true" ]; then
        read -r -p "위 YAML을 클러스터에 적용하시겠습니까? [y/N]: " confirm
        [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { print_warn "취소됨."; return 1; }
    fi
    oc apply -f "$file"
}

# ---------------------------------------------------------------------------
# detect_worker_nodes() — 클러스터에서 워커 노드 감지
#   설정: WORKER_NODES (공백 구분), TEST_NODE (첫 번째 워커)
# ---------------------------------------------------------------------------
detect_worker_nodes() {
    WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    TEST_NODE=$(echo "$WORKER_NODES" | awk '{print $1}')

    if [ -z "$WORKER_NODES" ]; then
        print_error "워커 노드를 찾을 수 없습니다."
        exit 1
    fi
    print_info "워커 노드: ${WORKER_NODES}"
}

# ---------------------------------------------------------------------------
# auto_detect_garage() — 클러스터 내 Garage S3 서비스 감지
#   설정: GARAGE_ENDPOINT, GARAGE_BUCKET, GARAGE_ACCESS_KEY,
#          GARAGE_SECRET_KEY, GARAGE_FOUND
# ---------------------------------------------------------------------------
auto_detect_garage() {
    GARAGE_ENDPOINT=""
    GARAGE_BUCKET="velero"
    GARAGE_ACCESS_KEY="garage"
    GARAGE_SECRET_KEY="garage123"

    local garage_ns
    garage_ns=$(oc get svc -A -l app=garage -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)

    GARAGE_FOUND=false

    if [ -n "$garage_ns" ]; then
        local garage_svc garage_port
        garage_svc=$(oc get svc -n "$garage_ns" -l app=garage \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
            oc get svc -n "$garage_ns" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        garage_port=$(oc get svc -n "$garage_ns" "$garage_svc" \
            -o jsonpath='{.spec.ports[?(@.name=="s3-api")].port}' 2>/dev/null || echo "3900")
        GARAGE_ENDPOINT="http://${garage_svc}.${garage_ns}.svc.cluster.local:${garage_port}"

        local secret_name
        secret_name=$(oc get secret -n "$garage_ns" \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
            tr ' ' '\n' | grep -iE "garage|credentials|s3" | head -1 || true)
        if [ -n "$secret_name" ]; then
            local ak sk
            ak=$(oc get secret -n "$garage_ns" "$secret_name" \
                -o jsonpath='{.data.accessKey}' 2>/dev/null | base64 -d 2>/dev/null || \
                oc get secret -n "$garage_ns" "$secret_name" \
                -o jsonpath='{.data.access_key_id}' 2>/dev/null | base64 -d 2>/dev/null || true)
            sk=$(oc get secret -n "$garage_ns" "$secret_name" \
                -o jsonpath='{.data.secretKey}' 2>/dev/null | base64 -d 2>/dev/null || \
                oc get secret -n "$garage_ns" "$secret_name" \
                -o jsonpath='{.data.secret_access_key}' 2>/dev/null | base64 -d 2>/dev/null || true)
            [ -n "$ak" ] && GARAGE_ACCESS_KEY="$ak"
            [ -n "$sk" ] && GARAGE_SECRET_KEY="$sk"
        fi

        GARAGE_FOUND=true
        print_info "Garage endpoint : ${GARAGE_ENDPOINT}  (ns: ${garage_ns})"
        print_info "Garage bucket   : ${GARAGE_BUCKET}"
        print_info "Garage accessKey: ${GARAGE_ACCESS_KEY}"
    else
        print_warn "Garage Service (app=garage) 감지 실패 → Garage 설정을 건너뜁니다."
    fi
}

# ---------------------------------------------------------------------------
# auto_detect_odf() — ODF (NooBaa MCG) S3 endpoint 감지
#   설정: ODF_S3_ENDPOINT, ODF_S3_BUCKET, ODF_S3_REGION,
#          ODF_S3_ACCESS_KEY, ODF_S3_SECRET_KEY
# ---------------------------------------------------------------------------
auto_detect_odf() {
    ODF_S3_ENDPOINT=""
    ODF_S3_BUCKET="velero"
    ODF_S3_REGION="localstorage"
    ODF_S3_ACCESS_KEY=""
    ODF_S3_SECRET_KEY=""

    local odf_ns="openshift-storage"

    ODF_S3_ENDPOINT=$(oc get noobaa -n "$odf_ns" \
        -o jsonpath='{.status.services.serviceS3.internalDNS[0]}' 2>/dev/null || true)
    if [ -z "$ODF_S3_ENDPOINT" ]; then
        local s3_port
        s3_port=$(oc get svc s3 -n "$odf_ns" \
            -o jsonpath='{.spec.ports[?(@.name=="s3")].port}' 2>/dev/null || echo "80")
        ODF_S3_ENDPOINT="http://s3.${odf_ns}.svc.cluster.local:${s3_port}"
    fi

    ODF_S3_ACCESS_KEY=$(oc get secret noobaa-admin -n "$odf_ns" \
        -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d 2>/dev/null || true)
    ODF_S3_SECRET_KEY=$(oc get secret noobaa-admin -n "$odf_ns" \
        -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d 2>/dev/null || true)

    if [ -n "$ODF_S3_ACCESS_KEY" ]; then
        print_info "ODF MCG S3 endpoint : ${ODF_S3_ENDPOINT}"
        print_info "ODF MCG region      : ${ODF_S3_REGION}"
        print_info "ODF MCG bucket      : ${ODF_S3_BUCKET}"
        print_info "ODF MCG 인증 정보   : noobaa-admin secret에서 가져옴"
    else
        print_warn "ODF MCG 인증 정보 감지 실패 (noobaa-admin secret 없음)"
    fi
}
