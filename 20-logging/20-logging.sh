#!/bin/bash
# =============================================================================
# 20-logging.sh
#
# OpenShift Audit Logging Configuration
# APIServer Audit Policy setup + collection/forwarding through OpenShift Logging Operator
#
#   1. Select and configure APIServer Audit Policy
#   2. Check OpenShift Logging Operator
#   3. Create ClusterLogging instance
#   4. Create LokiStack (when Loki Operator installed, using Garage S3)
#   5. Configure ClusterLogForwarder (including Audit logs)
#   6. Status check
#
# Usage: ./20-logging.sh
# =============================================================================

set -euo pipefail

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

# Object Storage (S3) — dedicated for LokiStack (determined by source in preflight)
S3_ENDPOINT=""
S3_BUCKET=""
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
S3_REGION=""

AUDIT_PROFILE=""
HAS_LOGGING=false
HAS_LOKI=false
LOGGING_V6=false

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

print_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERR ]${NC} $1"; }
print_step()  { echo -e "\n${CYAN}━━━ $1 ━━━${NC}"; }

# Preview YAML and apply after confirmation
confirm_and_apply() {
    local file="$1"
    echo ""
    print_info "YAML to apply:"
    echo "────────────────────────────────────────"
    cat "$file"
    echo "────────────────────────────────────────"
    read -r -p "Apply the above YAML to the cluster? [y/N]: " confirm
    [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { print_warn "Cancelled."; exit 0; }
    oc apply -f "$file"
}

# =============================================================================
# Select Audit Policy profile
# =============================================================================
choose_audit_profile() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Select APIServer Audit Policy profile${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} Default"
    echo -e "     Record metadata only (URL, HTTP Method, response code, user, time)."
    echo -e "     No request/response body. Minimum log volume."
    echo ""
    echo -e "  ${GREEN}2)${NC} WriteRequestBodies  ${YELLOW}[Recommended]${NC}"
    echo -e "     Record write request (create/update/patch/delete) bodies."
    echo -e "     Sufficient for audit purposes, excludes read request bodies."
    echo ""
    echo -e "  ${GREEN}3)${NC} AllRequestBodies"
    echo -e "     Record all request/response bodies. Most detailed but significantly increases log volume."
    echo -e "     May include sensitive information (Secret values, etc.) — use with caution."
    echo ""
    echo -e "  ${GREEN}4)${NC} None"
    echo -e "     Disable Audit logging. ${RED}Does not meet security recommendations.${NC}"
    echo ""
    read -r -p "  Select [1-4, default: 2]: " choice
    choice="${choice:-2}"

    case "$choice" in
        1) AUDIT_PROFILE="Default" ;;
        2) AUDIT_PROFILE="WriteRequestBodies" ;;
        3) AUDIT_PROFILE="AllRequestBodies" ;;
        4) AUDIT_PROFILE="None" ;;
        *)
            print_error "Please enter a value between 1 and 4."
            exit 1
            ;;
    esac
    print_ok "Selected: Audit Profile = ${AUDIT_PROFILE}"
}

# =============================================================================
# Pre-flight check
# =============================================================================
preflight() {
    print_step "Pre-flight Check"

    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to OpenShift."
        exit 1
    fi
    print_ok "Cluster access: $(oc whoami) @ $(oc whoami --show-server)"

    # Check OpenShift Logging Operator
    if [ "${LOGGING_INSTALLED:-false}" = "true" ]; then
        HAS_LOGGING=true
        print_ok "OpenShift Logging Operator confirmed"
    else
        HAS_LOGGING=false
        print_warn "OpenShift Logging Operator not installed → skipping."
        print_warn "  Installation guide: operators/"
        exit 77
    fi

    # Check Loki Operator
    if [ "${LOKI_INSTALLED:-false}" = "true" ]; then
        HAS_LOKI=true
        print_ok "Loki Operator confirmed"

        # Determine S3 initial values: Garage first, then ODF, then empty (manual input)
        if [ -n "${GARAGE_ENDPOINT:-}" ]; then
            S3_ENDPOINT="${GARAGE_ENDPOINT}"
            S3_BUCKET="${LOGGING_S3_BUCKET:-${GARAGE_BUCKET:-loki}}"
            S3_ACCESS_KEY="${GARAGE_ACCESS_KEY:-}"
            S3_SECRET_KEY="${GARAGE_SECRET_KEY:-}"
            S3_REGION="${LOGGING_S3_REGION:-garage}"
        elif [ -n "${ODF_S3_ENDPOINT:-}" ]; then
            S3_ENDPOINT="${ODF_S3_ENDPOINT}"
            S3_BUCKET="(OBC auto-generated — determined in step_loki_obc)"
            S3_ACCESS_KEY="${ODF_S3_ACCESS_KEY:-}"
            S3_SECRET_KEY="${ODF_S3_SECRET_KEY:-}"
            S3_REGION="${LOGGING_S3_REGION:-${ODF_S3_REGION:-us-east-1}}"
        else
            S3_ENDPOINT="${LOGGING_S3_ENDPOINT:-}"
            S3_BUCKET="${LOGGING_S3_BUCKET:-loki}"
            S3_ACCESS_KEY="${LOGGING_S3_ACCESS_KEY:-}"
            S3_SECRET_KEY="${LOGGING_S3_SECRET_KEY:-}"
            S3_REGION="${LOGGING_S3_REGION:-us-east-1}"
            print_warn "Object Storage auto-detection failed — please enter manually below."
        fi

        # Check and re-enter Object Storage info
        echo ""
        print_info "── Object Storage (S3) — dedicated for LokiStack ──"
        print_info "  S3 Endpoint  : ${S3_ENDPOINT:-(not set)}"
        print_info "  S3 Bucket    : ${S3_BUCKET}"
        print_info "  S3 Region    : ${S3_REGION}"
        print_info "  S3 AccessKey : ${S3_ACCESS_KEY:-(not set)}"
        print_info "  S3 SecretKey : ****"
        echo ""
        read -r -p "  Is the above information correct? (Y/n): " _confirm
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
        print_ok "Object Storage configuration confirmed (bucket: ${S3_BUCKET})"
    else
        HAS_LOKI=false
        print_warn "Loki Operator not installed → skipping LokiStack creation."
        if [ "$HAS_LOGGING" = "true" ]; then
            print_warn "  → ClusterLogForwarder will use default output only without Loki."
        fi
    fi

    # Detect Logging version (ClusterLogging CRD removed in v6)
    if ! oc get crd clusterloggings.logging.openshift.io &>/dev/null; then
        LOGGING_V6=true
        print_ok "OpenShift Logging v6 detected (using observability.openshift.io/v1)"
    else
        LOGGING_V6=false
        print_ok "OpenShift Logging v5 detected (using logging.openshift.io/v1)"
    fi
}

# =============================================================================
# Step 1: Configure APIServer Audit Policy
# =============================================================================
step_audit_policy() {
    print_step "1/5  APIServer Audit Policy Configuration (profile: ${AUDIT_PROFILE})"

    local current
    current=$(oc get apiserver cluster -o jsonpath='{.spec.audit.profile}' 2>/dev/null || echo "")
    if [ "${current}" = "${AUDIT_PROFILE}" ]; then
        print_ok "The same profile is already applied (${AUDIT_PROFILE}) — skipping."
        return
    fi
    [ -n "$current" ] && print_info "Current profile: ${current} → Change to: ${AUDIT_PROFILE}"

    cat > ./audit-policy.yaml <<EOF
apiVersion: config.openshift.io/v1
kind: APIServer
metadata:
  name: cluster
spec:
  audit:
    profile: ${AUDIT_PROFILE}
EOF

    confirm_and_apply ./audit-policy.yaml
    print_ok "Audit Policy applied successfully"
    print_info "kube-apiserver rollout may take several minutes."
    print_info "  Check: oc get co kube-apiserver"
}

# =============================================================================
# Step 2: Verify openshift-logging namespace
# =============================================================================
step_namespace() {
    print_step "2/5  Verify openshift-logging Namespace"

    if oc get namespace "${LOGGING_NS}" &>/dev/null; then
        print_ok "Namespace ${LOGGING_NS} exists"
    else
        print_error "Namespace ${LOGGING_NS} does not exist."
        print_error "  It will be created automatically when OpenShift Logging Operator is properly installed."
        print_error "  Check the operators/ installation guide."
        exit 1
    fi
}

# =============================================================================
# Step 3: Create ClusterLogging instance
# =============================================================================
step_cluster_logging() {
    print_step "3/5  Create ClusterLogging Instance"

    if [ "$LOGGING_V6" = "true" ]; then
        print_info "Logging v6 — no ClusterLogging CR, skipping."
        return
    fi

    if oc get clusterlogging "${CL_NAME}" -n "${LOGGING_NS}" &>/dev/null; then
        print_ok "ClusterLogging '${CL_NAME}' already exists — skipping."
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
        # Omit logStore block when Loki is not present (Vector collection only)
        log_store_block="  # logStore: omitted because Loki Operator is not installed"
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

    confirm_and_apply ./cluster-logging.yaml
    print_ok "ClusterLogging '${CL_NAME}' created successfully"
}

# =============================================================================
# Step 4a: Create OBC for dedicated Loki bucket when ODF backend is used
# =============================================================================
step_loki_obc() {
    # Skip if not ODF
    [ -z "${ODF_S3_ENDPOINT:-}" ] && [ -z "${GARAGE_ENDPOINT:-}" ] && return
    [ -n "${GARAGE_ENDPOINT:-}" ] && return   # OBC not needed for Garage

    print_step "4a  Create ObjectBucketClaim dedicated for Loki"

    if oc get obc obc-loki -n "${LOGGING_NS}" &>/dev/null; then
        print_ok "OBC obc-loki already exists — retrieving bucket name"
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
        echo "Generated file: obc-loki.yaml"
        oc apply -f ./obc-loki.yaml
        print_ok "OBC obc-loki created successfully"
    fi

    # Wait for Bound
    print_info "Waiting for OBC to be Bound..."
    local i=0
    while [ $i -lt 12 ]; do
        local phase
        phase=$(oc get obc obc-loki -n "${LOGGING_NS}" \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        [ "$phase" = "Bound" ] && break
        printf "  [%d/12] Waiting... (%s)\r" "$((i+1))" "${phase:-Pending}"
        sleep 5
        i=$((i+1))
    done
    echo ""
    if [ $i -eq 12 ]; then
        print_error "OBC Bound timed out."
        exit 1
    fi
    print_ok "OBC status: Bound"

    # Retrieve bucket name and credentials
    S3_BUCKET=$(oc get cm obc-loki -n "${LOGGING_NS}" \
        -o jsonpath='{.data.BUCKET_NAME}' 2>/dev/null || true)
    S3_ACCESS_KEY=$(oc get secret obc-loki -n "${LOGGING_NS}" \
        -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d || true)
    S3_SECRET_KEY=$(oc get secret obc-loki -n "${LOGGING_NS}" \
        -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d || true)
    print_ok "Loki OBC bucket/credentials retrieved successfully"
    print_info "  Bucket : ${S3_BUCKET}"
}

# =============================================================================
# Step 4: Create LokiStack + S3 Secret (when Loki Operator is installed)
# =============================================================================
step_loki_secret() {
    if oc get secret logging-loki-s3 -n "${LOGGING_NS}" &>/dev/null; then
        print_ok "S3 Secret 'logging-loki-s3' already exists."
        return
    fi

    if [ -z "${S3_ENDPOINT}" ] || [ -z "${S3_ACCESS_KEY}" ]; then
        print_error "Object Storage information is missing. Please enter S3 information in the preflight step."
        exit 1
    fi

    oc create secret generic logging-loki-s3 \
        -n "${LOGGING_NS}" \
        --from-literal=access_key_id="${S3_ACCESS_KEY}" \
        --from-literal=access_key_secret="${S3_SECRET_KEY}" \
        --from-literal=bucketnames="${S3_BUCKET}" \
        --from-literal=endpoint="${S3_ENDPOINT}" \
        --from-literal=region="${S3_REGION}"
    print_ok "S3 Secret 'logging-loki-s3' created successfully"
    print_info "  endpoint : ${S3_ENDPOINT}"
    print_info "  bucket   : ${S3_BUCKET}"
}

step_loki_stack() {
    print_step "4/5  Create LokiStack"

    if oc get lokistack "${LOKI_NAME}" -n "${LOGGING_NS}" &>/dev/null; then
        print_ok "LokiStack '${LOKI_NAME}' already exists — skipping."
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

    confirm_and_apply ./loki-stack.yaml

    # Reduce resources for POC environment (LokiStack CRD does not support resource override → patch StatefulSet directly)
    # Default 1x.small: ingester cpu=4/mem=20Gi → causes Pending due to insufficient CPU on worker nodes
    print_info "Reducing LokiStack StatefulSet resources (POC environment)..."
    sleep 5  # Wait for StatefulSet creation
    oc patch statefulset "${LOKI_NAME}-ingester" -n "${LOGGING_NS}" --type=json -p '[
      {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"500m"},
      {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"2Gi"}
    ]' 2>/dev/null && print_ok "ingester resource reduction complete" || print_warn "ingester patch failed (manual application required)"
    oc patch statefulset "${LOKI_NAME}-compactor" -n "${LOGGING_NS}" --type=json -p '[
      {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"200m"},
      {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"512Mi"}
    ]' 2>/dev/null && print_ok "compactor resource reduction complete" || print_warn "compactor patch failed (manual application required)"
    oc patch deployment "${LOKI_NAME}-query-frontend" -n "${LOGGING_NS}" --type=json -p '[
      {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"200m"},
      {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"512Mi"}
    ]' 2>/dev/null && print_ok "query-frontend resource reduction complete" || print_warn "query-frontend patch failed (manual application required)"

    print_info "Waiting for LokiStack to be ready (up to 5 minutes)..."
    local retries=30 i=0
    while [ "$i" -lt "$retries" ]; do
        local phase
        phase=$(oc get lokistack "${LOKI_NAME}" -n "${LOGGING_NS}" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [ "$phase" = "True" ]; then
            print_ok "LokiStack '${LOKI_NAME}' Ready"
            break
        fi
        printf "  [%d/%d] Waiting...\r" "$((i+1))" "$retries"
        sleep 10
        i=$((i+1))
    done
    echo ""
    [ "$i" -eq "$retries" ] && print_warn "LokiStack ready timed out. Check status: oc get lokistack -n ${LOGGING_NS}"
}

# =============================================================================
# Step 5: ClusterLogForwarder (including Audit logs)
# =============================================================================
step_log_forwarder() {
    print_step "5/5  Configure ClusterLogForwarder (audit + infrastructure + application)"

    if oc get clusterlogforwarder "${CLF_NAME}" -n "${LOGGING_NS}" &>/dev/null; then
        print_warn "ClusterLogForwarder '${CLF_NAME}' already exists."
        read -r -p "Overwrite the existing configuration? [y/N]: " overwrite
        [[ "$overwrite" != "y" && "$overwrite" != "Y" ]] && { print_info "Skipping."; return; }
    fi

    if [ "$LOGGING_V6" = "true" ]; then
        # v6: observability.openshift.io/v1, ServiceAccount required
        if ! oc get serviceaccount collector -n "${LOGGING_NS}" &>/dev/null; then
            oc create serviceaccount collector -n "${LOGGING_NS}"
            print_ok "ServiceAccount collector created"
        fi
        # Node log collection permissions
        for role in collect-application-logs collect-infrastructure-logs collect-audit-logs; do
            oc adm policy add-cluster-role-to-user "${role}" \
                -z collector -n "${LOGGING_NS}" 2>/dev/null || true
        done
        # LokiStack write permissions (returns 403 from gateway without this)
        for role in \
            cluster-logging-write-application-logs \
            cluster-logging-write-infrastructure-logs \
            cluster-logging-write-audit-logs \
            logging-collector-logs-writer; do
            oc adm policy add-cluster-role-to-user "${role}" \
                -z collector -n "${LOGGING_NS}" 2>/dev/null || true
        done
        print_ok "collector ServiceAccount permissions granted (collection + Loki write)"

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

    confirm_and_apply ./cluster-log-forwarder.yaml
    print_ok "ClusterLogForwarder '${CLF_NAME}' applied successfully"
}

# =============================================================================
# Enable Console Plugin (show Observe > Logs menu)
# =============================================================================
step_console_plugin() {
    print_step "6/6  Enable Console Plugin (Observe > Logs)"

    if [ "$LOGGING_V6" = "true" ]; then
        # v6: UIPlugin CR (safe as it does not touch the console.operator plugins array)
        if oc get uiplugin logging &>/dev/null; then
            print_ok "UIPlugin 'logging' already exists — skipping."
            return
        fi

        if ! oc get crd uiplugins.observability.openshift.io &>/dev/null; then
            print_warn "UIPlugin CRD not found — cluster-observability-operator not installed"
            print_info "  Install 'Cluster Observability Operator' from OperatorHub and re-run."
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
        print_ok "UIPlugin 'logging' created successfully"
        print_info "  The Observe > Logs menu will appear after reloading the Console."
    else
        # v5: consoleplugin method — append to existing plugins list (do not overwrite)
        if ! oc get consoleplugin logging-view-plugin &>/dev/null; then
            print_warn "logging-view-plugin ConsolePlugin does not exist."
            print_info "  OpenShift Logging Operator will create it automatically."
            print_info "    oc get consoleplugin"
            return
        fi
        print_ok "logging-view-plugin ConsolePlugin confirmed"

        local _enabled
        _enabled=$(oc get console.operator.openshift.io cluster \
            -o jsonpath='{.spec.plugins}' 2>/dev/null || echo "")
        if echo "${_enabled}" | grep -q "logging-view-plugin"; then
            print_ok "logging-view-plugin already enabled"
            return
        fi

        # Initialize /spec/plugins array if not present, then append
        if ! echo "${_enabled}" | grep -q '\['; then
            oc patch console.operator.openshift.io cluster --type=merge \
                -p '{"spec":{"plugins":[]}}' 2>/dev/null || true
        fi
        oc patch console.operator.openshift.io cluster --type=json \
            -p '[{"op":"add","path":"/spec/plugins/-","value":"logging-view-plugin"}]'
        print_ok "logging-view-plugin enabled successfully"
        print_info "  The Observe > Logs menu will appear after reloading the Console."
    fi
}

# =============================================================================
# Status check
# =============================================================================
step_verify() {
    print_step "Status Check"

    echo ""
    echo -e "${CYAN}  [ APIServer Audit Policy ]${NC}"
    oc get apiserver cluster -o jsonpath='    profile: {.spec.audit.profile}{"\n"}' 2>/dev/null || \
        echo "    (unable to check)"

    echo ""
    echo -e "${CYAN}  [ kube-apiserver Cluster Operator ]${NC}"
    oc get co kube-apiserver 2>/dev/null | \
        awk 'NR==1{printf "    %-30s %-10s %-12s %-12s\n",$1,$2,$3,$4} NR>1{printf "    %-30s %-10s %-12s %-12s\n",$1,$2,$3,$4}' || true

    if [ "$HAS_LOGGING" = "true" ]; then
        echo ""
        echo -e "${CYAN}  [ ClusterLogging ]${NC}"
        oc get clusterlogging -n "${LOGGING_NS}" 2>/dev/null | \
            awk '{printf "    %s\n", $0}' || echo "    (none)"

        echo ""
        echo -e "${CYAN}  [ ClusterLogForwarder ]${NC}"
        oc get clusterlogforwarder -n "${LOGGING_NS}" 2>/dev/null | \
            awk '{printf "    %s\n", $0}' || echo "    (none)"

        if [ "$HAS_LOKI" = "true" ]; then
            echo ""
            echo -e "${CYAN}  [ LokiStack ]${NC}"
            oc get lokistack -n "${LOGGING_NS}" 2>/dev/null | \
                awk '{printf "    %s\n", $0}' || echo "    (none)"
        fi

        echo ""
        echo -e "${CYAN}  [ Collector Pods ]${NC}"
        oc get pods -n "${LOGGING_NS}" -l component=collector 2>/dev/null | \
            awk '{printf "    %s\n", $0}' || echo "    (none)"
    fi

    echo ""
    print_info "Real-time Audit log check (example):"
    echo -e "    ${CYAN}oc adm node-logs --role=master --path=kube-apiserver/ | grep audit${NC}"
    if [ "$HAS_LOGGING" = "true" ]; then
        echo -e "    ${CYAN}oc logs -n ${LOGGING_NS} -l component=collector --tail=20${NC}"
    fi
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Delete 20-logging resources"
    local _logging_ns="openshift-logging"
    oc delete clusterlogforwarder --all -n "$_logging_ns" --ignore-not-found 2>/dev/null || true
    oc delete clusterlogging instance -n "$_logging_ns" --ignore-not-found 2>/dev/null || true
    oc delete lokistack logging-loki -n "$_logging_ns" --ignore-not-found 2>/dev/null || true
    oc delete secret logging-loki-s3 -n "$_logging_ns" --ignore-not-found 2>/dev/null || true
    oc delete obc obc-loki -n "$_logging_ns" --ignore-not-found 2>/dev/null || true
    print_ok "20-logging resources deleted successfully"
    print_info "  Namespace ${_logging_ns} is managed by Logging Operator and will not be deleted."
}

# =============================================================================
# main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  OpenShift Audit Logging Configuration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    choose_audit_profile
    preflight

    step_audit_policy

    if [ "$HAS_LOGGING" = "true" ]; then
        step_namespace
        step_cluster_logging
        if [ "$HAS_LOKI" = "true" ]; then
            step_loki_stack
        else
            print_step "4/5  Create LokiStack"
            print_warn "Loki Operator not installed — skipping."
        fi
        step_log_forwarder
        step_console_plugin
    else
        print_step "3/5  ClusterLogging"
        print_warn "OpenShift Logging Operator not installed — skipping."
        print_step "4/5  LokiStack"
        print_warn "OpenShift Logging Operator not installed — skipping."
        print_step "5/5  ClusterLogForwarder"
        print_warn "OpenShift Logging Operator not installed — skipping."
    fi

    step_verify

    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Audit Logging configuration complete${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  [Sample] Check who logged in and when${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${YELLOW}* Query from OpenShift Console → Observe → Logs after Loki collection is complete${NC}"
    echo ""
    echo -e "  ${GREEN}1) OAuth login events (token issuance = login point)${NC}"
    echo -e "     ${CYAN}{log_type=\"audit\"} | json | requestURI=~\"/apis/oauth.openshift.io/v1/oauthaccesstokens.*\" | verb=\"create\"${NC}"
    echo ""
    echo -e "  ${GREEN}2) Recent logins by user (by username)${NC}"
    echo -e "     ${CYAN}{log_type=\"audit\"} | json | requestURI=~\"/apis/oauth.openshift.io/v1/oauthaccesstokens.*\" | verb=\"create\" | line_format \"{{.requestReceivedTimestamp}} {{.user_username}}\"${NC}"
    echo ""
    echo -e "  ${GREEN}3) Filter by specific user login${NC}"
    echo -e "     ${CYAN}{log_type=\"audit\"} | json | requestURI=~\"/apis/oauth.openshift.io/v1/oauthaccesstokens.*\" | verb=\"create\" | user_username=\"admin\"${NC}"
    echo ""
    echo -e "  ${GREEN}4) Login failures (HTTP 401/403)${NC}"
    echo -e "     ${CYAN}{log_type=\"audit\"} | json | requestURI=~\"/apis/oauth.openshift.io/v1/oauthaccesstokens.*\" | responseStatus_code=~\"40[13]\"${NC}"
    echo ""
    echo -e "  ${GREEN}5) CLI method: Check directly from node Audit logs (Loki not required)${NC}"
    echo -e "     ${CYAN}oc adm node-logs --role=master --path=oauth-server/ | grep '\"verb\":\"create\"' | grep oauthaccesstokens | awk -F'\"' '{print \$4, \$8}'${NC}"
    echo ""
    echo -e "  ${YELLOW}Query field descriptions${NC}"
    echo -e "    requestReceivedTimestamp : Request timestamp (ISO 8601)"
    echo -e "    user.username            : Logged-in username"
    echo -e "    sourceIPs                : Source IP of the connection"
    echo -e "    responseStatus.code      : HTTP response code (201=success, 401=auth failure, 403=forbidden)"
    echo ""
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main "$@"
