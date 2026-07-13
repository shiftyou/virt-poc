#!/bin/bash
# =============================================================================
# 14-oadp.sh
#
# OADP lab environment setup
#   1. Verify OADP Operator namespace (default: openshift-adp)
#   2. Create ObjectBucketClaim and obtain bucket/credentials (ODF backend only)
#   3. Create cloud-credentials Secret
#   4. Generate VolumeSnapshotClass YAML (for CSI snapshots, apply as appropriate for storage environment)
#   5. Deploy DataProtectionApplication
#   6. Verify BackupStorageLocation
#   7. Create poc-oadp namespace
#   8. Create poc-oadp VM (using poc DataSource)
#   9. Create Backup CR (poc-oadp backup) + Generate Restore YAML (not applied)
#
# Requirements:
#   - OADP Operator must be installed (default namespace: openshift-adp)
#   - Backend: Garage deployed and configured, or ODF Operator installed
#
# Usage: ./14-oadp.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="${OADP_NS:-openshift-adp}"

# Backend to use: garage | odf (determined in preflight)
BACKEND=""

# Unified S3 variables (set in preflight based on backend)
S3_ENDPOINT=""
S3_BUCKET=""
S3_ACCESS_KEY=""
S3_SECRET_KEY=""
S3_REGION=""
DPA_NAME="poc-dpa"
BSL_NAME="poc-dpa-1"

source "${SCRIPT_DIR}/../utils/common.sh"

GARAGE_DEFAULT_IMAGE="dxflrs/garage:v1.0.1"

install_garage() {
    echo ""
    print_warn "Garage S3 service not found in the cluster."
    read -r -p "  Install Garage S3 storage automatically? (Y/n): " _ans
    if [[ "${_ans:-}" =~ ^[Nn]$ ]]; then
        return 1
    fi

    local garage_image="${GARAGE_DEFAULT_IMAGE}"
    read -r -p "  Garage container image [${garage_image}]: " _input
    [ -n "$_input" ] && garage_image="$_input"
    print_info "Using image: ${garage_image}"

    # Namespace
    if oc get namespace poc-garage &>/dev/null; then
        print_ok "Namespace poc-garage already exists — skipping"
    else
        oc new-project poc-garage > /dev/null
        print_ok "Namespace poc-garage created"
    fi

    # SCC
    oc adm policy add-scc-to-user anyuid -z default -n poc-garage &>/dev/null
    print_ok "anyuid SCC granted to default SA in poc-garage"

    # Deploy resources
    print_info "Deploying Garage resources..."
    oc apply -f - <<EOF
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: garage-data
  namespace: poc-garage
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: garage-meta
  namespace: poc-garage
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Secret
metadata:
  name: garage-credentials
  namespace: poc-garage
type: Opaque
stringData:
  accessKey: "garageadmin"
  secretKey: "garageadmin"
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: garage-config
  namespace: poc-garage
data:
  garage.toml: |
    metadata_dir = "/meta"
    data_dir = "/data"

    replication_factor = 1

    rpc_bind_addr = "[::]:3901"
    rpc_public_addr = "127.0.0.1:3901"
    rpc_secret = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"

    [s3_api]
    s3_region = "garage"
    api_bind_addr = "[::]:3900"
    root_domain = ".s3.garage.localhost"

    [s3_web]
    bind_addr = "[::]:3902"
    root_domain = ".web.garage.localhost"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: garage
  namespace: poc-garage
spec:
  replicas: 1
  selector:
    matchLabels:
      app: garage
  template:
    metadata:
      labels:
        app: garage
    spec:
      containers:
        - name: garage
          image: ${garage_image}
          env:
            - name: GARAGE_RPC_SECRET
              value: "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
          ports:
            - containerPort: 3900
              name: s3-api
            - containerPort: 3902
              name: web
          volumeMounts:
            - name: data
              mountPath: /data
            - name: meta
              mountPath: /meta
            - name: config
              mountPath: /etc/garage.toml
              subPath: garage.toml
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: garage-data
        - name: meta
          persistentVolumeClaim:
            claimName: garage-meta
        - name: config
          configMap:
            name: garage-config
---
apiVersion: v1
kind: Service
metadata:
  name: garage
  namespace: poc-garage
  labels:
    app: garage
spec:
  selector:
    app: garage
  ports:
    - name: s3-api
      port: 3900
      targetPort: 3900
    - name: web
      port: 3902
      targetPort: 3902
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: garage-api
  namespace: poc-garage
spec:
  to:
    kind: Service
    name: garage
  port:
    targetPort: s3-api
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF
    print_ok "Garage resources deployed"

    # Wait for pod
    print_info "Waiting for Garage pod to be ready..."
    if ! oc wait --for=condition=ready pod -l app=garage -n poc-garage --timeout=300s 2>/dev/null; then
        print_error "Garage pod failed to start. Check: oc get pods -n poc-garage"
        return 1
    fi
    print_ok "Garage pod is ready"

    # Configure layout and create bucket
    local garage_pod node_id
    garage_pod=$(oc get pod -n poc-garage -l app=garage -o jsonpath='{.items[0].metadata.name}')

    local id_output
    id_output=$(oc exec -n poc-garage "$garage_pod" -- /garage node id 2>&1 || true)
    # Extract hex node ID before "@"
    node_id=$(echo "$id_output" | grep -oE '[0-9a-f]+@' | head -1 | sed 's/@//')

    if [ -z "$node_id" ]; then
        print_error "Failed to get Garage node ID"
        print_error "  Output: ${id_output}"
        return 1
    fi
    print_info "Garage node ID: ${node_id}"

    oc exec -n poc-garage "$garage_pod" -- /garage layout assign -z dc1 -c 1G "$node_id" 2>&1 || true
    oc exec -n poc-garage "$garage_pod" -- /garage layout apply --version 1 2>&1 || true
    print_ok "Garage layout configured"

    # Create API key (Garage generates GK-prefixed access key + secret)
    local key_output gk_access gk_secret
    key_output=$(oc exec -n poc-garage "$garage_pod" -- /garage key create garageadmin 2>&1 || true)
    gk_access=$(echo "$key_output" | grep -i "Key ID" | awk '{print $NF}')
    gk_secret=$(echo "$key_output" | grep -i "Secret" | awk '{print $NF}')

    if [ -z "$gk_access" ] || [ -z "$gk_secret" ]; then
        print_warn "Key creation output:"
        echo "$key_output"
        print_warn "Could not parse Garage key — using defaults from Secret"
    else
        print_info "Garage key ID: ${gk_access}"
        # Update Secret with actual Garage-generated credentials
        oc create secret generic garage-credentials -n poc-garage \
            --from-literal=accessKey="$gk_access" \
            --from-literal=secretKey="$gk_secret" \
            --dry-run=client -o yaml | oc apply -f - 2>/dev/null
    fi

    # Create bucket and grant access
    oc exec -n poc-garage "$garage_pod" -- /garage bucket create velero 2>&1 || true
    oc exec -n poc-garage "$garage_pod" -- /garage bucket allow --read --write velero --key garageadmin 2>&1 || true
    print_ok "Bucket 'velero' created and access granted"

    print_ok "Garage S3 installation complete"
    return 0
}

preflight() {
    print_step "Pre-flight check"

    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to OpenShift."
        exit 1
    fi
    print_ok "Cluster connection: $(oc whoami) @ $(oc whoami --show-server)"

    # OADP Operator required
    if [ "${OADP_INSTALLED:-false}" != "true" ]; then
        print_warn "OADP Operator not installed → skipping."
        print_warn "  Installation guide: operators/oadp-operator.md"
        exit 77
    fi
    print_ok "OADP Operator confirmed (ns: ${NS})"

    # Determine initial S3 values: Garage preferred, then ODF, then empty (manual input)
    # If env.conf doesn't have S3 info, auto-detect from cluster
    if [ "${GARAGE_INSTALLED:-false}" = "true" ] && [ -n "${GARAGE_ENDPOINT:-}" ]; then
        BACKEND="garage"
        S3_ENDPOINT="${GARAGE_ENDPOINT}"
        S3_BUCKET="${OADP_S3_BUCKET:-${GARAGE_BUCKET:-velero}}"
        S3_ACCESS_KEY="${GARAGE_ACCESS_KEY:-}"
        S3_SECRET_KEY="${GARAGE_SECRET_KEY:-}"
        S3_REGION="${OADP_S3_REGION:-garage}"
    elif [ -z "${GARAGE_ENDPOINT:-}" ]; then
        # No Garage info in env.conf — try live detection
        auto_detect_garage
        if [ "${GARAGE_FOUND}" != "true" ]; then
            if install_garage; then
                auto_detect_garage
            fi
        fi
        if [ "${GARAGE_FOUND}" = "true" ]; then
            BACKEND="garage"
            S3_ENDPOINT="${GARAGE_ENDPOINT}"
            S3_BUCKET="${OADP_S3_BUCKET:-${GARAGE_BUCKET:-velero}}"
            S3_ACCESS_KEY="${GARAGE_ACCESS_KEY:-}"
            S3_SECRET_KEY="${GARAGE_SECRET_KEY:-}"
            S3_REGION="${OADP_S3_REGION:-garage}"
        elif [ "${ODF_INSTALLED:-false}" = "true" ]; then
            auto_detect_odf
            if [ -n "${ODF_S3_ACCESS_KEY:-}" ]; then
                BACKEND="odf"
                S3_ENDPOINT="${ODF_S3_ENDPOINT}"
                S3_BUCKET="(OBC auto-created — determined in step_obc)"
                S3_ACCESS_KEY="${ODF_S3_ACCESS_KEY:-}"
                S3_SECRET_KEY="${ODF_S3_SECRET_KEY:-}"
                S3_REGION="${OADP_S3_REGION:-${ODF_S3_REGION:-us-east-1}}"
            else
                BACKEND="custom"
                S3_ENDPOINT="${OADP_S3_ENDPOINT:-}"
                S3_BUCKET="${OADP_S3_BUCKET:-velero}"
                S3_ACCESS_KEY="${OADP_S3_ACCESS_KEY:-}"
                S3_SECRET_KEY="${OADP_S3_SECRET_KEY:-}"
                S3_REGION="${OADP_S3_REGION:-us-east-1}"
                print_warn "Object Storage auto-detection failed — please enter values below."
            fi
        else
            BACKEND="custom"
            S3_ENDPOINT="${OADP_S3_ENDPOINT:-}"
            S3_BUCKET="${OADP_S3_BUCKET:-velero}"
            S3_ACCESS_KEY="${OADP_S3_ACCESS_KEY:-}"
            S3_SECRET_KEY="${OADP_S3_SECRET_KEY:-}"
            S3_REGION="${OADP_S3_REGION:-us-east-1}"
            print_warn "Object Storage auto-detection failed — please enter values below."
        fi
    elif [ "${ODF_INSTALLED:-false}" = "true" ] && [ -n "${ODF_S3_ENDPOINT:-}" ]; then
        BACKEND="odf"
        S3_ENDPOINT="${ODF_S3_ENDPOINT}"
        S3_BUCKET="(OBC auto-created — determined in step_obc)"
        S3_ACCESS_KEY="${ODF_S3_ACCESS_KEY:-}"
        S3_SECRET_KEY="${ODF_S3_SECRET_KEY:-}"
        S3_REGION="${OADP_S3_REGION:-${ODF_S3_REGION:-us-east-1}}"
    else
        BACKEND="custom"
        S3_ENDPOINT="${OADP_S3_ENDPOINT:-}"
        S3_BUCKET="${OADP_S3_BUCKET:-velero}"
        S3_ACCESS_KEY="${OADP_S3_ACCESS_KEY:-}"
        S3_SECRET_KEY="${OADP_S3_SECRET_KEY:-}"
        S3_REGION="${OADP_S3_REGION:-us-east-1}"
        print_warn "Object Storage auto-detection failed — please enter values below."
    fi

    echo ""
    print_info "── Object Storage (S3) — for OADP backup ──"
    print_info "  Backend     : ${BACKEND}"
    print_info "  S3 Endpoint : ${S3_ENDPOINT:-(not set)}"
    print_info "  S3 Bucket   : ${S3_BUCKET}"
    print_info "  S3 Region   : ${S3_REGION}"
    print_info "  S3 AccessKey: ${S3_ACCESS_KEY:-(not set)}"
    print_info "  S3 SecretKey: ****"
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

    if [ -z "${S3_ENDPOINT}" ] || [ -z "${S3_ACCESS_KEY}" ]; then
        print_error "S3 Endpoint or AccessKey is empty."
        exit 1
    fi
    print_ok "Object Storage configuration confirmed (backend: ${BACKEND}, bucket: ${S3_BUCKET})"

    # Save S3 configuration to env.conf for reuse by other labs (e.g., 20-logging)
    save_to_env "GARAGE_INSTALLED" "${GARAGE_FOUND:-false}"
    save_to_env "GARAGE_ENDPOINT" "${GARAGE_ENDPOINT:-${S3_ENDPOINT}}"
    save_to_env "GARAGE_BUCKET" "${GARAGE_BUCKET:-${S3_BUCKET}}"
    save_to_env "GARAGE_ACCESS_KEY" "${GARAGE_ACCESS_KEY:-${S3_ACCESS_KEY}}"
    save_to_env "GARAGE_SECRET_KEY" "${GARAGE_SECRET_KEY:-${S3_SECRET_KEY}}"
    save_to_env "ODF_S3_ENDPOINT" "${ODF_S3_ENDPOINT:-}"
    save_to_env "ODF_S3_ACCESS_KEY" "${ODF_S3_ACCESS_KEY:-}"
    save_to_env "ODF_S3_SECRET_KEY" "${ODF_S3_SECRET_KEY:-}"
    save_to_env "ODF_S3_REGION" "${ODF_S3_REGION:-us-east-1}"
    save_to_env "OADP_S3_BUCKET" "${S3_BUCKET}"
    save_to_env "OADP_S3_REGION" "${S3_REGION}"
}

# =============================================================================
# Step 1: Verify namespace (OADP Operator installation namespace)
# =============================================================================
step_namespace() {
    print_step "1/6  Verify namespace (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "Namespace $NS confirmed"
    else
        print_error "Namespace $NS not found — please verify OADP Operator is installed."
        print_error "  Installation guide: operators/oadp-operator.md"
        exit 1
    fi
}

# =============================================================================
# Step 2: Create ObjectBucketClaim and obtain bucket/credentials (ODF backend only)
# =============================================================================
step_obc() {
    if [ "$BACKEND" != "odf" ]; then
        print_step "2/6  OBC — Garage backend, skipping"
        return
    fi

    print_step "2/6  Create ObjectBucketClaim (ns: ${NS})"

    # Auto-detect NooBaa StorageClass
    local obc_sc
    obc_sc=$(oc get storageclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
        tr ' ' '\n' | grep -i "noobaa" | head -1 || true)
    if [ -z "$obc_sc" ]; then
        obc_sc="openshift-storage.noobaa.io"
        print_warn "NooBaa StorageClass auto-detection failed → using default: ${obc_sc}"
    else
        print_info "OBC StorageClass: ${obc_sc}"
    fi

    if oc get obc obc-backups -n "$NS" &>/dev/null; then
        print_ok "ObjectBucketClaim obc-backups already exists — skipping"
    else
        cat > obc-backups.yaml <<EOF
apiVersion: objectbucket.io/v1alpha1
kind: ObjectBucketClaim
metadata:
  name: obc-backups
  namespace: ${NS}
spec:
  generateBucketName: backups
  storageClassName: ${obc_sc}
EOF
        echo "Generated file: obc-backups.yaml"
        oc apply -f obc-backups.yaml
        print_ok "ObjectBucketClaim obc-backups created successfully → ns: ${NS}"
    fi

    # Wait for Bound
    print_info "Waiting for OBC to be Bound..."
    local retries=12
    local i=0
    while [ $i -lt $retries ]; do
        local phase
        phase=$(oc get obc obc-backups -n "$NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [ "$phase" = "Bound" ]; then
            print_ok "OBC status: Bound"
            break
        fi
        printf "  [%d/%d] Waiting... (%s)\r" "$((i+1))" "$retries" "${phase:-Pending}"
        sleep 5
        i=$((i+1))
    done
    echo ""

    if [ $i -eq $retries ]; then
        print_error "OBC Bound timed out. Please check ODF/NooBaa status."
        exit 1
    fi

    # Get bucket name from ConfigMap
    # S3_ENDPOINT and S3_REGION retain values from env.conf (ODF_S3_ENDPOINT/REGION)
    S3_BUCKET=$(oc get cm obc-backups -n "$NS" \
        -o jsonpath='{.data.BUCKET_NAME}' 2>/dev/null || true)

    # Get per-bucket credentials from Secret (instead of noobaa-admin)
    S3_ACCESS_KEY=$(oc get secret obc-backups -n "$NS" \
        -o jsonpath='{.data.AWS_ACCESS_KEY_ID}' 2>/dev/null | base64 -d || true)
    S3_SECRET_KEY=$(oc get secret obc-backups -n "$NS" \
        -o jsonpath='{.data.AWS_SECRET_ACCESS_KEY}' 2>/dev/null | base64 -d || true)

    print_ok "OBC bucket/credentials obtained successfully"
    print_info "  Bucket   : ${S3_BUCKET}"
    print_info "  Endpoint : ${S3_ENDPOINT}"
    print_info "  Region   : ${S3_REGION}"
    print_info "  AccessKey: ${S3_ACCESS_KEY}"
}

# =============================================================================
# Step 3: Create cloud-credentials Secret (OADP Operator namespace)
# =============================================================================
step_credentials() {
    print_step "3/6  Create cloud-credentials Secret (backend: ${BACKEND}, ns: ${NS})"

    cat > cloud-credentials-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloud-credentials
  namespace: ${NS}
stringData:
  cloud: |
    [default]
    aws_access_key_id=${S3_ACCESS_KEY}
    aws_secret_access_key=${S3_SECRET_KEY}
EOF
    confirm_and_apply cloud-credentials-secret.yaml
    print_ok "cloud-credentials Secret created successfully → ns: ${NS}"
}

# =============================================================================
# Step 3: Generate VolumeSnapshotClass YAML (for CSI snapshots)
# =============================================================================
step_volumesnapshotclass() {
    print_step "4/6  Generate VolumeSnapshotClass YAML"

    # Auto-detect cluster's CSI driver
    local csi_driver
    csi_driver=$(oc get csidrivers -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
        tr ' ' '\n' | grep -v "^kubernetes\|^csi-snapshot\|^file" | head -1 || true)

    if [ -z "$csi_driver" ]; then
        csi_driver="your.csi.driver.com"
        print_warn "CSI driver auto-detection failed → using default: ${csi_driver}"
        print_warn "  Please update with the actual driver name and apply: oc get csidrivers"
    else
        print_info "CSI driver detected: ${csi_driver}"
    fi

    cat > volumesnapshotclass.yaml <<EOF
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: poc-volumesnapshotclass
  labels:
    velero.io/csi-volumesnapshot-class: "true"
driver: ${csi_driver}
deletionPolicy: Delete
EOF
    echo "Generated file: volumesnapshotclass.yaml"
    print_info "To use CSI snapshots, apply with the following command:"
    echo -e "    ${CYAN}oc apply -f volumesnapshotclass.yaml${NC}"
}

# =============================================================================
# Step 4: Deploy DataProtectionApplication (OADP Operator namespace)
# =============================================================================
step_dpa() {
    print_step "5/6  Deploy DataProtectionApplication (backend: ${BACKEND}, ns: ${NS})"

    # OADP allows only one DPA per namespace — update bucket/credentials if DPA already exists
    local _existing_dpa
    _existing_dpa=$(oc get dpa -n "$NS" --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1 || true)
    if [ -n "$_existing_dpa" ] && [ "$_existing_dpa" != "poc-dpa" ]; then
        print_warn "DPA '${_existing_dpa}' already exists (OADP allows only one DPA per namespace)."
        DPA_NAME="${_existing_dpa}"
        BSL_NAME="${_existing_dpa}-1"
        print_info "Updating bucket/endpoint/credentials for existing DPA '${_existing_dpa}'."

        oc patch dpa "${_existing_dpa}" -n "$NS" --type=json -p="[
          {\"op\":\"replace\",\"path\":\"/spec/backupLocations/0/velero/objectStorage/bucket\",\"value\":\"${S3_BUCKET}\"},
          {\"op\":\"replace\",\"path\":\"/spec/backupLocations/0/velero/config/s3Url\",\"value\":\"${S3_ENDPOINT}\"},
          {\"op\":\"replace\",\"path\":\"/spec/backupLocations/0/velero/config/region\",\"value\":\"${S3_REGION}\"}
        ]" 2>/dev/null && print_ok "DPA bucket/endpoint/region updated successfully" || \
            print_warn "DPA patch failed — manual check required: oc edit dpa ${_existing_dpa} -n ${NS}"
        return
    fi

    if oc get dpa poc-dpa -n "$NS" &>/dev/null; then
        print_ok "DataProtectionApplication poc-dpa already exists — skipping"
        return
    fi

    cat > poc-dpa.yaml <<EOF
apiVersion: oadp.openshift.io/v1alpha1
kind: DataProtectionApplication
metadata:
  name: poc-dpa
  namespace: ${NS}
spec:
  configuration:
    nodeAgent:
      enable: true
      uploaderType: restic
    velero:
      defaultPlugins:
        - aws
        - openshift
        - kubevirt
        - csi
      disableFsBackup: false
  logFormat: text
  backupLocations:
    - velero:
        provider: aws
        default: true
        objectStorage:
          bucket: ${S3_BUCKET}
          prefix: oadp
        config:
          profile: default
          region: ${S3_REGION}
          s3ForcePathStyle: "true"
          s3Url: ${S3_ENDPOINT}
          checksumAlgorithm: ""
        credential:
          key: cloud
          name: cloud-credentials
EOF
    confirm_and_apply poc-dpa.yaml
    print_ok "DataProtectionApplication poc-dpa deployed successfully → ns: ${NS}"
}

# =============================================================================
# Step 5: Verify BackupStorageLocation
# =============================================================================
step_verify() {
    print_step "6/6  Verify BackupStorageLocation (ns: ${NS})"

    # DPA_NAME/BSL_NAME are determined in step_dpa() (may change when reusing existing DPA)

    echo ""
    # Warn if there are other DPAs/BSLs in the namespace
    local other_bsl
    other_bsl=$(oc get backupstoragelocation -n "$NS" \
        --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -v "^${BSL_NAME}$" || true)
    if [ -n "$other_bsl" ]; then
        print_warn "Other BackupStorageLocations detected:"
        echo "$other_bsl" | while read -r b; do
            print_warn "  - ${b} (not created by this script, status irrelevant)"
        done
        echo ""
    fi

    print_info "Connection target information (BSL: ${BSL_NAME}):"
    print_info "  S3 Endpoint : ${S3_ENDPOINT}"
    print_info "  S3 Bucket   : ${S3_BUCKET}"
    print_info "  S3 Region   : ${S3_REGION}"
    echo ""
    print_warn "Note: Common causes of BSL validation failure"
    print_warn "  1) Bucket does not exist — Velero does not auto-create buckets."
    if [ "$BACKEND" = "odf" ]; then
        print_warn "     ODF: Uses bucket name created by OBC (obc-backups) → ${S3_BUCKET}"
    else
        print_warn "     Garage: Create bucket using 'garage bucket create ${S3_BUCKET}' or refer to 14-oadp.md"
    fi
    print_warn "  2) Endpoint unreachable — Velero Pod must be able to reach ${S3_ENDPOINT}."
    print_warn "  3) Credentials error — Check AccessKey / SecretKey"
    echo ""

    print_info "Waiting for BackupStorageLocation to be ready (BSL: ${BSL_NAME})..."
    local retries=18
    local i=0
    while [ $i -lt $retries ]; do
        local phase err_msg
        phase=$(oc get backupstoragelocation "${BSL_NAME}" -n "$NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [ "$phase" = "Available" ]; then
            print_ok "BackupStorageLocation ${BSL_NAME} status: Available"
            oc get backupstoragelocation -n "$NS" 2>/dev/null || true
            return
        fi
        err_msg=$(oc get backupstoragelocation "${BSL_NAME}" -n "$NS" \
            -o jsonpath='{.status.message}' 2>/dev/null || true)
        printf "  [%d/%d] Status: %-12s %s\r" "$((i+1))" "$retries" "${phase:-Pending}" "${err_msg:+| $err_msg}"
        sleep 10
        i=$((i+1))
    done
    echo ""

    print_warn "BackupStorageLocation readiness timed out."
    echo ""
    print_info "Current BSL status:"
    oc get backupstoragelocation -n "$NS" 2>/dev/null || true
    echo ""
    print_info "Check detailed error (${BSL_NAME}):"
    oc describe backupstoragelocation "${BSL_NAME}" -n "$NS" 2>/dev/null | grep -A5 "Status:\|Message:\|Phase:" || true
    echo ""
    print_info "  → oc describe backupstoragelocation ${BSL_NAME} -n ${NS}"
}

# =============================================================================
# Step 7: Create poc-oadp namespace (backup target)
# =============================================================================
VM_NS="poc-oadp"

step_vm_namespace() {
    print_step "7/9  Create backup target namespace (${VM_NS})"

    if oc get namespace "$VM_NS" &>/dev/null; then
        print_ok "Namespace $VM_NS already exists — skipping"
    else
        oc new-project "$VM_NS" > /dev/null
        print_ok "Namespace $VM_NS created successfully"
    fi
}

# =============================================================================
# Step 8: Create VM (poc-oadp, using poc DataSource)
# =============================================================================
step_vm() {
    print_step "8/9  Create VM (ns: ${VM_NS})"

    if oc get vm poc-oadp-vm -n "$VM_NS" &>/dev/null; then
        print_ok "VM poc-oadp-vm already exists — skipping"
        return
    fi

    if ! oc get template poc -n openshift &>/dev/null; then
        print_warn "poc Template not found — skipping VM creation. (Run 01-template first)"
        return
    fi

    local vm_yaml="${SCRIPT_DIR}/poc-oadp-vm.yaml"
    oc process -n openshift poc -p NAME="poc-oadp-vm" | \
        sed 's/  running: false/  runStrategy: Always/' > "${vm_yaml}"
    echo "Generated file: ${vm_yaml}"
    confirm_and_apply "${vm_yaml}"
    print_ok "VM poc-oadp-vm created successfully → ns: ${VM_NS}"
    print_info "  Check VM status: oc get vm -n ${VM_NS}"
}

# =============================================================================
# Step 9: Create Backup CR + Generate Restore YAML (not applied)
# =============================================================================
step_backup() {
    print_step "9/9  Create Backup CR (target: ${VM_NS}, ns: ${NS})"

    # Dynamically detect BSL name (OADP Operator auto-creates based on DPA name, e.g.: poc-dpa-1)
    local bsl_name
    bsl_name=$(oc get backupstoragelocation -n "$NS" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "default")
    print_info "BackupStorageLocation: ${bsl_name}"

    if oc get backup poc-oadp-backup -n "$NS" &>/dev/null; then
        print_ok "Backup poc-oadp-backup already exists — skipping"
    else
        cat > poc-oadp-backup.yaml <<EOF
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: poc-oadp-backup
  namespace: ${NS}
spec:
  includedNamespaces:
    - ${VM_NS}
  storageLocation: ${bsl_name}
  ttl: 720h0m0s
  snapshotVolumes: true
EOF
        confirm_and_apply poc-oadp-backup.yaml
        print_ok "Backup poc-oadp-backup created successfully → ns: ${NS}"
    fi

    # Generate Restore YAML (not applied)
    cat > poc-oadp-restore.yaml <<EOF
apiVersion: velero.io/v1
kind: Restore
metadata:
  name: poc-oadp-restore
  namespace: ${NS}
spec:
  backupName: poc-oadp-backup
  includedNamespaces:
    - ${VM_NS}
  restorePVs: true
EOF
    echo "Generated file: poc-oadp-restore.yaml"
    print_info "To restore, apply with the following command:"
    echo -e "    ${CYAN}oc apply -f poc-oadp-restore.yaml${NC}"
}

step_consoleyamlsamples() {
    print_step "10/10  Register ConsoleYAMLSample"

    cat > consoleyamlsample-dpa.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-dataprotectionapplication
spec:
  title: "POC DataProtectionApplication (OADP)"
  description: "Example DataProtectionApplication using S3-compatible object storage (Garage/ODF) as backup storage. Includes kubevirt, csi, and openshift plugins."
  targetResource:
    apiVersion: oadp.openshift.io/v1alpha1
    kind: DataProtectionApplication
  yaml: |
    apiVersion: oadp.openshift.io/v1alpha1
    kind: DataProtectionApplication
    metadata:
      name: poc-dpa
      namespace: ${NS}
    spec:
      configuration:
        nodeAgent:
          enable: true
          uploaderType: restic
        velero:
          defaultPlugins:
            - aws
            - openshift
            - kubevirt
            - csi
          disableFsBackup: false
      logFormat: text
      backupLocations:
        - velero:
            provider: aws
            default: true
            objectStorage:
              bucket: velero
              prefix: oadp
            config:
              profile: default
              region: us-east-1
              s3ForcePathStyle: "true"
              s3Url: http://garage.garage.svc:3900
              checksumAlgorithm: ""
            credential:
              key: cloud
              name: cloud-credentials
EOF
    oc apply -f consoleyamlsample-dpa.yaml
    print_ok "ConsoleYAMLSample poc-dataprotectionapplication registered successfully"

    cat > consoleyamlsample-backup.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-backup
spec:
  title: "POC Backup (Velero)"
  description: "Example Velero Backup CR for backing up VMs and volumes in a specific namespace. Uses the BSL name auto-created by DataProtectionApplication for storageLocation."
  targetResource:
    apiVersion: velero.io/v1
    kind: Backup
  yaml: |
    apiVersion: velero.io/v1
    kind: Backup
    metadata:
      name: poc-oadp-backup
      namespace: ${NS}
    spec:
      includedNamespaces:
        - poc-oadp
      storageLocation: poc-dpa-1
      ttl: 720h0m0s
      snapshotVolumes: true
EOF
    oc apply -f consoleyamlsample-backup.yaml
    print_ok "ConsoleYAMLSample poc-backup registered successfully"

    cat > consoleyamlsample-restore.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-restore
spec:
  title: "POC Restore (Velero)"
  description: "Example Restore CR for restoring VMs and PVs from a Velero Backup. Apply after backup is complete."
  targetResource:
    apiVersion: velero.io/v1
    kind: Restore
  yaml: |
    apiVersion: velero.io/v1
    kind: Restore
    metadata:
      name: poc-oadp-restore
      namespace: ${NS}
    spec:
      backupName: poc-oadp-backup
      includedNamespaces:
        - poc-oadp
      restorePVs: true
EOF
    oc apply -f consoleyamlsample-restore.yaml
    print_ok "ConsoleYAMLSample poc-restore registered successfully"
}

print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! OADP lab environment is ready.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Backend : ${BACKEND}"
    echo ""
    echo -e "  Check BackupStorageLocation:"
    echo -e "    ${CYAN}oc get backupstoragelocation -n ${NS}${NC}"
    echo ""
    echo -e "  Check VM status (backup target):"
    echo -e "    ${CYAN}oc get vm -n ${VM_NS}${NC}"
    echo ""
    echo -e "  Check Backup status:"
    echo -e "    ${CYAN}oc get backup poc-oadp-backup -n ${NS}${NC}"
    echo ""
    echo -e "  Run restore (after backup completes):"
    echo -e "    ${CYAN}oc apply -f poc-oadp-restore.yaml${NC}"
    echo ""
    echo -e "  For details: 14-oadp/14-oadp.md"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Delete 14-oadp resources"
    local _oadp_ns="${OADP_NS:-openshift-adp}"
    oc delete project poc-oadp --ignore-not-found 2>/dev/null || true
    oc delete dataprotectionapplication poc-dpa -n "$_oadp_ns" --ignore-not-found 2>/dev/null || true
    oc delete secret cloud-credentials -n "$_oadp_ns" --ignore-not-found 2>/dev/null || true
    oc delete objectbucketclaim obc-backups -n "$_oadp_ns" --ignore-not-found 2>/dev/null || true
    oc delete volumesnapshotclass poc-volumesnapshotclass --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-dataprotectionapplication poc-backup poc-restore --ignore-not-found 2>/dev/null || true
    oc delete project poc-garage --ignore-not-found 2>/dev/null || true
    print_ok "14-oadp resources deleted successfully"
}

main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  OADP lab environment setup${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_obc
    step_credentials
    step_volumesnapshotclass
    step_dpa
    step_verify
    step_vm_namespace
    step_vm
    step_backup
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
