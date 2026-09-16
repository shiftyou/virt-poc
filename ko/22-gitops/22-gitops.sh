#!/bin/bash
# =============================================================================
# 22-gitops.sh
#
# VM GitOps 관리 구성
#   1. 대상 namespace의 VM 정의를 export (런타임 필드 제거)
#   2. Git 저장소 구성 및 push
#   3. ArgoCD Application 생성하여 GitOps 관리 시작
#
# 사용법: ./22-gitops.sh [namespace]
#   옵션:
#     --cleanup [namespace]   ArgoCD Application 및 관련 리소스 삭제
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
fi

ARGOCD_NS="${ARGOCD_NS:-openshift-gitops}"
TARGET_NS=""
GIT_REPO_URL=""
VM_LIST=""
VM_COUNT=0
OUTPUT_DIR=""

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

    if ! oc get namespace "$ARGOCD_NS" &>/dev/null; then
        print_error "OpenShift GitOps가 설치되어 있지 않습니다 (${ARGOCD_NS} namespace 없음)"
        print_info "설치: OperatorHub → Red Hat OpenShift GitOps"
        exit 1
    fi
    local argocd_ready
    argocd_ready=$(oc get pods -n "$ARGOCD_NS" \
        -l app.kubernetes.io/name=openshift-gitops-server \
        --no-headers 2>/dev/null | grep -c "Running" || true)
    if [ "$argocd_ready" -lt 1 ]; then
        print_warn "ArgoCD 서버 Pod가 실행 중이지 않을 수 있습니다"
    else
        print_ok "OpenShift GitOps (ArgoCD) 확인됨"
    fi

    if ! command -v python3 &>/dev/null; then
        print_error "python3이 필요합니다 (VM 정의 정리용)"
        exit 1
    fi

    if ! command -v git &>/dev/null; then
        print_error "git이 필요합니다"
        exit 1
    fi

    # 대상 namespace
    local ns_arg="${1:-}"
    if [ -n "$ns_arg" ] && [[ "$ns_arg" != --* ]]; then
        TARGET_NS="$ns_arg"
    else
        echo ""
        read -r -p "$(echo -e "${YELLOW}  VM이 있는 namespace를 입력하세요: ${NC}")" TARGET_NS
    fi

    if [ -z "$TARGET_NS" ]; then
        print_error "Namespace를 입력해야 합니다"
        exit 1
    fi

    if ! oc get namespace "$TARGET_NS" &>/dev/null; then
        print_error "Namespace '${TARGET_NS}'를 찾을 수 없습니다"
        exit 1
    fi

    VM_LIST=$(oc get vm -n "$TARGET_NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -z "$VM_LIST" ]; then
        print_error "Namespace '${TARGET_NS}'에 VM이 없습니다"
        exit 1
    fi

    VM_COUNT=$(echo "$VM_LIST" | wc -w | tr -d ' ')
    print_ok "Namespace '${TARGET_NS}'에서 ${VM_COUNT}개의 VM 발견"
    for vm in $VM_LIST; do
        local _status
        _status=$(oc get vm "$vm" -n "$TARGET_NS" \
            -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
        echo -e "    ${DIM}${vm} (${_status})${NC}"
    done

    OUTPUT_DIR="${SCRIPT_DIR}/gitops-${TARGET_NS}"
}

# =============================================================================
# 1/3  VM 정의 Export
# =============================================================================
step_export_vms() {
    print_step "1/3  VM 정의 Export"

    mkdir -p "$OUTPUT_DIR"

    local exported=0
    for vm in $VM_LIST; do
        print_info "${vm} 추출 중..."
        oc get vm "$vm" -n "$TARGET_NS" -o json | python3 -c "
import json, sys

obj = json.load(sys.stdin)
meta = obj.get('metadata', {})

for k in ['uid', 'resourceVersion', 'creationTimestamp', 'generation',
          'managedFields', 'selfLink', 'finalizers']:
    meta.pop(k, None)

annots = meta.get('annotations', {})
for k in list(annots):
    if any(x in k for x in [
        'kubectl.kubernetes.io',
        'kubevirt.io/latest-observed-api-version',
        'kubevirt.io/storage-observed-api-version',
    ]):
        del annots[k]
if not annots:
    meta.pop('annotations', None)

obj.pop('status', None)

for dvt in obj.get('spec', {}).get('dataVolumeTemplates', []):
    dvt.pop('status', None)
    dm = dvt.get('metadata', {})
    for k in ['uid', 'resourceVersion', 'creationTimestamp', 'generation']:
        dm.pop(k, None)

try:
    import yaml
    yaml.dump(obj, sys.stdout, default_flow_style=False, allow_unicode=True)
except ImportError:
    json.dump(obj, sys.stdout, indent=2, ensure_ascii=False)
    print()
" > "${OUTPUT_DIR}/${vm}.yaml"
        exported=$((exported + 1))
    done

    print_ok "${exported}개의 VM 정의를 ${OUTPUT_DIR}/ 에 저장"
}

# =============================================================================
# 2/3  Git 저장소 설정
# =============================================================================
step_git_repo() {
    print_step "2/3  Git 저장소 설정"

    cd "$OUTPUT_DIR"

    if [ ! -d .git ]; then
        git init -b main > /dev/null 2>&1
        print_ok "Git 저장소 초기화됨"
    fi

    git add -A
    if git diff --cached --quiet 2>/dev/null; then
        print_info "변경 사항이 없습니다 — 커밋 건너뜀"
        cd "$SCRIPT_DIR"
        return
    fi
    git commit -m "Export ${VM_COUNT} VM(s) from namespace ${TARGET_NS}" > /dev/null
    print_ok "VM 매니페스트 커밋됨"

    # Gitea 감지
    echo ""
    local gitea_host=""
    gitea_host=$(oc get route -A \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.host}{"\n"}{end}' \
        2>/dev/null | grep -i gitea | head -1 | awk '{print $2}' || true)

    if [ -n "$gitea_host" ]; then
        print_info "클러스터 내 Gitea 감지됨: https://${gitea_host}"
        echo -e "    ${DIM}예: https://${gitea_host}/<사용자>/gitops-${TARGET_NS}.git${NC}"
        echo ""
    fi

    read -r -p "$(echo -e "${YELLOW}  Git 원격 저장소 URL (비워두면 건너뜀): ${NC}")" GIT_REPO_URL

    if [ -n "$GIT_REPO_URL" ]; then
        git remote remove origin 2>/dev/null || true
        git remote add origin "$GIT_REPO_URL"

        print_info "Push 시도 중..."
        if GIT_SSL_VERIFY=false git push -u origin main 2>&1; then
            print_ok "원격 저장소에 push 완료"
        else
            print_warn "Push 실패 — 저장소 생성 여부 및 인증 정보를 확인하세요"
            print_info "수동 push:"
            echo -e "    ${CYAN}cd $(pwd) && GIT_SSL_VERIFY=false git push -u origin main${NC}"
        fi
    else
        print_warn "원격 저장소를 설정하지 않았습니다"
        print_info "나중에 설정하려면:"
        echo -e "    ${CYAN}cd $(pwd)${NC}"
        echo -e "    ${CYAN}git remote add origin <URL>${NC}"
        echo -e "    ${CYAN}git push -u origin main${NC}"
    fi

    cd "$SCRIPT_DIR"
}

# =============================================================================
# 3/3  ArgoCD Application 생성
# =============================================================================
step_argocd_app() {
    print_step "3/3  ArgoCD Application 생성"

    local app_name="gitops-${TARGET_NS}"

    if [ -z "${GIT_REPO_URL:-}" ]; then
        print_warn "Git 원격 저장소가 없어 ArgoCD Application 생성을 건너뜁니다"
        echo ""
        print_info "원격 저장소 설정 후 아래 YAML로 Application을 생성하세요:"
        echo ""
        cat <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${app_name}
  namespace: ${ARGOCD_NS}
spec:
  project: default
  source:
    repoURL: <GIT_REPO_URL>
    targetRevision: HEAD
    path: .
  destination:
    server: https://kubernetes.default.svc
    namespace: ${TARGET_NS}
  syncPolicy:
    syncOptions:
      - CreateNamespace=false
      - ServerSideApply=true
EOF
        return
    fi

    # ArgoCD 관리 레이블 추가
    oc label namespace "$TARGET_NS" \
        argocd.argoproj.io/managed-by="$ARGOCD_NS" --overwrite 2>/dev/null || true
    print_ok "Namespace '${TARGET_NS}' ArgoCD 관리 레이블 추가됨"

    local app_file="${SCRIPT_DIR}/argocd-app-${TARGET_NS}.yaml"
    cat > "$app_file" <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: ${app_name}
  namespace: ${ARGOCD_NS}
spec:
  project: default
  source:
    repoURL: ${GIT_REPO_URL}
    targetRevision: HEAD
    path: .
  destination:
    server: https://kubernetes.default.svc
    namespace: ${TARGET_NS}
  syncPolicy:
    syncOptions:
      - CreateNamespace=false
      - ServerSideApply=true
EOF

    echo "생성된 파일: ${app_file}"
    oc apply -f "$app_file"
    print_ok "ArgoCD Application '${app_name}' 생성됨"

    local argocd_host
    argocd_host=$(oc get route openshift-gitops-server -n "$ARGOCD_NS" \
        -o jsonpath='{.spec.host}' 2>/dev/null || true)
    if [ -n "$argocd_host" ]; then
        print_info "ArgoCD 콘솔: https://${argocd_host}"
    fi
}

# =============================================================================
# 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! VM GitOps 관리 환경이 구성되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  대상 Namespace : ${CYAN}${TARGET_NS}${NC}"
    echo -e "  관리 대상 VM   : ${CYAN}${VM_COUNT}개${NC}"
    echo -e "  매니페스트 경로: ${CYAN}${OUTPUT_DIR}/${NC}"
    if [ -n "${GIT_REPO_URL:-}" ]; then
        echo -e "  Git 저장소     : ${CYAN}${GIT_REPO_URL}${NC}"
        echo -e "  ArgoCD App     : ${CYAN}gitops-${TARGET_NS}${NC}"
    fi
    echo ""
    echo -e "  ${YELLOW}GitOps 워크플로우:${NC}"
    echo -e "    1. ${OUTPUT_DIR}/ 의 VM YAML 파일을 수정"
    echo -e "    2. git commit & push"
    echo -e "    3. ArgoCD에서 Sync 실행 (또는 자동 동기화 설정)"
    echo ""
    echo -e "  ${YELLOW}유용한 명령어:${NC}"
    echo -e "    ${CYAN}# ArgoCD Application 상태 확인${NC}"
    echo -e "    ${CYAN}oc get application gitops-${TARGET_NS} -n ${ARGOCD_NS}${NC}"
    echo ""
    echo -e "    ${CYAN}# VM 변경 후 git push${NC}"
    echo -e "    ${CYAN}cd ${OUTPUT_DIR} && git add -A && git commit -m 'Update VMs' && git push${NC}"
    echo ""
    echo -e "    ${CYAN}# ArgoCD CLI로 수동 Sync${NC}"
    echo -e "    ${CYAN}argocd app sync gitops-${TARGET_NS}${NC}"
    echo ""
    echo -e "  ${YELLOW}주의사항:${NC}"
    echo -e "    - GitOps 관리 시작 후에는 Git을 통해 VM을 변경하세요"
    echo -e "    - 콘솔/CLI로 직접 변경하면 ArgoCD에서 'OutOfSync'로 표시됩니다"
    echo -e "    - DataVolume은 최초 생성 시에만 필요하며, 이후 PVC로 대체됩니다"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    local ns_arg="${1:-}"
    if [ -z "$ns_arg" ] || [[ "$ns_arg" == --* ]]; then
        echo ""
        read -r -p "$(echo -e "${YELLOW}  정리할 namespace를 입력하세요: ${NC}")" ns_arg
    fi

    if [ -z "$ns_arg" ]; then
        print_error "Namespace를 입력해야 합니다"
        exit 1
    fi

    print_step "--cleanup: gitops-${ns_arg} 리소스 삭제"

    oc delete application "gitops-${ns_arg}" -n "$ARGOCD_NS" \
        --ignore-not-found 2>/dev/null || true
    oc label namespace "$ns_arg" argocd.argoproj.io/managed-by- \
        2>/dev/null || true
    rm -f "${SCRIPT_DIR}/argocd-app-${ns_arg}.yaml"

    if [ -d "${SCRIPT_DIR}/gitops-${ns_arg}" ]; then
        read -r -p "  로컬 디렉터리 gitops-${ns_arg}/도 삭제하시겠습니까? [y/N]: " _del
        if [[ "${_del:-}" == "y" || "${_del:-}" == "Y" ]]; then
            rm -rf "${SCRIPT_DIR}/gitops-${ns_arg}"
            print_ok "로컬 디렉터리 삭제됨"
        fi
    fi

    print_ok "GitOps 리소스 삭제됨 (namespace: ${ns_arg})"
}

# =============================================================================
# main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  VM GitOps 관리 구성${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${DIM}  virt-poc ${POC_VERSION}${NC}"

    preflight "$@"
    step_export_vms
    step_git_repo
    step_argocd_app
    print_summary
}

if [ "${1:-}" = "--cleanup" ]; then
    cleanup "${2:-}"
    exit 0
fi
main "$@"
