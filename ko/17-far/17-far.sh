#!/bin/bash
# =============================================================================
# 17-far.sh
#
# Fence Agents Remediation (FAR) 랩 환경 구성
#   1. poc-far namespace 생성
#   2. IPMI 자격 증명 Secret 생성 (openshift-workload-availability)
#   3. FenceAgentsRemediationTemplate 생성 (IPMI 설정)
#   4. NodeHealthCheck CR 생성 (FAR 연동)
#
# 사용법: ./17-far.sh
# =============================================================================

set -euo pipefail
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

NS="poc-far"
REMEDIATION_NS="openshift-workload-availability"

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

    if [ "${FAR_INSTALLED:-false}" != "true" ]; then
        print_warn "Fence Agents Remediation Operator가 설치되어 있지 않습니다 → 건너뜀."
        print_warn "  설치 가이드: operators/far-operator.md"
        exit 77
    fi
    print_ok "Fence Agents Remediation Operator 확인됨"

    if [ "${NHC_INSTALLED:-false}" != "true" ]; then
        print_warn "Node Health Check Operator가 설치되어 있지 않습니다 → 건너뜀."
        print_warn "  설치 가이드: operators/nhc-operator.md"
        exit 77
    fi
    print_ok "Node Health Check Operator 확인됨"

    # env.conf에 IPMI 자격 증명이 없으면 수집
    load_or_ask FENCE_AGENT_USER "IPMI username" "admin"
    load_or_ask FENCE_AGENT_PASS "IPMI password" "password" "true"

    detect_worker_nodes
    NODE1="${TEST_NODE}"
    print_ok "대상 노드: $NODE1"

    if [ -z "${FENCE_AGENT_IPS:-}" ]; then
        echo ""
        print_info "각 워커 노드의 IPMI/BMC IP 주소를 입력하세요."
        FENCE_AGENT_IPS=""
        local _ipmi_idx=1
        for _node in ${WORKER_NODES}; do
            ask "  ${_node} IPMI/BMC IP" "192.168.1.${_ipmi_idx}" _node_ipmi_ip
            FENCE_AGENT_IPS="${FENCE_AGENT_IPS:+${FENCE_AGENT_IPS} }${_node_ipmi_ip}"
            _ipmi_idx=$((_ipmi_idx + 1))
        done
        print_ok "IPMI IP 목록: ${FENCE_AGENT_IPS}"
        save_to_env "FENCE_AGENT_IPS" "\"${FENCE_AGENT_IPS}\""
        save_to_env "FENCE_AGENT_USER" "${FENCE_AGENT_USER}"
        save_to_env "FENCE_AGENT_PASS" "${FENCE_AGENT_PASS}"
    fi

    FENCE_AGENT_IP="${FENCE_AGENT_IPS%% *}"

    if [ -z "${FENCE_AGENT_IP:-}" ] || [ "${FENCE_AGENT_IP}" = "192.168.1.100" ]; then
        print_warn "FENCE_AGENT_IP가 기본값입니다. env.conf의 FENCE_AGENT_IPS를 실제 BMC IP로 업데이트하세요."
    else
        print_ok "FENCE_AGENT_IP: ${FENCE_AGENT_IP}"
    fi

    print_info "  NS    : ${NS}"
    print_info "  NODE1 : ${NODE1}"
    print_info "  BMC IP: ${FENCE_AGENT_IP:-미설정}"
}

# =============================================================================
# Step 1: namespace 생성
# =============================================================================
step_namespace() {
    print_step "1/3  namespace 생성 (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "Namespace ${NS}이(가) 이미 존재합니다 — 건너뜀"
    else
        print_info "Namespace $NS 생성 중..."
        oc new-project "$NS" > /dev/null
        if oc get namespace "$NS" &>/dev/null; then
            print_ok "Namespace $NS 생성됨"
        else
            print_error "Namespace $NS 생성 실패"
            return 1
        fi
    fi
}

# =============================================================================
# Step 2: IPMI 자격 증명 Secret 생성
# =============================================================================
step_secret() {
    print_step "2/4  IPMI 자격 증명 Secret 생성 (ns: ${REMEDIATION_NS})"

    if oc get secret poc-far-credentials -n "${REMEDIATION_NS}" &>/dev/null; then
        print_ok "Secret poc-far-credentials이(가) 이미 존재합니다 — 건너뜀"
        return
    fi

    cat > far-credentials-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: poc-far-credentials
  namespace: ${REMEDIATION_NS}
stringData:
  --password: "${FENCE_AGENT_PASS:-password}"
EOF
    print_info "Secret poc-far-credentials 생성 중..."
    confirm_and_apply far-credentials-secret.yaml
    if oc get secret poc-far-credentials -n "${REMEDIATION_NS}" &>/dev/null; then
        print_ok "Secret poc-far-credentials 생성됨 → ns: ${REMEDIATION_NS}"
    else
        print_error "Secret poc-far-credentials 생성 실패"
        return 1
    fi
}

# =============================================================================
# Step 3: FenceAgentsRemediationTemplate 생성
# =============================================================================
step_far_template() {
    print_step "3/4  FenceAgentsRemediationTemplate 생성"

    # 클러스터에서 워커 노드 FQDN 목록 수집
    local worker_nodes
    worker_nodes=$(oc get nodes -l node-role.kubernetes.io/worker \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || \
        echo "${WORKER_NODES:-worker-0}" | tr ' ' '\n')

    if [ -z "$worker_nodes" ]; then
        worker_nodes="${WORKER_NODES:-worker-0}"
        worker_nodes=$(echo "$worker_nodes" | tr ' ' '\n')
    fi

    # YAML 헤더 작성
    cat > far-template.yaml <<EOF
apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
kind: FenceAgentsRemediationTemplate
metadata:
  annotations:
    remediation.medik8s.io/multiple-templates-support: "true"
  name: poc-far-template
  namespace: ${REMEDIATION_NS}
spec:
  template:
    spec:
      agent: fence_ipmilan
      nodeparameters:
        --ip:
EOF

    # 노드별 BMC IP 항목 추가 (env.conf FENCE_AGENT_IP를 공통 BMC IP로 사용)
    while IFS= read -r node; do
        [ -z "$node" ] && continue
        echo "          ${node}: ${FENCE_AGENT_IP:-192.168.1.100}" >> far-template.yaml
        print_info "  Node → BMC IP: ${node} → ${FENCE_AGENT_IP:-192.168.1.100}"
    done <<< "$worker_nodes"

    # 나머지 YAML 작성
    cat >> far-template.yaml <<EOF
      remediationStrategy: ResourceDeletion
      retrycount: 5
      retryinterval: 5s
      sharedSecretName: poc-far-credentials
      sharedparameters:
        --action: reboot
        --lanplus: ""
        --username: ${FENCE_AGENT_USER:-admin}
      timeout: 1m0s
EOF

    print_info "FenceAgentsRemediationTemplate poc-far-template 생성 중..."
    confirm_and_apply far-template.yaml
    if oc get fenceagentsremediationtemplate poc-far-template -n "$REMEDIATION_NS" &>/dev/null; then
        print_ok "FenceAgentsRemediationTemplate poc-far-template 생성됨"
    else
        print_error "FenceAgentsRemediationTemplate poc-far-template 생성 실패"
        return 1
    fi
    print_info "  agent           : fence_ipmilan"
    print_info "  sharedSecretName: poc-far-credentials (--password 포함)"
    print_info "  BMC IP          : ${FENCE_AGENT_IP:-192.168.1.100}"
}

# =============================================================================
# Step 3: NodeHealthCheck 생성
# =============================================================================
step_nhc() {
    print_step "4/5  NodeHealthCheck 생성 (FAR 연동)"

    cat > nhc-far.yaml <<EOF
apiVersion: remediation.medik8s.io/v1alpha1
kind: NodeHealthCheck
metadata:
  name: poc-far-nhc
spec:
  minHealthy: "51%"
  remediationTemplate:
    apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
    kind: FenceAgentsRemediationTemplate
    name: poc-far-template
    namespace: ${REMEDIATION_NS}
  selector:
    matchExpressions:
      - key: node-role.kubernetes.io/worker
        operator: Exists
  unhealthyConditions:
    - type: Ready
      status: "False"
      duration: 300s
    - type: Ready
      status: Unknown
      duration: 300s
EOF
    print_info "NodeHealthCheck poc-far-nhc 생성 중..."
    confirm_and_apply nhc-far.yaml
    if oc get nodehealthcheck poc-far-nhc &>/dev/null; then
        print_ok "NodeHealthCheck poc-far-nhc 생성됨"
    else
        print_error "NodeHealthCheck poc-far-nhc 생성 실패"
        return 1
    fi
    print_info "  조건: Ready=False 또는 Unknown이 300초 이상 지속 → FAR 트리거 (IPMI reboot)"
}

# =============================================================================
# 완료 요약
# =============================================================================
step_consoleyamlsamples() {
    print_step "5/5  ConsoleYAMLSample 등록"

    cat > consoleyamlsample-nhc-far.yaml <<'EOF'
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-nodehealthcheck-far
spec:
  title: "POC NodeHealthCheck (FAR integration)"
  description: "Example NodeHealthCheck CR for auto-rebooting unhealthy worker nodes via IPMI using Fence Agents Remediation. FAR is triggered when Ready=False or Unknown state persists for 300 seconds."
  targetResource:
    apiVersion: remediation.medik8s.io/v1alpha1
    kind: NodeHealthCheck
  yaml: |
    apiVersion: remediation.medik8s.io/v1alpha1
    kind: NodeHealthCheck
    metadata:
      name: poc-far-nhc
    spec:
      minHealthy: "51%"
      remediationTemplate:
        apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
        kind: FenceAgentsRemediationTemplate
        name: poc-far-template
        namespace: openshift-workload-availability
      selector:
        matchExpressions:
          - key: node-role.kubernetes.io/worker
            operator: Exists
      unhealthyConditions:
        - type: Ready
          status: "False"
          duration: 300s
        - type: Ready
          status: Unknown
          duration: 300s
EOF
    print_info "ConsoleYAMLSample poc-nodehealthcheck-far 등록 중..."
    oc apply -f consoleyamlsample-nhc-far.yaml
    if oc get consoleyamlsample poc-nodehealthcheck-far &>/dev/null; then
        print_ok "ConsoleYAMLSample poc-nodehealthcheck-far 등록됨"
    else
        print_error "ConsoleYAMLSample poc-nodehealthcheck-far 등록 실패"
        return 1
    fi

    cat > consoleyamlsample-far-template.yaml <<'EOF'
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-fenceagentsremediationtemplate
spec:
  title: "POC FenceAgentsRemediationTemplate (IPMI)"
  description: "Example FenceAgentsRemediationTemplate for rebooting nodes via IPMI using fence_ipmilan. Configure per-node BMC IPs and shared credentials Secret."
  targetResource:
    apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
    kind: FenceAgentsRemediationTemplate
  yaml: |
    apiVersion: fence-agents-remediation.medik8s.io/v1alpha1
    kind: FenceAgentsRemediationTemplate
    metadata:
      annotations:
        remediation.medik8s.io/multiple-templates-support: "true"
      name: poc-far-template
      namespace: openshift-workload-availability
    spec:
      template:
        spec:
          agent: fence_ipmilan
          nodeparameters:
            --ip:
              worker-0: 192.168.1.100
              worker-1: 192.168.1.101
          remediationStrategy: ResourceDeletion
          retrycount: 5
          retryinterval: 5s
          sharedSecretName: poc-far-credentials
          sharedparameters:
            --action: reboot
            --lanplus: ""
            --username: admin
          timeout: 1m0s
EOF
    print_info "ConsoleYAMLSample poc-fenceagentsremediationtemplate 등록 중..."
    oc apply -f consoleyamlsample-far-template.yaml
    if oc get consoleyamlsample poc-fenceagentsremediationtemplate &>/dev/null; then
        print_ok "ConsoleYAMLSample poc-fenceagentsremediationtemplate 등록됨"
    else
        print_error "ConsoleYAMLSample poc-fenceagentsremediationtemplate 등록 실패"
        return 1
    fi
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! FAR 랩 환경이 준비되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  NHC 상태 확인:"
    echo -e "    ${CYAN}oc get nodehealthcheck poc-far-nhc${NC}"
    echo ""
    echo -e "  IPMI 연결 테스트:"
    echo -e "    ${CYAN}ipmitool -I lanplus -H ${FENCE_AGENT_IP:-<BMC_IP>} -U ${FENCE_AGENT_USER:-admin} -P <PASS> chassis power status${NC}"
    echo ""
    echo -e "  장애 시뮬레이션:"
    echo -e "    ${CYAN}oc debug node/${NODE1} -- chroot /host systemctl stop kubelet${NC}"
    echo ""
    echo -e "  FAR 트리거 확인 (300초 후):"
    echo -e "    ${CYAN}oc get fenceagentsremediation -A${NC}"
    echo -e "    ${CYAN}oc get nodes -w${NC}"
    echo ""
    echo -e "  상세 내용: 17-far/17-far.md"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 17-far 리소스 삭제"
    local _rem_ns="openshift-workload-availability"

    print_info "Project poc-far 삭제 중..."
    oc delete project poc-far --ignore-not-found 2>/dev/null || true
    if ! oc get namespace poc-far &>/dev/null; then
        print_ok "Project poc-far 삭제됨"
    else
        print_warn "Project poc-far 삭제 진행 중 (백그라운드)"
    fi

    print_info "NodeHealthCheck poc-far-nhc 삭제 중..."
    oc delete nodehealthcheck poc-far-nhc --ignore-not-found 2>/dev/null || true
    if ! oc get nodehealthcheck poc-far-nhc &>/dev/null; then
        print_ok "NodeHealthCheck poc-far-nhc 삭제됨"
    else
        print_warn "NodeHealthCheck poc-far-nhc 삭제 실패"
    fi

    print_info "FenceAgentsRemediationTemplate poc-far-template 삭제 중..."
    oc delete fenceagentsremediationtemplate poc-far-template -n "$_rem_ns" --ignore-not-found 2>/dev/null || true
    if ! oc get fenceagentsremediationtemplate poc-far-template -n "$_rem_ns" &>/dev/null; then
        print_ok "FenceAgentsRemediationTemplate poc-far-template 삭제됨"
    else
        print_warn "FenceAgentsRemediationTemplate poc-far-template 삭제 실패"
    fi

    print_info "Secret poc-far-credentials 삭제 중..."
    oc delete secret poc-far-credentials -n "$_rem_ns" --ignore-not-found 2>/dev/null || true
    if ! oc get secret poc-far-credentials -n "$_rem_ns" &>/dev/null; then
        print_ok "Secret poc-far-credentials 삭제됨"
    else
        print_warn "Secret poc-far-credentials 삭제 실패"
    fi

    print_info "ConsoleYAMLSample 삭제 중..."
    oc delete consoleyamlsample poc-nodehealthcheck-far poc-fenceagentsremediationtemplate --ignore-not-found 2>/dev/null || true
    if ! oc get consoleyamlsample poc-nodehealthcheck-far &>/dev/null && \
       ! oc get consoleyamlsample poc-fenceagentsremediationtemplate &>/dev/null; then
        print_ok "ConsoleYAMLSample 삭제됨"
    else
        print_warn "ConsoleYAMLSample 삭제 실패"
    fi
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  FAR 랩 환경 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}  virt-poc ${POC_VERSION}${NC}"

    preflight
    step_namespace
    step_secret
    step_far_template
    step_nhc
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
