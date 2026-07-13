#!/bin/bash
# =============================================================================
# 04-multitenancy.sh
#
# Multi-tenant VM environment configuration
#   - Create 2 namespaces (poc-multitenancy-1, poc-multitenancy-2)
#   - user1: poc-multitenancy-1 admin  → can create VMs
#   - user2: poc-multitenancy-1 view   → cannot create VMs (read-only)
#   - user3: poc-multitenancy-2 admin  → can create VMs
#   - user4: poc-multitenancy-2 view   → cannot create VMs (read-only)
#   - Create 1 VM per namespace (using poc template)
#
# Usage: ./04-multitenancy.sh [--cleanup]
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
# Configuration
# =============================================================================
NS1="poc-multitenancy-1"
NS2="poc-multitenancy-2"

USER1="user1"   # NS1 admin (can create VMs)
USER2="user2"   # NS1 view  (read-only, cannot create VMs)
USER3="user3"   # NS2 admin (can create VMs)
USER4="user4"   # NS2 view  (read-only, cannot create VMs)

DEFAULT_PASS="Redhat1!"

HTPASSWD_SECRET="htpasswd-secret"
HTPASSWD_IDP_NAME="poc-htpasswd"
HTPASSWD_TMP="/tmp/poc-htpasswd-$$"

DATASOURCE_NS="${DATASOURCE_NS:-openshift-virtualization-os-images}"
DATASOURCE_NAME="${DATASOURCE_NAME:-poc-golden}"
STORAGE_CLASS="${STORAGE_CLASS:-}"

# =============================================================================
preflight() {
    print_step "Pre-flight checks"

    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift."
        exit 1
    fi
    print_ok "Cluster connection: $(oc whoami) @ $(oc whoami --show-server)"

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator not installed → skipping."
        print_warn "  Installation guide: operators/kubevirt-hyperconverged-operator.md"
        exit 77
    fi
    print_ok "OpenShift Virtualization Operator confirmed"

    if ! command -v htpasswd &>/dev/null; then
        print_error "htpasswd command not found."
        print_info "Install: dnf install -y httpd-tools"
        exit 1
    fi
    print_ok "htpasswd command confirmed"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc Template not found — VMs will not be created. (Run 01-template first)"
    else
        print_ok "poc Template confirmed"
    fi
}

# =============================================================================
step_users() {
    print_step "Create users (HTPasswd Identity Provider)"

    # Get existing htpasswd secret content
    if oc get secret "$HTPASSWD_SECRET" -n openshift-config &>/dev/null; then
        print_info "Existing htpasswd secret found → adding users"
        oc get secret "$HTPASSWD_SECRET" \
            -n openshift-config \
            -o jsonpath='{.data.htpasswd}' | base64 -d > "$HTPASSWD_TMP"
    else
        print_info "Creating new htpasswd file"
        touch "$HTPASSWD_TMP"
    fi

    # Create/update 4 users
    for user in "$USER1" "$USER2" "$USER3" "$USER4"; do
        htpasswd -bB "$HTPASSWD_TMP" "$user" "$DEFAULT_PASS" 2>/dev/null
        print_ok "User: ${CYAN}${user}${NC}  (password: ${DEFAULT_PASS})"
    done

    # Create or update htpasswd secret
    if oc get secret "$HTPASSWD_SECRET" -n openshift-config &>/dev/null; then
        oc set data secret "$HTPASSWD_SECRET" \
            --from-file=htpasswd="$HTPASSWD_TMP" \
            -n openshift-config
        print_ok "htpasswd secret updated"
    else
        oc create secret generic "$HTPASSWD_SECRET" \
            --from-file=htpasswd="$HTPASSWD_TMP" \
            -n openshift-config
        print_ok "htpasswd secret created"
    fi
    rm -f "$HTPASSWD_TMP"

    # Register HTPasswd IDP in OAuth CR (add if not present)
    if oc get oauth cluster \
        -o jsonpath='{.spec.identityProviders[*].name}' 2>/dev/null | \
        tr ' ' '\n' | grep -qx "$HTPASSWD_IDP_NAME"; then
        print_ok "OAuth IDP '${HTPASSWD_IDP_NAME}' already registered"
    else
        local idp_json
        idp_json="{\"name\":\"${HTPASSWD_IDP_NAME}\",\"mappingMethod\":\"claim\",\"type\":\"HTPasswd\",\"htpasswd\":{\"fileData\":{\"name\":\"${HTPASSWD_SECRET}\"}}}"

        # Try to append to existing array, fallback to creating new array
        if ! oc patch oauth cluster --type=json \
            -p="[{\"op\":\"add\",\"path\":\"/spec/identityProviders/-\",\"value\":${idp_json}}]" \
            2>/dev/null; then
            oc patch oauth cluster --type=merge \
                -p="{\"spec\":{\"identityProviders\":[${idp_json}]}}"
        fi
        print_ok "OAuth IDP '${HTPASSWD_IDP_NAME}' registered"
        print_warn "Authentication operator restart will take 1-2 minutes."
    fi
}

# =============================================================================
step_namespaces() {
    print_step "Create namespaces"

    for ns in "$NS1" "$NS2"; do
        if oc get namespace "$ns" &>/dev/null; then
            print_warn "Namespace already exists: $ns"
        else
            oc create namespace "$ns"
            print_ok "Namespace created: ${CYAN}${ns}${NC}"
        fi
    done
}

# =============================================================================
step_rbac() {
    print_step "Configure RBAC"

    # RoleBinding (namespace-scoped) — not ClusterRoleBinding (cluster-wide)
    # Bind admin/view ClusterRole to specific NS only → access only to resources in that NS
    # No permissions in other namespaces
    echo ""
    printf "  %-10s  %-30s  %-12s  %s\n" "User" "Namespace" "Role" "Create VM"
    echo "  ──────────────────────────────────────────────────────────────"

    oc adm policy add-role-to-user admin "$USER1" -n "$NS1" 2>/dev/null
    printf "  %-10s  %-30s  %-12s  %s\n" "$USER1" "$NS1" "admin" "Yes"
    print_ok "${USER1} → ${NS1} [admin]  — can create VMs"

    oc adm policy add-role-to-user view "$USER2" -n "$NS1" 2>/dev/null
    printf "  %-10s  %-30s  %-12s  %s\n" "$USER2" "$NS1" "view" "No"
    print_ok "${USER2} → ${NS1} [view]   — read-only, cannot create VMs"

    oc adm policy add-role-to-user admin "$USER3" -n "$NS2" 2>/dev/null
    printf "  %-10s  %-30s  %-12s  %s\n" "$USER3" "$NS2" "admin" "Yes"
    print_ok "${USER3} → ${NS2} [admin]  — can create VMs"

    oc adm policy add-role-to-user view "$USER4" -n "$NS2" 2>/dev/null
    printf "  %-10s  %-30s  %-12s  %s\n" "$USER4" "$NS2" "view" "No"
    print_ok "${USER4} → ${NS2} [view]   — read-only, cannot create VMs"

    # DataSource reference permissions — grant view permission only to admin users (VM creators)
    # since they use DataSource in openshift-virtualization-os-images as sourceRef when creating VMs
    oc adm policy add-role-to-user view "$USER1" -n "$DATASOURCE_NS" 2>/dev/null
    print_ok "${USER1} → ${DATASOURCE_NS} [view] (for DataSource reference)"

    oc adm policy add-role-to-user view "$USER3" -n "$DATASOURCE_NS" 2>/dev/null
    print_ok "${USER3} → ${DATASOURCE_NS} [view] (for DataSource reference)"
}

# =============================================================================
create_vm() {
    local ns="$1"
    local vm_name="$2"

    if oc get vm "$vm_name" -n "$ns" &>/dev/null; then
        print_warn "VM already exists: ${vm_name} (${ns})"
        return 0
    fi

    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc Template not found — skipping ${vm_name} creation. (Run 01-template first)"
        return 0
    fi

    local vm_yaml="${SCRIPT_DIR}/${vm_name}.yaml"
    oc process -n openshift poc -p NAME="$vm_name" | \
        sed 's/runStrategy: Halted/runStrategy: Always/' | \
        sed 's/  running: false/  runStrategy: Always/' > "${vm_yaml}"
    echo "Generated file: ${vm_yaml}"
    oc apply -n "$ns" -f "${vm_yaml}"
    virtctl start "$vm_name" -n "$ns" 2>/dev/null || true
    print_ok "VM created and started: ${CYAN}${vm_name}${NC} (namespace: ${ns})"
}

step_vms() {
    print_step "Create VMs (1 per namespace)"

    # Check DataSource existence
    if ! oc get datasource "$DATASOURCE_NAME" -n "$DATASOURCE_NS" &>/dev/null; then
        print_warn "DataSource '${DATASOURCE_NAME}' (${DATASOURCE_NS}) not found"
        print_info "Run 01-template step first or change DATASOURCE_NAME variable."
        print_info "Skipping VM creation."
        return 0
    fi

    # Auto-detect StorageClass
    if [ -z "${STORAGE_CLASS:-}" ]; then
        STORAGE_CLASS=$(oc get sc \
            -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' \
            2>/dev/null | awk '{print $1}' || true)
        [ -n "$STORAGE_CLASS" ] && print_info "StorageClass auto-detected: ${STORAGE_CLASS}"
    fi

    create_vm "$NS1" "poc-mt-vm-1"
    create_vm "$NS2" "poc-mt-vm-2"

    # Wait for startup
    echo ""
    print_info "Waiting for VMs to start (up to 5 minutes)..."
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
        printf "  Waiting... mt1=%s  mt2=%s  (%d/%d)\r" \
            "$s1" "$s2" "$((i+1))" "$retries"
        sleep 10
        i=$((i+1))
    done
    echo ""
}

# =============================================================================
step_verify() {
    print_step "Verification"

    echo ""
    print_info "━━ Namespaces ━━"
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
    print_step "Cleanup"

    print_info "Deleting VMs..."
    oc delete vm poc-mt-vm-1 -n "$NS1" --ignore-not-found
    oc delete vm poc-mt-vm-2 -n "$NS2" --ignore-not-found

    print_info "Deleting namespaces (including RoleBindings)..."
    oc delete namespace "$NS1" --ignore-not-found
    oc delete namespace "$NS2" --ignore-not-found

    print_info "Deleting DataSource NS RoleBindings..."
    for user in "$USER1" "$USER3"; do
        oc adm policy remove-role-from-user view "$user" \
            -n "$DATASOURCE_NS" 2>/dev/null || true
    done

    print_info "Deleting User / Identity objects..."
    for user in "$USER1" "$USER2" "$USER3" "$USER4"; do
        oc delete user "$user" --ignore-not-found 2>/dev/null || true
        oc delete identity "${HTPASSWD_IDP_NAME}:${user}" --ignore-not-found 2>/dev/null || true
    done

    print_ok "Cleanup complete"
    print_warn "Remove htpasswd secret and OAuth IDP settings manually."
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
    echo -e "${GREEN}  Done! Multi-Tenant environment configuration complete.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${CYAN}━━ Users / Permissions ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "  %-8s  %-28s  %-8s  %-10s  %s\n" "User" "Namespace" "Role" "Create VM" "Password"
    echo "  ──────────────────────────────────────────────────────────────────────"
    printf "  %-8s  %-28s  %-8s  %-10s  %s\n" "$USER1" "$NS1" "admin" "Yes" "$DEFAULT_PASS"
    printf "  %-8s  %-28s  %-8s  %-10s  %s\n" "$USER2" "$NS1" "view"  "No"  "$DEFAULT_PASS"
    printf "  %-8s  %-28s  %-8s  %-10s  %s\n" "$USER3" "$NS2" "admin" "Yes" "$DEFAULT_PASS"
    printf "  %-8s  %-28s  %-8s  %-10s  %s\n" "$USER4" "$NS2" "view"  "No"  "$DEFAULT_PASS"
    echo ""
    echo -e "  ${CYAN}━━ Console Login ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  URL: ${BLUE}https://${console_url}${NC}"
    echo -e "  IDP: ${CYAN}${HTPASSWD_IDP_NAME}${NC}"
    echo ""
    echo -e "  ${CYAN}━━ CLI Switch Test ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  # user1 — ${NS1} admin (can create VMs)"
    echo -e "  ${CYAN}oc login -u ${USER1} -p '${DEFAULT_PASS}' ${api_url}${NC}"
    echo -e "  ${CYAN}oc get vm -n ${NS1}${NC}           # success"
    echo -e "  ${CYAN}oc get vm -n ${NS2}${NC}           # denied (no permission)"
    echo ""
    echo -e "  # user2 — ${NS1} view (cannot create VMs)"
    echo -e "  ${CYAN}oc login -u ${USER2} -p '${DEFAULT_PASS}' ${api_url}${NC}"
    echo -e "  ${CYAN}oc get vm -n ${NS1}${NC}           # success (read)"
    echo -e "  ${CYAN}oc create -f poc-mt-vm-1.yaml -n ${NS1}${NC} # denied (view only)"
    echo ""
    echo -e "  # user3 — ${NS2} admin (can create VMs)"
    echo -e "  ${CYAN}oc login -u ${USER3} -p '${DEFAULT_PASS}' ${api_url}${NC}"
    echo -e "  ${CYAN}oc get vm -n ${NS2}${NC}           # success"
    echo -e "  ${CYAN}oc get vm -n ${NS1}${NC}           # denied (no permission)"
    echo ""
    echo -e "  # user4 — ${NS2} view (cannot create VMs)"
    echo -e "  ${CYAN}oc login -u ${USER4} -p '${DEFAULT_PASS}' ${api_url}${NC}"
    echo -e "  ${CYAN}oc get vm -n ${NS2}${NC}           # success (read)"
    echo -e "  ${CYAN}oc create -f poc-mt-vm-2.yaml -n ${NS2}${NC} # denied (view only)"
    echo ""
    echo -e "  For details: refer to 04-multitenancy.md"
    echo ""
}

# =============================================================================
main() {
    if [ "${1:-}" = "--cleanup" ]; then
        echo ""
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        echo -e "${YELLOW}  04-multitenancy: Cleanup mode${NC}"
        echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
        preflight
        cleanup
        return 0
    fi

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  04-multitenancy: Multi-Tenant VM Environment Configuration${NC}"
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
