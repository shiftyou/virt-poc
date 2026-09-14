#!/bin/bash
# =============================================================================
# 22-gitops.sh
#
# VM GitOps Management Setup
#   1. Export VM definitions from target namespace (strip runtime fields)
#   2. Set up Git repository and push
#   3. Create ArgoCD Application for GitOps management
#
# Usage: ./22-gitops.sh [namespace]
#   Options:
#     --cleanup [namespace]   Remove ArgoCD Application and related resources
# =============================================================================

set -euo pipefail
trap 'echo -e "\n\033[0;31m[ERROR]\033[0m Command failed at line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

if [ -f "${SCRIPT_DIR}/../utils/common.sh" ]; then
    source "${SCRIPT_DIR}/../utils/common.sh"
else
    # ── Standalone mode: inline helpers without common.sh ──
    RED='\033[0;31m'; GREEN='\033[0;32m'; DIM='\033[2m'
    YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
    print_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
    print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
    print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
    print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
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
# Preflight checks
# =============================================================================
preflight() {
    print_step "Preflight checks"

    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to OpenShift."
        exit 1
    fi
    print_ok "Cluster connection: $(oc whoami) @ $(oc whoami --show-server)"

    if ! oc get namespace "$ARGOCD_NS" &>/dev/null; then
        print_error "OpenShift GitOps is not installed (${ARGOCD_NS} namespace not found)"
        print_info "Install: OperatorHub → Red Hat OpenShift GitOps"
        exit 1
    fi
    local argocd_ready
    argocd_ready=$(oc get pods -n "$ARGOCD_NS" \
        -l app.kubernetes.io/name=openshift-gitops-server \
        --no-headers 2>/dev/null | grep -c "Running" || true)
    if [ "$argocd_ready" -lt 1 ]; then
        print_warn "ArgoCD server pod may not be running"
    else
        print_ok "OpenShift GitOps (ArgoCD) verified"
    fi

    if ! command -v python3 &>/dev/null; then
        print_error "python3 is required (for cleaning VM definitions)"
        exit 1
    fi

    if ! command -v git &>/dev/null; then
        print_error "git is required"
        exit 1
    fi

    # Target namespace
    local ns_arg="${1:-}"
    if [ -n "$ns_arg" ] && [[ "$ns_arg" != --* ]]; then
        TARGET_NS="$ns_arg"
    else
        echo ""
        read -r -p "$(echo -e "${YELLOW}  Enter namespace containing VMs: ${NC}")" TARGET_NS
    fi

    if [ -z "$TARGET_NS" ]; then
        print_error "Namespace is required"
        exit 1
    fi

    if ! oc get namespace "$TARGET_NS" &>/dev/null; then
        print_error "Namespace '${TARGET_NS}' not found"
        exit 1
    fi

    VM_LIST=$(oc get vm -n "$TARGET_NS" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    if [ -z "$VM_LIST" ]; then
        print_error "No VMs found in namespace '${TARGET_NS}'"
        exit 1
    fi

    VM_COUNT=$(echo "$VM_LIST" | wc -w | tr -d ' ')
    print_ok "Found ${VM_COUNT} VM(s) in namespace '${TARGET_NS}'"
    for vm in $VM_LIST; do
        local _status
        _status=$(oc get vm "$vm" -n "$TARGET_NS" \
            -o jsonpath='{.status.printableStatus}' 2>/dev/null || echo "Unknown")
        echo -e "    ${DIM}${vm} (${_status})${NC}"
    done

    OUTPUT_DIR="${SCRIPT_DIR}/gitops-${TARGET_NS}"
}

# =============================================================================
# 1/3  Export VM definitions
# =============================================================================
step_export_vms() {
    print_step "1/3  Export VM definitions"

    mkdir -p "$OUTPUT_DIR"

    local exported=0
    for vm in $VM_LIST; do
        print_info "Exporting: ${vm}..."
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

    print_ok "Exported ${exported} VM definition(s) to ${OUTPUT_DIR}/"
}

# =============================================================================
# 2/3  Git repository setup
# =============================================================================
step_git_repo() {
    print_step "2/3  Git repository setup"

    cd "$OUTPUT_DIR"

    if [ ! -d .git ]; then
        git init -b main > /dev/null 2>&1
        print_ok "Git repository initialized"
    fi

    git add -A
    if git diff --cached --quiet 2>/dev/null; then
        print_info "No changes to commit — skipping"
        cd "$SCRIPT_DIR"
        return
    fi
    git commit -m "Export ${VM_COUNT} VM(s) from namespace ${TARGET_NS}" > /dev/null
    print_ok "VM manifests committed"

    # Detect Gitea
    echo ""
    local gitea_host=""
    gitea_host=$(oc get route -A \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.host}{"\n"}{end}' \
        2>/dev/null | grep -i gitea | head -1 | awk '{print $2}' || true)

    if [ -n "$gitea_host" ]; then
        print_info "In-cluster Gitea detected: https://${gitea_host}"
        echo -e "    ${DIM}e.g. https://${gitea_host}/<user>/gitops-${TARGET_NS}.git${NC}"
        echo ""
    fi

    read -r -p "$(echo -e "${YELLOW}  Git remote URL (leave empty to skip): ${NC}")" GIT_REPO_URL

    if [ -n "$GIT_REPO_URL" ]; then
        git remote remove origin 2>/dev/null || true
        git remote add origin "$GIT_REPO_URL"

        print_info "Pushing..."
        if GIT_SSL_VERIFY=false git push -u origin main 2>&1; then
            print_ok "Pushed to remote repository"
        else
            print_warn "Push failed — check that the repository exists and credentials are correct"
            print_info "Manual push:"
            echo -e "    ${CYAN}cd $(pwd) && GIT_SSL_VERIFY=false git push -u origin main${NC}"
        fi
    else
        print_warn "Remote repository not configured"
        print_info "To configure later:"
        echo -e "    ${CYAN}cd $(pwd)${NC}"
        echo -e "    ${CYAN}git remote add origin <URL>${NC}"
        echo -e "    ${CYAN}git push -u origin main${NC}"
    fi

    cd "$SCRIPT_DIR"
}

# =============================================================================
# 3/3  Create ArgoCD Application
# =============================================================================
step_argocd_app() {
    print_step "3/3  Create ArgoCD Application"

    local app_name="gitops-${TARGET_NS}"

    if [ -z "${GIT_REPO_URL:-}" ]; then
        print_warn "No Git remote — skipping ArgoCD Application creation"
        echo ""
        print_info "After configuring the remote, create the Application with this YAML:"
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

    # Add ArgoCD management label
    oc label namespace "$TARGET_NS" \
        argocd.argoproj.io/managed-by="$ARGOCD_NS" --overwrite 2>/dev/null || true
    print_ok "Namespace '${TARGET_NS}' labeled for ArgoCD management"

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

    echo "Generated file: ${app_file}"
    oc apply -f "$app_file"
    print_ok "ArgoCD Application '${app_name}' created"

    local argocd_host
    argocd_host=$(oc get route openshift-gitops-server -n "$ARGOCD_NS" \
        -o jsonpath='{.spec.host}' 2>/dev/null || true)
    if [ -n "$argocd_host" ]; then
        print_info "ArgoCD console: https://${argocd_host}"
    fi
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! VM GitOps management is configured.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Target Namespace : ${CYAN}${TARGET_NS}${NC}"
    echo -e "  Managed VMs      : ${CYAN}${VM_COUNT}${NC}"
    echo -e "  Manifest path    : ${CYAN}${OUTPUT_DIR}/${NC}"
    if [ -n "${GIT_REPO_URL:-}" ]; then
        echo -e "  Git repository   : ${CYAN}${GIT_REPO_URL}${NC}"
        echo -e "  ArgoCD App       : ${CYAN}gitops-${TARGET_NS}${NC}"
    fi
    echo ""
    echo -e "  ${YELLOW}GitOps workflow:${NC}"
    echo -e "    1. Edit VM YAML files in ${OUTPUT_DIR}/"
    echo -e "    2. git commit & push"
    echo -e "    3. Sync in ArgoCD (or configure auto-sync)"
    echo ""
    echo -e "  ${YELLOW}Useful commands:${NC}"
    echo -e "    ${CYAN}# Check ArgoCD Application status${NC}"
    echo -e "    ${CYAN}oc get application gitops-${TARGET_NS} -n ${ARGOCD_NS}${NC}"
    echo ""
    echo -e "    ${CYAN}# Push VM changes${NC}"
    echo -e "    ${CYAN}cd ${OUTPUT_DIR} && git add -A && git commit -m 'Update VMs' && git push${NC}"
    echo ""
    echo -e "    ${CYAN}# Manual sync via ArgoCD CLI${NC}"
    echo -e "    ${CYAN}argocd app sync gitops-${TARGET_NS}${NC}"
    echo ""
    echo -e "  ${YELLOW}Notes:${NC}"
    echo -e "    - After enabling GitOps, make VM changes through Git"
    echo -e "    - Direct changes via console/CLI will show as 'OutOfSync' in ArgoCD"
    echo -e "    - DataVolumes are only needed at initial creation; they become PVCs afterward"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    local ns_arg="${1:-}"
    if [ -z "$ns_arg" ] || [[ "$ns_arg" == --* ]]; then
        echo ""
        read -r -p "$(echo -e "${YELLOW}  Enter namespace to clean up: ${NC}")" ns_arg
    fi

    if [ -z "$ns_arg" ]; then
        print_error "Namespace is required"
        exit 1
    fi

    print_step "--cleanup: Remove gitops-${ns_arg} resources"

    oc delete application "gitops-${ns_arg}" -n "$ARGOCD_NS" \
        --ignore-not-found 2>/dev/null || true
    oc label namespace "$ns_arg" argocd.argoproj.io/managed-by- \
        2>/dev/null || true
    rm -f "${SCRIPT_DIR}/argocd-app-${ns_arg}.yaml"

    if [ -d "${SCRIPT_DIR}/gitops-${ns_arg}" ]; then
        read -r -p "  Also delete local directory gitops-${ns_arg}/? [y/N]: " _del
        if [[ "${_del:-}" == "y" || "${_del:-}" == "Y" ]]; then
            rm -rf "${SCRIPT_DIR}/gitops-${ns_arg}"
            print_ok "Local directory deleted"
        fi
    fi

    print_ok "GitOps resources removed (namespace: ${ns_arg})"
}

# =============================================================================
# main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  VM GitOps Management Setup${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

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
