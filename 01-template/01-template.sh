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
# Step 1: Create DataVolume (HTTP URL import)
# =============================================================================
step_datavolume() {
    print_step "1/4  Create DataVolume (poc-golden, HTTP import)"

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
    print_info "Waiting for PVC $DV_NAME to become Bound (HTTP import in progress)..."
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
#    oc delete datasource "${DV_NAME}" -n "${TARGET_NS}" --ignore-not-found 2>/dev/null || true
#    oc delete dv "${DV_NAME}" -n "${TARGET_NS}" --ignore-not-found 2>/dev/null || true
#    oc delete pvc "${DV_NAME}" -n "${TARGET_NS}" --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-datasource --ignore-not-found 2>/dev/null || true
    print_ok "01-template resources deleted"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  POC Golden Image → Template Registration${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight "${1:-}"

    step_datavolume
    step_datasource
    step_template
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main "${1:-}"
