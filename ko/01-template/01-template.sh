#!/bin/bash
# =============================================================================
# 01-template.sh
#
# rhel9-poc-golden.qcow2 → DataVolume → DataSource → Template 등록
# 이 스크립트를 실행하면 openshift namespace에 poc Template이 생성됩니다.
#
# 사용법: ./01-template.sh [qcow2-파일-경로]
#   예시) ./01-template.sh
#   예시) ./01-template.sh /path/to/vm-images/rhel9-poc-golden.qcow2
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# env.conf 자동 로드 (단독 실행 시)
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

source "${SCRIPT_DIR}/../utils/common.sh"

# =============================================================================
# 사전 점검
# =============================================================================
preflight() {
    print_step "사전 점검"

    # OpenShift Virtualization Operator 확인
    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator가 설치되지 않았습니다 → 건너뜀."
        print_warn "  설치 가이드: operators/kubevirt-hyperconverged-operator.md"
        exit 77
    fi

    print_ok "설정 확인됨 (STORAGE_CLASS=${STORAGE_CLASS})"

    # oc 로그인
    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi
    print_ok "클러스터 연결: $(oc whoami) @ $(oc whoami --show-server)"

    # virtctl
    if ! command -v virtctl &>/dev/null; then
        print_error "virtctl을 찾을 수 없습니다."
        echo "  설치: oc get ConsoleCLIDownload virtctl-clidownloads-kubevirt-hyperconverged \\"
        echo "          -o jsonpath='{.spec.links[0].href}'"
        exit 1
    fi
    print_ok "virtctl: $(virtctl version --client 2>/dev/null | sed -n 's/.*GitVersion:"v\([^"]*\)".*/\1/p' | head -1 || echo 'found')"

}

# =============================================================================
# Step 1: DataVolume 생성 (HTTP URL import)
# =============================================================================
step_datavolume() {
    print_step "1/4  DataVolume 생성 (poc-golden, HTTP import)"

    local phase
    phase=$(oc get dv "$DV_NAME" -n "$TARGET_NS" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)

    if [ "$phase" = "Succeeded" ]; then
        print_ok "DataVolume $DV_NAME 이미 존재합니다 (Succeeded) — 건너뜀"
        return
    elif [ -n "$phase" ]; then
        print_warn "DataVolume $DV_NAME 상태: $phase — 재생성합니다"
        oc delete dv "$DV_NAME" -n "$TARGET_NS" --ignore-not-found
        oc delete pvc "$DV_NAME" -n "$TARGET_NS" --ignore-not-found
    fi

    print_info "DataVolume 생성 URL: ${GOLDEN_IMAGE_URL}"

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
    echo "생성된 파일: datavolume-poc-golden.yaml"
    oc apply -f datavolume-poc-golden.yaml
    print_ok "DataVolume $DV_NAME 생성됨 (HTTP import 진행 중)"
}

# =============================================================================
# Step 2: DataSource 등록 및 PVC Bound 대기
# =============================================================================
step_datasource() {
    print_step "2/4  DataSource 등록 및 PVC Bound 대기 (poc-golden)"

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
    echo "생성된 파일: datasource-poc-golden.yaml"
    oc apply -f datasource-poc-golden.yaml
    print_ok "DataSource $DS_NAME 생성됨"

    # DataSource 존재 확인 후 PVC Bound 대기
    print_info "PVC $DV_NAME이 Bound 상태가 되기를 대기 중 (HTTP import 진행 중)..."
    local pvc_phase dv_phase progress
    while true; do
        pvc_phase=$(oc get pvc "$DV_NAME" -n "$TARGET_NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        if [ "$pvc_phase" = "Bound" ]; then
            print_ok "PVC $DV_NAME Bound 확인됨 — Template 생성을 진행합니다."
            break
        fi
        dv_phase=$(oc get dv "$DV_NAME" -n "$TARGET_NS" \
            -o jsonpath='{.status.phase}' 2>/dev/null || true)
        progress=$(oc get dv "$DV_NAME" -n "$TARGET_NS" \
            -o jsonpath='{.status.progress}' 2>/dev/null || true)
        print_info "PVC: ${pvc_phase:-Unknown}, DV: ${dv_phase:-Unknown}${progress:+, 진행률: $progress} — 30초 후 재확인..."
        sleep 30
    done
}

# =============================================================================
# Step 3: Template 등록
# =============================================================================
step_template() {
    print_step "3/4  Template 등록 (poc @ openshift)"

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

    echo "생성된 파일: template-poc.yaml"
    oc apply -f template-poc.yaml

    print_ok "Template $TEMPLATE_NAME 등록됨 (namespace: $TEMPLATE_NS)"
}

# =============================================================================
# Step 4: ConsoleYAMLSample 등록
# =============================================================================
step_consoleyamlsamples() {
    print_step "4/4  ConsoleYAMLSample 등록"

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
    echo "생성된 파일: consoleyamlsample-datasource.yaml"
    oc apply -f consoleyamlsample-datasource.yaml
    print_ok "ConsoleYAMLSample poc-datasource 등록됨"
}

# =============================================================================
# 요약
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  완료! POC VM Template이 등록되었습니다.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  DataVolume : ${CYAN}oc get dv ${DV_NAME} -n ${TARGET_NS}${NC}"
    echo -e "  DataSource : ${CYAN}oc get datasource ${DS_NAME} -n ${TARGET_NS}${NC}"
    echo -e "  Template   : ${CYAN}oc get template ${TEMPLATE_NAME} -n ${TEMPLATE_NS}${NC}"
    echo ""
    echo -e "  VM 생성:"
    echo -e "  ${CYAN}oc process -n openshift poc | oc apply -n <namespace> -f -${NC}"
    echo ""
    echo -e "  또는 Console > Virtualization > Catalog > 'POC VM' 선택"
    echo ""
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "--cleanup: 01-template 리소스 삭제"
    oc delete template poc -n openshift --ignore-not-found 2>/dev/null || true
#    oc delete datasource "${DV_NAME}" -n "${TARGET_NS}" --ignore-not-found 2>/dev/null || true
#    oc delete dv "${DV_NAME}" -n "${TARGET_NS}" --ignore-not-found 2>/dev/null || true
#    oc delete pvc "${DV_NAME}" -n "${TARGET_NS}" --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-datasource --ignore-not-found 2>/dev/null || true
    print_ok "01-template 리소스 삭제됨"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  POC Golden Image → Template 등록${NC}"
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
