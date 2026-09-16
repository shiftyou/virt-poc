#!/bin/bash
# =============================================================================
# 20-logging.sh
#
# OpenShift Audit 로깅 설정
# APIServer Audit Policy 구성 + OpenShift Logging Operator를 통한 수집/전달
#
#   1. APIServer Audit Policy 선택 및 설정
#   2. OpenShift Logging Operator 확인
#   3. ClusterLogging 인스턴스 생성
#   4. LokiStack 생성 (Loki Operator 설치 시, Garage S3 사용)
#   5. ClusterLogForwarder 설정 (Audit 로그 포함)
#   6. 상태 확인
#
# 사용법: ./20-logging.sh
# =============================================================================

set -euo pipefail
trap 'echo -e "\n\033[0;31m[오류]\033[0m ${LINENO}번째 줄에서 명령 실패: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

LOGGING_NS="openshift-logging"
LOKI_NAME="logging-loki"
CLF_NAME="instance"
CL_NAME="instance"
STORAGE_CLASS="${STORAGE_CLASS:-ocs-storagecluster-ceph-rbd}"

# Object Storage (S3) — LokiStack 전용 (preflight에서 소스 결정)
S3_ENDPOINT=""
S3_BUCKET=""
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
S3_REGION=""

AUDIT_PROFILE=""
HAS_LOGGING=false
HAS_LOKI=false
LOGGING_V6=false

if [ -f "${SCRIPT_DIR}/../utils/common.sh" ]; then
    source "${SCRIPT_DIR}/../utils/common.sh"
else
    # ── 독립 실행 모드: common.sh 없이 인라인 헬퍼 사용 ──
    RED='\033[0;31m'; GREEN='\033[0;32m'; DIM='\033[2m'
    POC_VERSION=$(cat "${SCRIPT_DIR}/../../VERSION" 2>/dev/null || echo "dev")
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

# =============================================================================
# Audit Policy 프로파일 선택
# =============================================================================
choose_audit_profile() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  APIServer Audit Policy 프로파일 선택${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Default"
    echo -e "     메타데이터만 기록 (URL, HTTP Method, 응답 코드, 사용자, 시간)."
    echo -e "     요청/응답 본문 없음. 최소 로그 용량."
    echo ""
    echo -e "  ${GREEN}2)${NC} WriteRequestBodies  ${YELLOW}[권장]${NC}"
    echo -e "     쓰기 요청 (create/update/patch/delete) 본문을 기록."
    echo -e "     감사 목적에 충분하며, 읽기 요청 본문은 제외."
    echo ""
    echo -e "  ${GREEN}3)${NC} AllRequestBodies"
    echo -e "     모든 요청/응답 본문을 기록. 가장 상세하지만 로그 용량이 크게 증가합니다."
    echo -e "     민감한 정보 (Secret 값 등)가 포함될 수 있으므로 주의하여 사용하세요."
    echo ""
    echo -e "  ${GREEN}4)${NC} None"
    echo -e "     Audit 로깅 비활성화. ${RED}보안 권고사항을 충족하지 않습니다.${NC}"
    echo ""
    read -r -p "  선택하세요 [1-4, 기본값: 2]: " choice
    choice="${choice:-2}"

    case "$choice" in
        1) AUDIT_PROFILE="Default" ;;
        2) AUDIT_PROFILE="WriteRequestBodies" ;;
        3) AUDIT_PROFILE="AllRequestBodies" ;;
        4) AUDIT_PROFILE="None" ;;
        *)
            print_error "1에서 4 사이의 값을 입력하세요."
            exit 1
            ;;
    esac
    print_ok "선택됨: Audit Profile = ${AUDIT_PROFILE}"
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
    print_ok "클러스터 접근: $(oc whoami) @ $(oc whoami --show-server)"

    # OpenShift Logging Operator 확인
    if [ "${LOGGING_INSTALLED:-false}" = "true" ]; then
        HAS_LOGGING=true
        print_ok "OpenShift Logging Operator 확인됨"
    else
        HAS_LOGGING=false
        print_warn "OpenShift Logging Operator가 설치되어 있지 않습니다 → 건너뜀."
        print_warn "  설치 가이드: operators/"
        exit 77
    fi

    # Loki Operator 확인
    if [ "${LOKI_INSTALLED:-false}" = "true" ]; then
        HAS_LOKI=true
        print_ok "Loki Operator 확인됨"

        # S3 초기값 결정: env.conf Garage → env.conf ODF → 라이브 감지 → 수동 입력
        if [ -n "${GARAGE_ENDPOINT:-}" ]; then
            S3_ENDPOINT="${GARAGE_ENDPOINT}"
            S3_BUCKET="${LOGGING_S3_BUCKET:-${GARAGE_BUCKET:-loki}}"
            S3_ACCESS_KEY="${GARAGE_ACCESS_KEY:-}"
            S3_SECRET_KEY="${GARAGE_SECRET_KEY:-}"
            S3_REGION="${LOGGING_S3_REGION:-garage}"
        elif [ -n "${ODF_S3_ENDPOINT:-}" ]; then
            S3_ENDPOINT="${ODF_S3_ENDPOINT}"
            S3_BUCKET="(OBC 자동 생성 — step_loki_obc에서 결정)"
            S3_ACCESS_KEY="${ODF_S3_ACCESS_KEY:-}"
            S3_SECRET_KEY="${ODF_S3_SECRET_KEY:-}"
            S3_REGION="${LOGGING_S3_REGION:-${ODF_S3_REGION:-us-east-1}}"
        elif [ -n "${LOGGING_S3_ENDPOINT:-}" ]; then
            S3_ENDPOINT="${LOGGING_S3_ENDPOINT}"
            S3_BUCKET="${LOGGING_S3_BUCKET:-loki}"
            S3_ACCESS_KEY="${LOGGING_S3_ACCESS_KEY:-}"
            S3_SECRET_KEY="${LOGGING_S3_SECRET_KEY:-}"
            S3_REGION="${LOGGING_S3_REGION:-us-east-1}"
        else
            # env.conf에 S3 정보 없음 — 라이브 감지 시도
            auto_detect_garage
            if [ "${GARAGE_FOUND}" = "true" ]; then
                S3_ENDPOINT="${GARAGE_ENDPOINT}"
                S3_BUCKET="${LOGGING_S3_BUCKET:-loki}"
                S3_ACCESS_KEY="${GARAGE_ACCESS_KEY:-}"
                S3_SECRET_KEY="${GARAGE_SECRET_KEY:-}"
                S3_REGION="${LOGGING_S3_REGION:-garage}"
            elif [ "${ODF_INSTALLED:-false}" = "true" ]; then
                auto_detect_odf
                if [ -n "${ODF_S3_ACCESS_KEY:-}" ]; then
                    S3_ENDPOINT="${ODF_S3_ENDPOINT}"
                    S3_BUCKET="(OBC 자동 생성 — step_loki_obc에서 결정)"
                    S3_ACCESS_KEY="${ODF_S3_ACCESS_KEY:-}"
                    S3_SECRET_KEY="${ODF_S3_SECRET_KEY:-}"
                    S3_REGION="${LOGGING_S3_REGION:-${ODF_S3_REGION:-us-east-1}}"
                else
                    S3_ENDPOINT=""
                    S3_BUCKET="${LOGGING_S3_BUCKET:-loki}"
                    S3_ACCESS_KEY=""
                    S3_SECRET_KEY=""
                    S3_REGION="${LOGGING_S3_REGION:-us-east-1}"
                    print_warn "Object Storage 자동 감지 실패 — 아래에서 수동으로 입력하세요."
                fi
            else
                S3_ENDPOINT=""
                S3_BUCKET="${LOGGING_S3_BUCKET:-loki}"
                S3_ACCESS_KEY=""
                S3_SECRET_KEY=""
                S3_REGION="${LOGGING_S3_REGION:-us-east-1}"
                print_warn "Object Storage 자동 감지 실패 — 아래에서 수동으로 입력하세요."
            fi
        fi

        # Object Storage 정보 확인 및 재입력
        echo ""
        print_info "── Object Storage (S3) — LokiStack 전용 ──"
        print_info "  S3 Endpoint  : ${S3_ENDPOINT:-(미설정)}"
        print_info "  S3 Bucket    : ${S3_BUCKET}"
        print_info "  S3 Region    : ${S3_REGION}"
        print_info "  S3 AccessKey : ${S3_ACCESS_KEY:-(미설정)}"
        print_info "  S3 SecretKey : ****"
        echo ""
        read -r -p "  위 정보가 맞습니까? (Y/n): " _confirm
        if [[ "${_confirm:-}" =~ ^[Nn]$ ]]; then
            read -r -p "  S3 Endpoint  [${S3_ENDPOINT}]: " _input
            [ -n "$_input" ] && S3_ENDPOINT="$_input"
            read -r -p "  S3 Bucket    [${S3_BUCKET}]: " _input
            [ -n "$_input" ] && S3_BUCKET="$_input"
            read -r -p "  S3 Region    [${S3_REGION}]: " _input
            [ -n "$_input" ] && S3_REGION="$_input"
            read -r -p "  S3 AccessKey [${S3_ACCESS_KEY}]: " _input
            [ -n "$_input" ] && S3_ACCESS_KEY="$_input"
            read -r -s -p "  S3 SecretKey [****]: " _input
            echo ""
            [ -n "$_input" ] && S3_SECRET_KEY="$_input"
        fi
        print_ok "Object Storage 설정 확인됨 (bucket: ${S3_BUCKET})"

        # Logging S3 설정을 env.conf에 저장
        save_to_env "LOGGING_S3_ENDPOINT" "${S3_ENDPOINT}"
        save_to_env "LOGGING_S3_BUCKET" "${S3_BUCKET}"
        save_to_env "LOGGING_S3_ACCESS_KEY" "${S3_ACCESS_KEY}"
        save_to_env "LOGGING_S3_SECRET_KEY" "${S3_SECRET_KEY}"
        save_to_env "LOGGING_S3_REGION" "${S3_REGION}"
    else
        HAS_LOKI=false
        print_warn "Loki Operator가 설치되어 있지 않습니다 → LokiStack 생성 건너뜀."
        if [ "$HAS_LOGGING" = "true" ]; then
            print_warn "  → Loki 없이 ClusterLogForwarder는 기본 출력만 사용합니다."
        fi
    fi

    # Logging 버전 감지 (v6에서 ClusterLogging CRD 제거됨)
    if ! oc get crd clusterloggings.logging.openshift.io &>/dev/null; then
        LOGGING_V6=true
        print_ok "OpenShift Logging v6 감지됨 (observability.openshift.io/v1 사용)"
    else
        LOGGING_V6=false
        print_ok "OpenShift Logging v5 감지됨 (logging.openshift.io/v1 사용)"
    fi
}

# =============================================================================
# Step 1: APIServer Audit Policy 설정
# =============================================================================
step_audit_policy() {
    print_step "1/5  APIServer Audit Policy 설정 (프로파일: ${AUDIT_PROFILE})"

    local current
    current=$(oc get apiserver cluster -o jsonpath='{.spec.audit.profile}' 2>/dev/null || echo "")
    if [ "${current}" = "${AUDIT_PROFILE}" ]; then
        print_ok "동일한 프로파일이 이미 적용되어 있습니다 (${AUDIT_PROFILE}) — 건너뜀."
        return
    fi
    [ -n "$current" ] && print_info "현재 프로파일: ${current} → 변경: ${AUDIT_PROFILE}"

    cat > ./audit-policy.yaml <<EOF
apiVersion: config.openshift.io/v1
kind: APIServer
metadata:
  name: cluster
spec:
  audit:
    profile: ${AUDIT_PROFILE}
EOF

    confirm_and_apply ./audit-policy.yaml false
    print_ok "Audit Policy 적용 완료"
    print_info "kube-apiserver rollout에 수 분이 소요될 수 있습니다."
    print_info "  확인: oc get co kube-apiserver"
}

# =============================================================================
# Step 2: openshift-logging namespace 확인
# =============================================================================
step_namespace() {
    print_step "2/5  openshift-logging Namespace 확인"

    if oc get namespace "${LOGGING_NS}" &>/dev/null; then
        print_ok "Namespace ${LOGGING_NS} 존재함"
    else
        print_error "Namespace ${LOGGING_NS}이(가) 존재하지 않습니다."
        print_error "  OpenShift Logging Operator가 정상 설치되면 자동으로 생성됩니다."
        print_error "  operators/ 설치 가이드를 확인하세요."
        exit 1
    fi
}

# =============================================================================
# Step 3: ClusterLogging 인스턴스 생성
# =============================================================================
step_cluster_logging() {
    print_step "3/5  ClusterLogging 인스턴스 생성"

    if [ "$LOGGING_V6" = "true" ]; then
        print_info "Logging v6 — ClusterLogging CR 불필요, 건너뜀."
        return
    fi

    if oc get clusterlogging "${CL_NAME}" -n "${LOGGING_NS}" &>/dev/null; then
        print_ok "ClusterLogging '${CL_NAME}'이(가) 이미 존재합니다 — 건너뜀."
        return
    fi

    local log_store_type="lokistack"
    local log_store_block=""

    if [ "$HAS_LOKI" = "true" ]; then
        log_store_block="  logStore:
    type: lokistack
    lokiStack:
      name: ${LOKI_NAME}
    retentionPolicy:
      application:
        maxAge: 7d
      audit:
        maxAge: 30d
      infrastructure:
        maxAge: 7d"
    else
        # Loki가 없을 때 logStore 블록 생략 (Vector 수집만)
        log_store_block="  # logStore: Loki Operator가 설치되어 있지 않아 생략됨"
    fi

    cat > ./cluster-logging.yaml <<EOF
apiVersion: logging.openshift.io/v1
kind: ClusterLogging
metadata:
  name: ${CL_NAME}
  namespace: ${LOGGING_NS}
spec:
  managementState: Managed
${log_store_block}
  collection:
    type: vector
EOF

    confirm_and_apply ./cluster-logging.yaml false
    print_ok "ClusterLogging '${CL_NAME}' 생성 완료"
}

# =============================================================================
# Step 4a: ODF 백엔드 사용 시 Loki 전용 OBC 생성
# =============================================================================
step_loki_obc() {
    # ODF가 아니면 건너뜀
    [ -z "${ODF_S3_ENDPOINT:-}" ] && [ -z "${GARAGE_ENDPOINT:-}" ] && return
    [ -n "${GARAGE_ENDPOINT:-}" ] && return   # Garage에는 OBC 불필요

    print_step "4a  Loki 전용 ObjectBucketClaim 생성"

    if oc get obc obc-loki -n "${LOGGING_NS}" &>/dev/null; then
        print_ok "OBC obc-loki가 이미 존재합니다 — bucket 이름 조회 중"
    else
        local _obc_sc
        _obc_sc=$(oc get storageclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
            tr ' ' '\n' | grep -i "noobaa" | head -1 || true)
        [ -z "$_obc_sc" ] && _obc_sc="openshift-storage.noobaa.io"

        cat > ./obc-loki.yaml <<EOF
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: obc-loki
  namespace: ${LOGGING_NS}
spec:
  generateBucketName: loki
  storageClassName: ${_obc_sc}
EOF
        echo "생성된 파일: obc-loki.yaml"
        oc apply -f ./obc-loki.yaml
        print_ok "OBC obc-loki 생성 완료"
    fi

    # Bound 대기
    print_info "OBC가 Bound 상태가 되기를 대기 중..."
    local i=0
    while [ $i -lt 12 ]; do
        local phase
        phase=$(oc get obc obc-loki -n "${LOGGING_NS}" \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        [ "$phase" = "Bound" ] && break
        printf "  [%d/12] 대기 중... (%s)\r" "$((i+1))" "${phase:-Pending}"
        sleep 5
        i=$((i+1))
    done
    echo ""
    if [ $i -eq 12 ]; then
        print_error "OBC Bound 시간 초과."
        exit 1
    fi
    print_ok "OBC 상태: Bound"

    # bucket 이름 및 자격 증명 조회
    S3_BUCKET=$(oc get cm obc-loki -n "${LOGGING_NS}" \
        -o jsonpath='{.data.BUCKET_NAME}' 2>/dev/null || true)
    S3_ACCESS_KEY=$(oc get secret obc-loki -n "${LOGGING_NS}" \
        -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d || true)
    S3_SECRET_KEY=$(oc get secret obc-loki -n "${LOGGING_NS}" \
        -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d || true)
    print_ok "Loki OBC bucket/자격 증명 조회 완료"
    print_info "  Bucket : ${S3_BUCKET}"
}

# =============================================================================
# Step 4: LokiStack + S3 Secret 생성 (Loki Operator 설치 시)
# =============================================================================
step_loki_secret() {
    if oc get secret logging-loki-s3 -n "${LOGGING_NS}" &>/dev/null; then
        print_ok "S3 Secret 'logging-loki-s3'이(가) 이미 존재합니다."
        return
    fi

    if [ -z "${S3_ENDPOINT}" ] || [ -z "${S3_ACCESS_KEY}" ]; then
        print_error "Object Storage 정보가 없습니다. 사전 점검 단계에서 S3 정보를 입력하세요."
        exit 1
    fi

    oc create secret generic logging-loki-s3 \
        -n "${LOGGING_NS}" \
        --from-literal=access_key_id="${S3_ACCESS_KEY}" \
        --from-literal=access_key_secret="${S3_SECRET_KEY}" \
        --from-literal=bucketnames="${S3_BUCKET}" \
        --from-literal=endpoint="${S3_ENDPOINT}" \
        --from-literal=region="${S3_REGION}"
    print_ok "S3 Secret 'logging-loki-s3' 생성 완료"
    print_info "  endpoint : ${S3_ENDPOINT}"
    print_info "  bucket   : ${S3_BUCKET}"
}

step_loki_stack() {
    print_step "4/5  LokiStack 생성"

    if oc get lokistack "${LOKI_NAME}" -n "${LOGGING_NS}" &>/dev/null; then
        print_ok "LokiStack '${LOKI_NAME}'이(가) 이미 존재합니다 — 건너뜀."
        return
    fi

    step_loki_obc
    step_loki_secret

    cat > ./loki-stack.yaml <<EOF
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: ${LOKI_NAME}
  namespace: ${LOGGING_NS}
spec:
  size: 1x.small
  storage:
    schemas:
      - version: v13
        effectiveDate: "2024-01-01"
    secret:
      name: logging-loki-s3
      type: s3
  storageClassName: ${STORAGE_CLASS}
  tenants:
    mode: openshift-logging
EOF

    confirm_and_apply ./loki-stack.yaml false

    # POC 환경용 리소스 축소 (LokiStack CRD는 리소스 오버라이드를 지원하지 않아 StatefulSet을 직접 패치)
    # 기본 1x.small: ingester cpu=4/mem=20Gi → 워커 노드의 CPU 부족으로 Pending 발생
    print_info "LokiStack StatefulSet 리소스 축소 중 (POC 환경)..."
    sleep 5  # StatefulSet 생성 대기
    oc patch statefulset "${LOKI_NAME}-ingester" -n "${LOGGING_NS}" --type=json -p '[
      {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"500m"},
      {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"2Gi"}
    ]' 2>/dev/null && print_ok "ingester 리소스 축소 완료" || print_warn "ingester 패치 실패 (수동 적용 필요)"
    oc patch statefulset "${LOKI_NAME}-compactor" -n "${LOGGING_NS}" --type=json -p '[
      {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"200m"},
      {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"512Mi"}
    ]' 2>/dev/null && print_ok "compactor 리소스 축소 완료" || print_warn "compactor 패치 실패 (수동 적용 필요)"
    oc patch deployment "${LOKI_NAME}-query-frontend" -n "${LOGGING_NS}" --type=json -p '[
      {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"200m"},
      {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"512Mi"}
    ]' 2>/dev/null && print_ok "query-frontend 리소스 축소 완료" || print_warn "query-frontend 패치 실패 (수동 적용 필요)"

    print_info "LokiStack 준비 대기 중 (최대 5분)..."
    local retries=30 i=0
    while [ "$i" -lt "$retries" ]; do
        local phase
        phase=$(oc get lokistack "${LOKI_NAME}" -n "${LOGGING_NS}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "$phase" = "True" ]; then
            print_ok "LokiStack '${LOKI_NAME}' Ready"
            break
        fi
        printf "  [%d/%d] 대기 중...\r" "$((i+1))" "$retries"
        sleep 10
        i=$((i+1))
    done
    echo ""
    [ "$i" -eq "$retries" ] && print_warn "LokiStack 준비 시간 초과. 상태 확인: oc get lokistack -n ${LOGGING_NS}"
}

# =============================================================================
# Step 5: ClusterLogForwarder (Audit 로그 포함)
# =============================================================================
step_log_forwarder() {
    print_step "5/5  ClusterLogForwarder 설정 (audit + infrastructure + application)"

    if oc get clusterlogforwarder "${CLF_NAME}" -n "${LOGGING_NS}" &>/dev/null; then
        print_warn "ClusterLogForwarder '${CLF_NAME}'이(가) 이미 존재합니다."
        read -r -p "기존 설정을 덮어쓰시겠습니까? [y/N]: " overwrite
        [[ "$overwrite" != "y" && "$overwrite" != "Y" ]] && { print_info "건너뜀."; return; }
    fi

    if [ "$LOGGING_V6" = "true" ]; then
        # v6: observability.openshift.io/v1, ServiceAccount 필요
        if ! oc get serviceaccount collector -n "${LOGGING_NS}" &>/dev/null; then
            oc create serviceaccount collector -n "${LOGGING_NS}"
            print_ok "ServiceAccount collector 생성됨"
        fi
        # 노드 로그 수집 권한
        for role in collect-application-logs collect-infrastructure-logs collect-audit-logs; do
            oc adm policy add-cluster-role-to-user "${role}" \
                -z collector -n "${LOGGING_NS}" 2>/dev/null || true
        done
        # LokiStack 쓰기 권한 (이것 없이는 gateway에서 403 반환)
        for role in \
            cluster-logging-write-application-logs \
            cluster-logging-write-infrastructure-logs \
            cluster-logging-write-audit-logs \
            logging-collector-logs-writer; do
            oc adm policy add-cluster-role-to-user "${role}" \
                -z collector -n "${LOGGING_NS}" 2>/dev/null || true
        done
        print_ok "collector ServiceAccount 권한 부여됨 (수집 + Loki 쓰기)"

        local output_section
        if [ "$HAS_LOKI" = "true" ]; then
            output_section="  outputs:
    - name: loki-storage
      type: lokiStack
      lokiStack:
        target:
          name: ${LOKI_NAME}
          namespace: ${LOGGING_NS}
        authentication:
          token:
            from: serviceAccount
      tls:
        insecureSkipVerify: true
  pipelines:
    - name: all-to-loki
      inputRefs:
        - application
        - infrastructure
        - audit
      outputRefs:
        - loki-storage"
        else
            output_section="  pipelines:
    - name: all-to-default
      inputRefs:
        - application
        - infrastructure
        - audit
      outputRefs:
        - default"
        fi

        cat > ./cluster-log-forwarder.yaml <<EOF
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: ${CLF_NAME}
  namespace: ${LOGGING_NS}
spec:
  serviceAccount:
    name: collector
${output_section}
EOF
    else
        # v5: logging.openshift.io/v1
        local output_section
        if [ "$HAS_LOKI" = "true" ]; then
            output_section="  outputs:
    - name: loki-storage
      type: lokiStack
      lokiStack:
        target:
          name: ${LOKI_NAME}
          namespace: ${LOGGING_NS}
        authentication:
          token:
            from: serviceAccount
  pipelines:
    - name: all-to-loki
      inputRefs:
        - application
        - infrastructure
        - audit
      outputRefs:
        - loki-storage"
        else
            output_section="  pipelines:
    - name: all-to-default
      inputRefs:
        - application
        - infrastructure
        - audit
      outputRefs:
        - default"
        fi

        cat > ./cluster-log-forwarder.yaml <<EOF
apiVersion: logging.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: ${CLF_NAME}
  namespace: ${LOGGING_NS}
spec:
${output_section}
EOF
    fi

    confirm_and_apply ./cluster-log-forwarder.yaml false
    print_ok "ClusterLogForwarder '${CLF_NAME}' 적용 완료"
}

# =============================================================================
# Console Plugin 활성화 (Observe > Logs 메뉴 표시)
# =============================================================================
step_console_plugin() {
    print_step "6/6  Console Plugin 활성화 (Observe > Logs)"

    if [ "$LOGGING_V6" = "true" ]; then
        # v6: UIPlugin CR (console.operator plugins 배열을 건드리지 않아 안전)
        if oc get uiplugin logging &>/dev/null; then
            print_ok "UIPlugin 'logging'이(가) 이미 존재합니다 — 건너뜀."
            return
        fi

        if ! oc get crd uiplugins.observability.openshift.io &>/dev/null; then
            print_warn "UIPlugin CRD를 찾을 수 없습니다 — cluster-observability-operator가 설치되어 있지 않음"
            print_info "  OperatorHub에서 'Cluster Observability Operator'를 설치한 후 다시 실행하세요."
            return
        fi

        cat > ./uiplugin-logging.yaml <<EOF
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: logging
spec:
  type: Logging
  logging:
    lokiStack:
      name: ${LOKI_NAME}
      namespace: ${LOGGING_NS}
EOF
        oc apply -f ./uiplugin-logging.yaml
        print_ok "UIPlugin 'logging' 생성 완료"
        print_info "  Console을 새로고침하면 Observe > Logs 메뉴가 나타납니다."
    else
        # v5: consoleplugin 방식 — 기존 plugins 목록에 추가 (덮어쓰지 않음)
        if ! oc get consoleplugin logging-view-plugin &>/dev/null; then
            print_warn "logging-view-plugin ConsolePlugin이 존재하지 않습니다."
            print_info "  OpenShift Logging Operator가 자동으로 생성합니다."
            print_info "    oc get consoleplugin"
            return
        fi
        print_ok "logging-view-plugin ConsolePlugin 확인됨"

        local _enabled
        _enabled=$(oc get console.operator.openshift.io cluster \
            -o jsonpath='{.spec.plugins}' 2>/dev/null || echo "")
        if echo "${_enabled}" | grep -q "logging-view-plugin"; then
            print_ok "logging-view-plugin이 이미 활성화되어 있습니다"
            return
        fi

        # /spec/plugins 배열이 없으면 초기화 후 추가
        if ! echo "${_enabled}" | grep -q '\['; then
            oc patch console.operator.openshift.io cluster --type=merge \
                -p '{"spec":{"plugins":[]}}' 2>/dev/null || true
        fi
        oc patch console.operator.openshift.io cluster --type=json \
            -p '[{"op":"add","path":"/spec/plugins/-","value":"logging-view-plugin"}]'
        print_ok "logging-view-plugin 활성화 완료"
        print_info "  Console을 새로고침하면 Observe > Logs 메뉴가 나타납니다."
    fi
}

# =============================================================================
# 상태 확인
# =============================================================================
step_verify() {
    print_step "상태 확인"

    echo ""
    echo -e "${CYAN}  [ APIServer Audit Policy ]${NC}"
    oc get apiserver cluster -o jsonpath='    profile: {.spec.audit.profile}{"\n"}' 2>/dev/null || \
        echo "    (확인 불가)"

    echo ""
    echo -e "${CYAN}  [ kube-apiserver Cluster Operator ]${NC}"
    oc get co kube-apiserver 2>/dev/null | \
        awk 'NR==1{printf "    %-30s %-10s %-12s %-12s\n",$1,$2,$3,$4} NR>1{printf "    %-30s %-10s %-12s %-12s\n",$1,$2,$3,$4}' || true

    if [ "$HAS_LOGGING" = "true" ]; then
        echo ""
        echo -e "${CYAN}  [ ClusterLogging ]${NC}"
        oc get clusterlogging -n "${LOGGING_NS}" 2>/dev/null | \
            awk '{printf "    %s\n", $0}' || echo "    (없음)"

        echo ""
        echo -e "${CYAN}  [ ClusterLogForwarder ]${NC}"
        oc get clusterlogforwarder -n "${LOGGING_NS}" 2>/dev/null | \
            awk '{printf "    %s\n", $0}' || echo "    (없음)"

        if [ "$HAS_LOKI" = "true" ]; then
            echo ""
            echo -e "${CYAN}  [ LokiStack ]${NC}"
            oc get lokistack -n "${LOGGING_NS}" 2>/dev/null | \
                awk '{printf "    %s\n", $0}' || echo "    (없음)"
        fi

        echo ""
        echo -e "${CYAN}  [ Collector Pod ]${NC}"
        oc get pods -n "${LOGGING_NS}" -l component=collector 2>/dev/null | \
            awk '{printf "    %s\n", $0}' || echo "    (없음)"
    fi

    echo ""
    print_info "실시간 Audit 로그 확인 (예시):"
    echo -e "    ${CYAN}oc adm node-logs --role=master --path=kube-apiserver/ | grep audit${NC}"
    if [ "$HAS_LOGGING" = "true" ]; then
        echo -e "    ${CYAN}oc logs -n ${LOGGING_NS} -l component=collector --tail=20${NC}"
    fi
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 20-logging 리소스 삭제"
    local _logging_ns="openshift-logging"
    oc delete clusterlogforwarder --all -n "$_logging_ns" --ignore-not-found 2>/dev/null || true
    oc delete clusterlogging instance -n "$_logging_ns" --ignore-not-found 2>/dev/null || true
    oc delete lokistack logging-loki -n "$_logging_ns" --ignore-not-found 2>/dev/null || true
    oc delete secret logging-loki-s3 -n "$_logging_ns" --ignore-not-found 2>/dev/null || true
    oc delete obc obc-loki -n "$_logging_ns" --ignore-not-found 2>/dev/null || true
    print_ok "20-logging 리소스 삭제 완료"
    print_info "  Namespace ${_logging_ns}은(는) Logging Operator가 관리하므로 삭제하지 않습니다."
}

# =============================================================================
# main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  OpenShift Audit 로깅 설정${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}  virt-poc ${POC_VERSION}${NC}"

    choose_audit_profile
    preflight

    step_audit_policy

    if [ "$HAS_LOGGING" = "true" ]; then
        step_namespace
        step_cluster_logging
        if [ "$HAS_LOKI" = "true" ]; then
            step_loki_stack
        else
            print_step "4/5  LokiStack 생성"
            print_warn "Loki Operator가 설치되어 있지 않습니다 — 건너뜀."
        fi
        step_log_forwarder
        step_console_plugin
    else
        print_step "3/5  ClusterLogging"
        print_warn "OpenShift Logging Operator가 설치되어 있지 않습니다 — 건너뜀."
        print_step "4/5  LokiStack"
        print_warn "OpenShift Logging Operator가 설치되어 있지 않습니다 — 건너뜀."
        print_step "5/5  ClusterLogForwarder"
        print_warn "OpenShift Logging Operator가 설치되어 있지 않습니다 — 건너뜀."
    fi

    step_verify

    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Audit 로깅 설정 완료${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  [샘플] 누가 언제 로그인했는지 확인${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${YELLOW}* Loki 수집 완료 후 OpenShift Console → Observe → Logs에서 쿼리${NC}"
    echo ""
    echo -e "  ${GREEN}1) OAuth 로그인 이벤트 (토큰 발급 = 로그인 시점)${NC}"
    echo -e "     ${CYAN}{log_type=\"audit\"} | json | requestURI=~\"/apis/oauth.openshift.io/v1/oauthaccesstokens.*\" | verb=\"create\"${NC}"
    echo ""
    echo -e "  ${GREEN}2) 사용자별 최근 로그인 (username 기준)${NC}"
    echo -e "     ${CYAN}{log_type=\"audit\"} | json | requestURI=~\"/apis/oauth.openshift.io/v1/oauthaccesstokens.*\" | verb=\"create\" | line_format \"{{.requestReceivedTimestamp}} {{.user_username}}\"${NC}"
    echo ""
    echo -e "  ${GREEN}3) 특정 사용자 로그인 필터${NC}"
    echo -e "     ${CYAN}{log_type=\"audit\"} | json | requestURI=~\"/apis/oauth.openshift.io/v1/oauthaccesstokens.*\" | verb=\"create\" | user_username=\"admin\"${NC}"
    echo ""
    echo -e "  ${GREEN}4) 로그인 실패 (HTTP 401/403)${NC}"
    echo -e "     ${CYAN}{log_type=\"audit\"} | json | requestURI=~\"/apis/oauth.openshift.io/v1/oauthaccesstokens.*\" | responseStatus_code=~\"40[13]\"${NC}"
    echo ""
    echo -e "  ${GREEN}5) CLI 방식: 노드 Audit 로그에서 직접 확인 (Loki 불필요)${NC}"
    echo -e "     ${CYAN}oc adm node-logs --role=master --path=oauth-server/ | grep '\"verb\":\"create\"' | grep oauthaccesstokens | awk -F'\"' '{print \$4, \$8}'${NC}"
    echo ""
    echo -e "  ${YELLOW}쿼리 필드 설명${NC}"
    echo -e "    requestReceivedTimestamp : 요청 타임스탬프 (ISO 8601)"
    echo -e "    user.username            : 로그인한 사용자명"
    echo -e "    sourceIPs                : 접속 소스 IP"
    echo -e "    responseStatus.code      : HTTP 응답 코드 (201=성공, 401=인증 실패, 403=권한 없음)"
    echo ""
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main "$@"
