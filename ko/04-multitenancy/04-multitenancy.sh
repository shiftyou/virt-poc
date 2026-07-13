#!/bin/bash
# =============================================================================
# 04-multitenancy.sh
#
# 멀티 테넌트 VM 환경 구성
#   - 2개의 namespace 생성 (poc-multitenancy-1, poc-multitenancy-2)
#   - user1: poc-multitenancy-1 admin  → VM 생성 가능
#   - user2: poc-multitenancy-1 view   → VM 생성 불가 (읽기 전용)
#   - user3: poc-multitenancy-2 admin  → VM 생성 가능
#   - user4: poc-multitenancy-2 view   → VM 생성 불가 (읽기 전용)
#   - namespace당 1개의 VM 생성 (poc template 사용)
#
# 사용법: ./04-multitenancy.sh [--cleanup]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

source "${SCRIPT_DIR}/../utils/common.sh"

print_cmd() { echo -e "  ${DIM}\$ $1${NC}"; }

# =============================================================================
# 설정
# =============================================================================
NS1="poc-multitenancy-1"
NS2="poc-multitenancy-2"

USER1="user1"   # NS1 admin (VM 생성 가능)
USER2="user2"   # NS1 view  (읽기 전용, VM 생성 불가)
USER3="user3"   # NS2 admin (VM 생성 가능)
USER4="user4"   # NS2 view  (읽기 전용, VM 생성 불가)

DEFAULT_PASS="Redhat1!"

HTPASSWD_SECRET="htpasswd-secret"
HTPASSWD_IDP_NAME="poc-htpasswd"
HTPASSWD_TMP="/tmp/poc-htpasswd-$$"

DATASOURCE_NS="${DATASOURCE_NS:-openshift-virtualization-os-images}"
DATASOURCE_NAME="${DATASOURCE_NAME:-poc}"
STORAGE_CLASS="${STORAGE_CLASS:-}"

# =============================================================================
preflight() {
    print_step "사전 점검"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 연결: $(oc whoami) @ $(oc whoami --show-server)"

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator가 설치되지 않았습니다 → 건너뜀."
        print_warn "  설치 가이드: operators/kubevirt-hyperconverged-operator.md"
        exit 77
    fi
    print_ok "OpenShift Virtualization Operator 확인됨"

    if ! command -v htpasswd &>/dev/null; then
        print_error "htpasswd 명령어를 찾을 수 없습니다."
        print_info "설치: dnf install -y httpd-tools"
        exit 1
    fi
    print_ok "htpasswd 명령어 확인됨"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc Template을 찾을 수 없습니다 — VM이 생성되지 않습니다. (먼저 01-template을 실행하세요)"
    else
        print_ok "poc Template 확인됨"
    fi
}

# =============================================================================
step_users() {
    print_step "사용자 생성 (HTPasswd Identity Provider)"

    # 기존 htpasswd secret 내용 가져오기
    if oc get secret "$HTPASSWD_SECRET" -n openshift-config &>/dev/null; then
        print_info "기존 htpasswd secret 발견 → 사용자 추가"
        oc get secret "$HTPASSWD_SECRET" \
            -n openshift-config \
            -o jsonpath='{.data.htpasswd}' | base64 -d > "$HTPASSWD_TMP"
    else
        print_info "새 htpasswd 파일 생성"
        touch "$HTPASSWD_TMP"
    fi

    # 4명의 사용자 생성/업데이트
    for user in "$USER1" "$USER2" "$USER3" "$USER4"; do
        htpasswd -bB "$HTPASSWD_TMP" "$user" "$DEFAULT_PASS" 2>/dev/null
        print_ok "사용자: ${CYAN}${user}${NC}  (비밀번호: ${DEFAULT_PASS})"
    done

    # htpasswd secret 생성 또는 업데이트
    if oc get secret "$HTPASSWD_SECRET" -n openshift-config &>/dev/null; then
        oc set data secret "$HTPASSWD_SECRET" \
            --from-file=htpasswd="$HTPASSWD_TMP" \
            -n openshift-config
        print_ok "htpasswd secret 업데이트됨"
    else
        oc create secret generic "$HTPASSWD_SECRET" \
            --from-file=htpasswd="$HTPASSWD_TMP" \
            -n openshift-config
        print_ok "htpasswd secret 생성됨"
    fi
    rm -f "$HTPASSWD_TMP"

    # OAuth CR에 HTPasswd IDP 등록 (없으면 추가)
    if oc get oauth cluster \
        -o jsonpath='{.spec.identityProviders[*].name}' 2>/dev/null | \
        tr ' ' '\n' | grep -qx "$HTPASSWD_IDP_NAME"; then
        print_ok "OAuth IDP '${HTPASSWD_IDP_NAME}' 이미 등록됨"
    else
        local idp_json
        idp_json="{\"name\":\"${HTPASSWD_IDP_NAME}\",\"mappingMethod\":\"claim\",\"type\":\"HTPasswd\",\"htpasswd\":{\"fileData\":{\"name\":\"${HTPASSWD_SECRET}\"}}}"

        # 기존 배열에 추가 시도, 실패 시 새 배열 생성
        if ! oc patch oauth cluster --type=json \
            -p="[{\"op\":\"add\",\"path\":\"/spec/identityProviders/-\",\"value\":${idp_json}}]" \
            2>/dev/null; then
            oc patch oauth cluster --type=merge \
                -p="{\"spec\":{\"identityProviders\":[${idp_json}]}}"
        fi
        print_ok "OAuth IDP '${HTPASSWD_IDP_NAME}' 등록됨"
        print_warn "인증 operator 재시작에 1-2분 소요됩니다."
    fi
}

# =============================================================================
step_namespaces() {
    print_step "Namespace 생성"

    for ns in "$NS1" "$NS2"; do
        if oc get namespace "$ns" &>/dev/null; then
            print_warn "Namespace가 이미 존재합니다: $ns"
        else
            oc create namespace "$ns"
            print_ok "Namespace 생성됨: ${CYAN}${ns}${NC}"
        fi
    done
}

# =============================================================================
step_rbac() {
    print_step "RBAC 구성"

    # RoleBinding (namespace 범위) — ClusterRoleBinding (클러스터 전체)이 아님
    # admin/view ClusterRole을 특정 NS에만 바인딩 → 해당 NS의 리소스에만 접근 가능
    # 다른 namespace에는 권한 없음
    echo ""
    printf "  %-10s  %-30s  %-12s  %s\n" "사용자" "Namespace" "역할" "VM 생성"
    echo "  ──────────────────────────────────────────────────────────────"

    oc adm policy add-role-to-user admin "$USER1" -n "$NS1" 2>/dev/null
    printf "  %-10s  %-30s  %-12s  %s\n" "$USER1" "$NS1" "admin" "가능"
    print_ok "${USER1} → ${NS1} [admin]  — VM 생성 가능"

    oc adm policy add-role-to-user view "$USER2" -n "$NS1" 2>/dev/null
    printf "  %-10s  %-30s  %-12s  %s\n" "$USER2" "$NS1" "view" "불가"
    print_ok "${USER2} → ${NS1} [view]   — 읽기 전용, VM 생성 불가"

    oc adm policy add-role-to-user admin "$USER3" -n "$NS2" 2>/dev/null
    printf "  %-10s  %-30s  %-12s  %s\n" "$USER3" "$NS2" "admin" "가능"
    print_ok "${USER3} → ${NS2} [admin]  — VM 생성 가능"

    oc adm policy add-role-to-user view "$USER4" -n "$NS2" 2>/dev/null
    printf "  %-10s  %-30s  %-12s  %s\n" "$USER4" "$NS2" "view" "불가"
    print_ok "${USER4} → ${NS2} [view]   — 읽기 전용, VM 생성 불가"

    # DataSource 참조 권한 — VM 생성자(admin 사용자)에게만 view 권한 부여
    # VM 생성 시 openshift-virtualization-os-images의 DataSource를 sourceRef로 사용하므로
    oc adm policy add-role-to-user view "$USER1" -n "$DATASOURCE_NS" 2>/dev/null
    print_ok "${USER1} → ${DATASOURCE_NS} [view] (DataSource 참조용)"

    oc adm policy add-role-to-user view "$USER3" -n "$DATASOURCE_NS" 2>/dev/null
    print_ok "${USER3} → ${DATASOURCE_NS} [view] (DataSource 참조용)"
}

# =============================================================================
create_vm() {
    local ns="$1"
    local vm_name="$2"

    if oc get vm "$vm_name" -n "$ns" &>/dev/null; then
        print_warn "VM이 이미 존재합니다: ${vm_name} (${ns})"
        return 0
    fi

    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc Template을 찾을 수 없습니다 — ${vm_name} 생성을 건너뜁니다. (먼저 01-template을 실행하세요)"
        return 0
    fi

    local vm_yaml="${SCRIPT_DIR}/${vm_name}.yaml"
    oc process -n openshift poc -p NAME="$vm_name" | \
        sed 's/runStrategy: Halted/runStrategy: Always/' | \
        sed 's/  running: false/  runStrategy: Always/' > "${vm_yaml}"
    echo "생성된 파일: ${vm_yaml}"
    oc apply -n "$ns" -f "${vm_yaml}"
    virtctl start "$vm_name" -n "$ns" 2>/dev/null || true
    print_ok "VM 생성 및 시작됨: ${CYAN}${vm_name}${NC} (namespace: ${ns})"
}

step_vms() {
    print_step "VM 생성 (namespace당 1개)"

    # DataSource 존재 확인
    if ! oc get datasource "$DATASOURCE_NAME" -n "$DATASOURCE_NS" &>/dev/null; then
        print_warn "DataSource '${DATASOURCE_NAME}' (${DATASOURCE_NS})을(를) 찾을 수 없습니다"
        print_info "먼저 01-template 단계를 실행하거나 DATASOURCE_NAME 변수를 변경하세요."
        print_info "VM 생성을 건너뜁니다."
        return 0
    fi

    # StorageClass 자동 감지
    if [ -z "${STORAGE_CLASS:-}" ]; then
        STORAGE_CLASS=$(oc get sc \
            -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' \
            2>/dev/null | awk '{print $1}' || true)
        [ -n "$STORAGE_CLASS" ] && print_info "StorageClass 자동 감지됨: ${STORAGE_CLASS}"
    fi

    create_vm "$NS1" "poc-mt-vm-1"
    create_vm "$NS2" "poc-mt-vm-2"

    # 시작 대기
    echo ""
    print_info "VM 시작 대기 중 (최대 5분)..."
    local retries=30
    local i=0
    while [ "$i" -lt "$retries" ]; do
        local s1 s2
        s1=$(oc get vmi poc-mt-vm-1 -n "$NS1" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "-")
        s2=$(oc get vmi poc-mt-vm-2 -n "$NS2" \
            -o jsonpath='{.status.phase}' 2>/dev/null || echo "-")

        if [ "$s1" = "Running" ] && [ "$s2" = "Running" ]; then
            echo ""
            print_ok "poc-mt-vm-1 (${NS1}) → Running"
            print_ok "poc-mt-vm-2 (${NS2}) → Running"
            break
        fi
        printf "  대기 중... mt1=%s  mt2=%s  (%d/%d)\r" \
            "$s1" "$s2" "$((i+1))" "$retries"
        sleep 10
        i=$((i+1))
    done
    echo ""
}

# =============================================================================
step_verify() {
    print_step "검증"

    echo ""
    print_info "━━ Namespace ━━"
    oc get namespace "$NS1" "$NS2" --no-headers \
        -o custom-columns='NAME:.metadata.name,STATUS:.status.phase'

    echo ""
    print_info "━━ RoleBinding ━━"
    for ns in "$NS1" "$NS2"; do
        echo "  [${ns}]"
        oc get rolebindings -n "$ns" --no-headers \
            -o custom-columns='BINDING:.metadata.name,ROLE:.roleRef.name,SUBJECT:.subjects[0].name' \
            2>/dev/null | grep -E "user[1-4]" | \
            awk '{printf "    %-35s %-10s %s\n", $1, $2, $3}' || true
    done

    echo ""
    print_info "━━ VM ━━"
    oc get vm -n "$NS1" -n "$NS2" \
        -o custom-columns='NAME:.metadata.name,NS:.metadata.namespace,STATUS:.status.printableStatus' \
        2>/dev/null || \
    { oc get vm -n "$NS1" 2>/dev/null; oc get vm -n "$NS2" 2>/dev/null; } || true
}

# =============================================================================
cleanup() {
    print_step "정리"

    print_info "VM 삭제 중..."
    oc delete vm poc-mt-vm-1 -n "$NS1" --ignore-not-found
    oc delete vm poc-mt-vm-2 -n "$NS2" --ignore-not-found

    print_info "Namespace 삭제 중 (RoleBinding 포함)..."
    oc delete namespace "$NS1" --ignore-not-found
    oc delete namespace "$NS2" --ignore-not-found

    print_info "DataSource NS RoleBinding 삭제 중..."
    for user in "$USER1" "$USER3"; do
        oc adm policy remove-role-from-user view "$user" \
            -n "$DATASOURCE_NS" 2>/dev/null || true
    done

    print_info "User / Identity 오브젝트 삭제 중..."
    for user in "$USER1" "$USER2" "$USER3" "$USER4"; do
        oc delete user "$user" --ignore-not-found 2>/dev/null || true
        oc delete identity "${HTPASSWD_IDP_NAME}:${user}" --ignore-not-found 2>/dev/null || true
    done

    print_ok "정리 완료"
    print_warn "htpasswd secret과 OAuth IDP 설정은 수동으로 삭제하세요."
    print_cmd "oc delete secret ${HTPASSWD_SECRET} -n openshift-config"
}

# =============================================================================
print_summary() {
    local api_url console_url
    api_url=$(oc whoami --show-server 2>/dev/null || echo "")
    console_url=$(oc get route console -n openshift-console \
        -o jsonpath='{.spec.host}' 2>/dev/null || echo "<console-url>")

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! 멀티 테넌트 환경 구성이 완료되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${CYAN}━━ 사용자 / 권한 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "  %-8s  %-28s  %-8s  %-10s  %s\n" "사용자" "Namespace" "역할" "VM 생성" "비밀번호"
    echo "  ──────────────────────────────────────────────────────────────────────"
    printf "  %-8s  %-28s  %-8s  %-10s  %s\n" "$USER1" "$NS1" "admin" "가능" "$DEFAULT_PASS"
    printf "  %-8s  %-28s  %-8s  %-10s  %s\n" "$USER2" "$NS1" "view"  "불가"  "$DEFAULT_PASS"
    printf "  %-8s  %-28s  %-8s  %-10s  %s\n" "$USER3" "$NS2" "admin" "가능" "$DEFAULT_PASS"
    printf "  %-8s  %-28s  %-8s  %-10s  %s\n" "$USER4" "$NS2" "view"  "불가"  "$DEFAULT_PASS"
    echo ""
    echo -e "  ${CYAN}━━ Console 로그인 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  URL: ${BLUE}https://${console_url}${NC}"
    echo -e "  IDP: ${CYAN}${HTPASSWD_IDP_NAME}${NC}"
    echo ""
    echo -e "  ${CYAN}━━ CLI 전환 테스트 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  # user1 — ${NS1} admin (VM 생성 가능)"
    echo -e "  ${CYAN}oc login -u ${USER1} -p '${DEFAULT_PASS}' ${api_url}${NC}"
    echo -e "  ${CYAN}oc get vm -n ${NS1}${NC}           # 성공"
    echo -e "  ${CYAN}oc get vm -n ${NS2}${NC}           # 거부됨 (권한 없음)"
    echo ""
    echo -e "  # user2 — ${NS1} view (VM 생성 불가)"
    echo -e "  ${CYAN}oc login -u ${USER2} -p '${DEFAULT_PASS}' ${api_url}${NC}"
    echo -e "  ${CYAN}oc get vm -n ${NS1}${NC}           # 성공 (읽기)"
    echo -e "  ${CYAN}oc create -f vm.yaml -n ${NS1}${NC} # 거부됨 (view 전용)"
    echo ""
    echo -e "  # user3 — ${NS2} admin (VM 생성 가능)"
    echo -e "  ${CYAN}oc login -u ${USER3} -p '${DEFAULT_PASS}' ${api_url}${NC}"
    echo -e "  ${CYAN}oc get vm -n ${NS2}${NC}           # 성공"
    echo -e "  ${CYAN}oc get vm -n ${NS1}${NC}           # 거부됨 (권한 없음)"
    echo ""
    echo -e "  # user4 — ${NS2} view (VM 생성 불가)"
    echo -e "  ${CYAN}oc login -u ${USER4} -p '${DEFAULT_PASS}' ${api_url}${NC}"
    echo -e "  ${CYAN}oc get vm -n ${NS2}${NC}           # 성공 (읽기)"
    echo -e "  ${CYAN}oc create -f vm.yaml -n ${NS2}${NC} # 거부됨 (view 전용)"
    echo ""
    echo -e "  자세한 내용: 04-multitenancy.md 참조"
    echo ""
}

# =============================================================================
main() {
    if [ "${1:-}" = "--cleanup" ]; then
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}  04-multitenancy: 정리 모드${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        preflight
        cleanup
        return 0
    fi

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  04-multitenancy: 멀티 테넌트 VM 환경 구성${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_users
    step_namespaces
    step_rbac
    step_vms
    step_verify
    print_summary
}

main "$@"
