#!/bin/bash
# =============================================================================
# 01-template.sh
#
# rhel9-poc-golden.qcow2 → DataVolume → DataSource → Template registration
# Running this creates a poc Template in the openshift namespace.
#
# Usage: ./01-template.sh [qcow2-file-path]
#   e.g.) ./01-template.sh
#   e.g.) ./01-template.sh /path/to/vm-images/rhel9-poc-golden.qcow2
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-load env.conf (when running standalone)
ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

TARGET_NS="openshift-virtualization-os-images"
DV_NAME="poc-golden"
DS_NAME="poc-golden"
TEMPLATE_NAME="poc"
TEMPLATE_NS="openshift"
DISK_SIZE="30Gi"
STORAGE_CLASS="${STORAGE_CLASS}"
GOLDEN_IMAGE_URL="${GOLDEN_IMAGE_URL:-http://krssa.ddns.net/vm-images/rhel9-poc-golden.qcow2}"
GOLDEN_IMAGE_LOCAL="${GOLDEN_IMAGE_LOCAL:-}"

if [ -f "${SCRIPT_DIR}/../utils/common.sh" ]; then
    source "${SCRIPT_DIR}/../utils/common.sh"
else
    # ── standalone mode: inline common helpers ──
    RED='\033[0;31m'; GREEN='\033[0;32m'; DIM='\033[2m'
    YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'
    print_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
    print_ok()    { echo -e "${GREEN}[ OK ]${NC} $1"; }
    print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
    print_error() { echo -e "${RED}[ERR ]${NC} $1"; }
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
            echo -n -e "${YELLOW}  $prompt${NC} [default: ****]: "; read -s input_val; echo
        else
            echo -n -e "${YELLOW}  $prompt${NC} [default: ${default}]: "; read input_val
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
            print_info "YAML to apply:"; cat "$file"
            read -r -p "Apply this YAML to the cluster? [y/N]: " confirm
            [[ "$confirm" != "y" && "$confirm" != "Y" ]] && { print_warn "Cancelled."; return 1; }
        fi
        oc apply -f "$file"
    }
    detect_worker_nodes() {
        WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
        TEST_NODE=$(echo "$WORKER_NODES" | awk '{print $1}')
        [ -z "$WORKER_NODES" ] && { print_error "No worker nodes found."; exit 1; }
        print_info "Worker nodes: ${WORKER_NODES}"
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
        else print_warn "Garage Service (app=garage) not detected — skipping Garage config."; fi
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
            print_info "ODF MCG credentials : from noobaa-admin secret"
        else print_warn "ODF MCG credentials not detected (no noobaa-admin secret)"; fi
    }
fi

# =============================================================================
# Pre-flight checks
# =============================================================================
preflight() {
    print_step "Pre-flight checks"

    # Check OpenShift Virtualization Operator
    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator not installed → skipping."
        print_warn "  Installation guide: operators/kubevirt-hyperconverged-operator.md"
        exit 77
    fi

    print_ok "Configuration confirmed (STORAGE_CLASS=${STORAGE_CLASS})"

    # oc login
    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift."
        exit 1
    fi
    print_ok "Cluster connection: $(oc whoami) @ $(oc whoami --show-server)"

    # virtctl
    if ! command -v virtctl &>/dev/null; then
        print_error "virtctl not found."
        echo "  Install: oc get ConsoleCLIDownload virtctl-clidownloads-kubevirt-hyperconverged \\"
        echo "          -o jsonpath='{.spec.links[0].href}'"
        exit 1
    fi
    print_ok "virtctl: $(virtctl version --client 2>/dev/null | sed -n 's/.*GitVersion:"v\([^"]*\)".*/\1/p' | head -1 || echo 'found')"

}

# =============================================================================
# Step 1: Create DataVolume (local upload or HTTP URL import)
# =============================================================================
step_datavolume() {
    print_step "1/4  Create DataVolume (poc-golden)"

    local phase
    phase=$(oc get dv "$DV_NAME" -n "$TARGET_NS" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)

    if [ "$phase" = "Succeeded" ]; then
        print_ok "DataVolume $DV_NAME already exists (Succeeded) — skipping"
        return
    elif [ -n "$phase" ]; then
        print_warn "DataVolume $DV_NAME status: $phase — recreating"
        oc delete dv "$DV_NAME" -n "$TARGET_NS" --ignore-not-found
        oc delete pvc "$DV_NAME" -n "$TARGET_NS" --ignore-not-found
    fi

    local local_qcow2=""
    local url_filename
    url_filename=$(basename "$GOLDEN_IMAGE_URL")

    local base_dir repo_root
    base_dir="$(cd "${SCRIPT_DIR}/.." && pwd)"
    repo_root="$(cd "${SCRIPT_DIR}/../.." && pwd)"

    if [ -n "$GOLDEN_IMAGE_LOCAL" ] && [ -f "$GOLDEN_IMAGE_LOCAL" ]; then
        local_qcow2="$(cd "$(dirname "$GOLDEN_IMAGE_LOCAL")" && pwd)/$(basename "$GOLDEN_IMAGE_LOCAL")"
    elif [ -f "${base_dir}/${url_filename}" ]; then
        local_qcow2="${base_dir}/${url_filename}"
    elif [ -f "${repo_root}/downloads/images/${url_filename}" ]; then
        local_qcow2="${repo_root}/downloads/images/${url_filename}"
    elif [ -f "$(pwd)/${url_filename}" ]; then
        local_qcow2="$(pwd)/${url_filename}"
    fi

    if [ -n "$local_qcow2" ]; then
        print_info "Local file found: ${local_qcow2} — using virtctl upload"

        cat > datavolume-poc-golden.yaml <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  annotations:
    cdi.kubevirt.io/storage.bind.immediate.requested: 'true'
    cdi.kubevirt.io/storage.usePopulator: 'true'
  name: ${DV_NAME}
  namespace: ${TARGET_NS}
  labels:
    instancetype.kubevirt.io/default-preference: rhel.9
    instancetype.kubevirt.io/default-preference-kind: VirtualMachineClusterPreference
spec:
  source:
    upload: {}
  storage:
    accessModes:
      - ReadWriteMany
    resources:
      requests:
        storage: ${DISK_SIZE}
    storageClassName: ${STORAGE_CLASS}
    volumeMode: Block
EOF
        echo "Generated file: datavolume-poc-golden.yaml"
        oc apply -f datavolume-poc-golden.yaml

        print_info "Uploading ${local_qcow2} via virtctl image-upload..."
        virtctl image-upload dv "$DV_NAME" \
            --image-path="$local_qcow2" \
            --namespace="$TARGET_NS" \
            --no-create \
            --insecure
        print_ok "DataVolume $DV_NAME created (local upload complete)"
    else
        print_info "Local file not found (${url_filename}) — using HTTP import"
        print_info "DataVolume creation URL: ${GOLDEN_IMAGE_URL}"

        cat > datavolume-poc-golden.yaml <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  annotations:
    cdi.kubevirt.io/storage.bind.immediate.requested: 'true'
    cdi.kubevirt.io/storage.usePopulator: 'true'
  name: ${DV_NAME}
  namespace: ${TARGET_NS}
  labels:
    instancetype.kubevirt.io/default-preference: rhel.9
    instancetype.kubevirt.io/default-preference-kind: VirtualMachineClusterPreference
spec:
  source:
    http:
      url: '${GOLDEN_IMAGE_URL}'
  storage:
    accessModes:
      - ReadWriteMany
    resources:
      requests:
        storage: ${DISK_SIZE}
    storageClassName: ${STORAGE_CLASS}
    volumeMode: Block
EOF
        echo "Generated file: datavolume-poc-golden.yaml"
        oc apply -f datavolume-poc-golden.yaml
        print_ok "DataVolume $DV_NAME created (HTTP import in progress)"
    fi
}

# =============================================================================
# Step 2: Register DataSource and wait for PVC Bound
# =============================================================================
step_datasource() {
    print_step "2/4  Register DataSource and wait for PVC Bound (poc-golden)"

    cat > datasource-poc-golden.yaml <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  labels:
    instancetype.kubevirt.io/default-preference: rhel.9
    instancetype.kubevirt.io/default-preference-kind: VirtualMachineClusterPreference
  name: ${DS_NAME}
  namespace: ${TARGET_NS}
spec:
  source:
    pvc:
      name: ${DV_NAME}
      namespace: ${TARGET_NS}
EOF
    echo "Generated file: datasource-poc-golden.yaml"
    oc apply -f datasource-poc-golden.yaml
    print_ok "DataSource $DS_NAME created"

    # Wait for PVC Bound after confirming DataSource exists
    print_info "Waiting for PVC $DV_NAME to become Bound..."
    local pvc_phase dv_phase progress
    while true; do
        pvc_phase=$(oc get pvc "$DV_NAME" -n "$TARGET_NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [ "$pvc_phase" = "Bound" ]; then
            print_ok "PVC $DV_NAME Bound confirmed — proceeding with Template creation."
            break
        fi
        dv_phase=$(oc get dv "$DV_NAME" -n "$TARGET_NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        progress=$(oc get dv "$DV_NAME" -n "$TARGET_NS" \
            -o jsonpath='{.status.progress}' 2>/dev/null || true)
        print_info "PVC: ${pvc_phase:-Unknown}, DV: ${dv_phase:-Unknown}${progress:+, Progress: $progress} — rechecking in 30 seconds..."
        sleep 30
    done
}

# =============================================================================
# Step 3: Register Template
# =============================================================================
step_template() {
    print_step "3/4  Register Template (poc @ openshift)"

    cat > template-poc.yaml <<EOF
kind: Template
apiVersion: template.openshift.io/v1
metadata:
  name: poc
  namespace: openshift
  labels:
    template.kubevirt.io/architecture: amd64
    flavor.template.kubevirt.io/small: 'true'
    template.kubevirt.io/type: vm
    vm.kubevirt.io/template: poc
    app.kubernetes.io/component: templating
    app.kubernetes.io/name: custom-templates
    vm.kubevirt.io/template.namespace: openshift
    workload.template.kubevirt.io/server: 'true'
  annotations:
    template.kubevirt.io/provider: ''
    template.kubevirt.io/provider-url: 'https://www.redhat.com'
    openshift.io/display-name: 'POC VM'
    defaults.template.kubevirt.io/disk: rootdisk
    template.kubevirt.io/editable: |
      /objects[0].spec.template.spec.domain.cpu.sockets
      /objects[0].spec.template.spec.domain.cpu.cores
      /objects[0].spec.template.spec.domain.cpu.threads
      /objects[0].spec.template.spec.domain.memory.guest
      /objects[0].spec.template.spec.domain.devices.disks
      /objects[0].spec.template.spec.volumes
      /objects[0].spec.template.spec.networks
    template.openshift.io/bindable: 'false'
    openshift.kubevirt.io/pronounceable-suffix-for-name-expression: 'true'
    tags: 'hidden,kubevirt,virtualmachine,linux,rhel'
    template.kubevirt.io/provider-support-level: Full
    description: Template for POC
    iconClass: icon-rhel
    openshift.io/provider-display-name: ''
objects:
  - apiVersion: kubevirt.io/v1
    kind: VirtualMachine
    metadata:
      labels:
        app: '\${NAME}'
        vm.kubevirt.io/template: poc
        vm.kubevirt.io/template.namespace: openshift
      name: '\${NAME}'
    spec:
      dataVolumeTemplates:
        - apiVersion: cdi.kubevirt.io/v1beta1
          kind: DataVolume
          metadata:
            name: '\${NAME}'
          spec:
            sourceRef:
              kind: DataSource
              name: '\${DATA_SOURCE_NAME}'
              namespace: '\${DATA_SOURCE_NAMESPACE}'
            storage:
              resources:
                requests:
                  storage: 30Gi
      runStrategy: Halted
      template:
        metadata:
          annotations:
            vm.kubevirt.io/flavor: small
            vm.kubevirt.io/os: rhel9
            vm.kubevirt.io/workload: server
            descheduler.alpha.kubernetes.io/evict: "true"
          labels:
            kubevirt.io/domain: '\${NAME}'
            kubevirt.io/size: small
        spec:
          domain:
            cpu:
              cores: 1
              sockets: 1
              threads: 1
            devices:
              disks:
                - disk:
                    bus: virtio
                  name: rootdisk
                - disk:
                    bus: virtio
                  name: cloudinitdisk
              interfaces:
                - masquerade: {}
                  model: virtio
                  name: default
              rng: {}
            memory:
              guest: 2Gi
          networks:
            - name: default
              pod: {}
          terminationGracePeriodSeconds: 180
          volumes:
            - dataVolume:
                name: '\${NAME}'
              name: rootdisk
            - cloudInitNoCloud:
                userData: |-
                  #cloud-config
                  user: cloud-user
                  password: \${CLOUD_USER_PASSWORD}
                  chpasswd: { expire: False }
              name: cloudinitdisk
parameters:
  - name: NAME
    description: VM name
    generate: expression
    from: 'poc-[a-z0-9]{16}'
  - name: DATA_SOURCE_NAME
    description: Name of the DataSource to clone
    value: poc-golden
  - name: DATA_SOURCE_NAMESPACE
    description: Namespace of the DataSource
    value: openshift-virtualization-os-images
  - name: CLOUD_USER_PASSWORD
    description: Randomized password for the cloud-init user cloud-user
    value: redhat
EOF

#    generate: expression
#    from: '[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}'

    echo "Generated file: template-poc.yaml"
    oc apply -f template-poc.yaml

    print_ok "Template $TEMPLATE_NAME registered (namespace: $TEMPLATE_NS)"
}

# =============================================================================
# Step 4: Register ConsoleYAMLSample
# =============================================================================
step_consoleyamlsamples() {
    print_step "4/4  Register ConsoleYAMLSample"

    cat > consoleyamlsample-datasource.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-datasource
spec:
  title: "POC DataSource Registration"
  description: "Register a DataSource that references a Golden Image PVC. Apply after uploading the PVC with virtctl image-upload."
  targetResource:
    apiVersion: cdi.kubevirt.io/v1beta1
    kind: DataSource
  yaml: |
    apiVersion: cdi.kubevirt.io/v1beta1
    kind: DataSource
    metadata:
      name: poc
      namespace: openshift-virtualization-os-images
    spec:
      source:
        pvc:
          name: poc-golden
          namespace: openshift-virtualization-os-images
EOF
    echo "Generated file: consoleyamlsample-datasource.yaml"
    oc apply -f consoleyamlsample-datasource.yaml
    print_ok "ConsoleYAMLSample poc-datasource registered"
}

# =============================================================================
# Summary
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! POC VM Template has been registered.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  DataVolume : ${CYAN}oc get dv ${DV_NAME} -n ${TARGET_NS}${NC}"
    echo -e "  DataSource : ${CYAN}oc get datasource ${DS_NAME} -n ${TARGET_NS}${NC}"
    echo -e "  Template   : ${CYAN}oc get template ${TEMPLATE_NAME} -n ${TEMPLATE_NS}${NC}"
    echo ""
    echo -e "  Create VM:"
    echo -e "  ${CYAN}oc process -n openshift poc | oc apply -n <namespace> -f -${NC}"
    echo ""
    echo -e "  Or Console > Virtualization > Catalog > Select 'POC VM'"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Delete 01-template resources"
    oc delete template poc -n openshift --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-datasource --ignore-not-found 2>/dev/null || true

    echo ""
    echo -n -e "${YELLOW}  Delete golden image (DataSource/DataVolume/PVC)? Other labs depend on this. (y/N): ${NC}"
    read -r confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        oc delete datasource "${DS_NAME}" -n "${TARGET_NS}" --ignore-not-found 2>/dev/null || true
        oc delete dv "${DV_NAME}" -n "${TARGET_NS}" --ignore-not-found 2>/dev/null || true
        oc delete pvc "${DV_NAME}" -n "${TARGET_NS}" --ignore-not-found 2>/dev/null || true
        print_ok "Golden image deleted"
    else
        print_info "Golden image kept"
    fi

    print_ok "01-template cleanup done"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  POC Golden Image → Template Registration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    if [ -n "${1:-}" ] && [ -f "${1:-}" ]; then
        GOLDEN_IMAGE_LOCAL="$1"
    fi

    preflight

    step_datavolume
    step_datasource
    step_template
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main "${1:-}"
