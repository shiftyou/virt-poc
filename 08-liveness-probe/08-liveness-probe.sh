#!/bin/bash
# =============================================================================
# 07-liveness-probe.sh
#
# VM Liveness Probe practice environment setup
#   1. Create poc-liveness-probe namespace
#   2. Create VM using poc template
#   3. Configure HTTP Liveness Probe (port 80) on VM
#
# Usage: ./07-liveness-probe.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS="poc-liveness-probe"
VM_NAME="poc-liveness-vm"

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

# Migrate spec.running (deprecated) -> spec.runStrategy
# Call before oc patch vm to remove admission webhook warnings
ensure_runstrategy() {
    local vm="$1" ns="$2"
    local running
    running=$(oc get vm "$vm" -n "$ns" \
        -o jsonpath='{.spec.running}' 2>/dev/null || true)
    [ -z "$running" ] && return 0
    local rs="Halted"
    [ "$running" = "true" ] && rs="Always"
    oc patch vm "$vm" -n "$ns" --type=json -p "[
      {\"op\":\"remove\",\"path\":\"/spec/running\"},
      {\"op\":\"add\",\"path\":\"/spec/runStrategy\",\"value\":\"${rs}\"}
    ]" &>/dev/null || true
}

# =============================================================================
# Pre-flight checks
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

    if ! oc get template poc -n openshift &>/dev/null; then
        print_error "poc Template not found. Run 01-template first."
        exit 1
    fi
    print_ok "poc Template confirmed"
}

# =============================================================================
# Step 1: Create namespace
# =============================================================================
step_namespace() {
    print_step "1/3  Create namespace (${NS})"

    if oc get namespace "$NS" &>/dev/null; then
        print_ok "Namespace $NS already exists — skipping"
    else
        oc new-project "$NS" > /dev/null
        print_ok "Namespace $NS created"
    fi
}

# =============================================================================
# Step 2: Create VM (poc template + Liveness Probe)
# =============================================================================
step_vm() {
    print_step "2/3  Create VM (poc template + HTTP Liveness Probe port 80)"

    if oc get vm "$VM_NAME" -n "$NS" &>/dev/null; then
        print_ok "VM $VM_NAME already exists — skipping"
        return
    fi

    # Create VM from poc template
    oc process -n openshift poc -p NAME="$VM_NAME" | \
        sed 's/runStrategy: Always/runStrategy: Halted/' | sed 's/  running: false/  runStrategy: Halted/' > "${VM_NAME}.yaml"
    echo "Generated file: ${VM_NAME}.yaml"
    oc apply -n "$NS" -f "${VM_NAME}.yaml"
    print_ok "VM $VM_NAME created"

    # HTTP Liveness Probe (port 80) patch
    # spec.template.spec.readinessProbe / livenessProbe → supported at KubeVirt VMI level
    ensure_runstrategy "$VM_NAME" "$NS"
    oc patch vm "$VM_NAME" -n "$NS" --type=merge -p '{
      "spec": {
        "template": {
          "spec": {
            "readinessProbe": {
              "httpGet": {
                "port": 80
              },
              "initialDelaySeconds": 120,
              "periodSeconds": 20,
              "timeoutSeconds": 10,
              "failureThreshold": 3,
              "successThreshold": 3
            },
            "livenessProbe": {
              "httpGet": {
                "port": 80
              },
              "initialDelaySeconds": 120,
              "periodSeconds": 20,
              "timeoutSeconds": 10,
              "failureThreshold": 3
            }
          }
        }
      }
    }'
    print_ok "Liveness/Readiness Probe configured (port 80)"
    print_info "  initialDelaySeconds: 120  (allow time for VM boot)"
    print_info "  periodSeconds      : 20"
    print_info "  failureThreshold   : 3    (VM restart after 3 failures)"

    virtctl start "$VM_NAME" -n "$NS" 2>/dev/null || true
    print_ok "VM $VM_NAME started"
}

# =============================================================================
# Step 3: Service guidance for Probe verification
# =============================================================================
step_consoleyamlsamples() {
    print_step "4/4  Register ConsoleYAMLSample"

    cat > consoleyamlsample-liveness-vm.yaml <<'EOF'
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-liveness-vm
spec:
  title: "POC VM Liveness/Readiness Probe"
  description: "A VirtualMachine example with HTTP Liveness/Readiness Probe configured. Performs periodic health checks on port 80, and restarts the VM after 3 consecutive failures."
  targetResource:
    apiVersion: kubevirt.io/v1
    kind: VirtualMachine
  yaml: |
    apiVersion: kubevirt.io/v1
    kind: VirtualMachine
    metadata:
      name: poc-liveness-vm
      namespace: poc-liveness-probe
    spec:
      runStrategy: Always
      template:
        spec:
          readinessProbe:
            httpGet:
              port: 80
            initialDelaySeconds: 120
            periodSeconds: 20
            timeoutSeconds: 10
            failureThreshold: 3
            successThreshold: 3
          livenessProbe:
            httpGet:
              port: 80
            initialDelaySeconds: 120
            periodSeconds: 20
            timeoutSeconds: 10
            failureThreshold: 3
          domain:
            cpu:
              cores: 1
            memory:
              guest: 2Gi
            devices:
              disks:
                - name: rootdisk
                  disk:
                    bus: virtio
          volumes:
            - name: rootdisk
              dataVolume:
                name: poc-liveness-vm
      dataVolumeTemplates:
        - metadata:
            name: poc-liveness-vm
          spec:
            pvc:
              accessModes:
                - ReadWriteMany
              resources:
                requests:
                  storage: 30Gi
            sourceRef:
              kind: DataSource
              name: poc
              namespace: openshift-virtualization-os-images
EOF
    oc apply -f consoleyamlsample-liveness-vm.yaml
    print_ok "ConsoleYAMLSample poc-liveness-vm registered"
}

step_service() {
    print_step "3/4  VM internal httpd port guidance"

    print_info "KubeVirt Probe uses virt-probe to connect directly to VMI internal IP."
    print_info "httpGet.port specifies the port inside the VM (no Service required)."
    echo ""
    print_info "A port 80 HTTP server must be running inside the VM for the Probe to succeed."
    print_info "If httpd is installed in the poc golden image, it will pass automatically."
    echo ""
    print_info "If httpd is not installed, run a simple server after accessing the VM:"
    echo -e "    ${CYAN}virtctl console $VM_NAME -n $NS${NC}"
    echo -e "    ${CYAN}# Inside VM:${NC}"
    echo -e "    ${CYAN}nohup python3 -m http.server 80 &>/dev/null &${NC}"
    echo -e "    ${CYAN}# If python3 is not installed: nohup nc -lk -p 80 -e /bin/echo &>/dev/null &${NC}"
}

# =============================================================================
# Completion summary
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! Liveness Probe practice environment is ready.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Check VM status:"
    echo -e "    ${CYAN}oc get vm,vmi -n ${NS}${NC}"
    echo ""
    echo -e "  Check Probe status:"
    echo -e "    ${CYAN}oc get vmi $VM_NAME -n $NS -o jsonpath='{range .status.conditions[*]}{.type}: {.status}  {.message}{\"\\n\"}{end}'${NC}"
    echo ""
    echo -e "  VM console access:"
    echo -e "    ${CYAN}virtctl console $VM_NAME -n $NS${NC}"
    echo ""
    echo -e "  For details: refer to ${CYAN}10-liveness-probe.md${NC}"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Delete 08-liveness-probe resources"
    oc delete project poc-liveness-probe --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample poc-liveness-vm --ignore-not-found 2>/dev/null || true
    print_ok "08-liveness-probe resources deleted"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  VM Liveness Probe Practice Environment Setup${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespace
    step_vm
    step_service
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
