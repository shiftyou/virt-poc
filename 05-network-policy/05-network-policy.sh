#!/bin/bash
# =============================================================================
# 05-network-policy.sh
#
# NetworkPolicy (pod network) practice environment setup
#
#   - Namespaces: poc-network-policy-1, poc-network-policy-2
#   - Policy: networking.k8s.io/v1 NetworkPolicy (pod network / eth0)
#     1. deny-all               : Block all Ingress
#     2. allow-same-network     : Allow Ingress between Pods in the same namespace
#     3. allow-access-from-ns1  : Allow Ingress from NS1 namespace Pods in NS2
#
# Usage: ./05-network-policy.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

NS1="poc-network-policy-1"
NS2="poc-network-policy-2"
TOTAL_STEPS=6

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

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator not installed → skipping."
        exit 77
    fi

    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift."
        exit 1
    fi
    print_ok "Cluster connection: $(oc whoami) @ $(oc whoami --show-server)"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_error "poc Template not found. Run 01-template first."
        exit 1
    fi
    print_ok "poc Template confirmed"

    print_info "  NS1 : ${NS1}"
    print_info "  NS2 : ${NS2}"
}

# =============================================================================
# Step 1: Create namespaces
# =============================================================================
step_namespaces() {
    print_step "1/${TOTAL_STEPS}  Create namespaces"

    for NS in "$NS1" "$NS2"; do
        if oc get namespace "$NS" &>/dev/null; then
            print_ok "Namespace $NS already exists — skipping"
        else
            oc new-project "$NS" > /dev/null
            print_ok "Namespace $NS created"
        fi
        # Ensure label used in namespaceSelector matchLabels
        # Auto-assigned in Kubernetes 1.21+, but set explicitly to prevent missing label
        oc label namespace "$NS" kubernetes.io/metadata.name="$NS" --overwrite > /dev/null
        print_ok "Label confirmed: kubernetes.io/metadata.name=${NS}"
    done
}

# =============================================================================
# Step 2: Default Deny All policy
# =============================================================================
step_deny_all() {
    print_step "2/${TOTAL_STEPS}  Apply Default Deny All policy"

    for NS in "$NS1" "$NS2"; do
        cat > "netpol-deny-all-${NS}.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all
  namespace: ${NS}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
EOF
        echo "Generated file: netpol-deny-all-${NS}.yaml"
        oc apply -f "netpol-deny-all-${NS}.yaml"
        print_ok "deny-all applied (namespace: ${NS})"
    done
}

# =============================================================================
# Step 3: Allow Same Network policy
# =============================================================================
step_allow_same_network() {
    print_step "3/${TOTAL_STEPS}  Apply Allow Same Network policy"

    for NS in "$NS1" "$NS2"; do
        cat > "netpol-allow-same-network-${NS}.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-network
  namespace: ${NS}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}
EOF
        echo "Generated file: netpol-allow-same-network-${NS}.yaml"
        oc apply -f "netpol-allow-same-network-${NS}.yaml"
        print_ok "allow-same-network applied (namespace: ${NS})"
    done
}

# =============================================================================
# Step 4: Allow Access From NS1 policy (apply to NS2 only)
# =============================================================================
step_allow_from_ns1() {
    print_step "4/${TOTAL_STEPS}  Apply Allow Access From ${NS1} policy (${NS2})"

    cat > "netpol-allow-from-ns1-${NS2}.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-access-from-project1
  namespace: ${NS2}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ${NS1}
EOF
    echo "Generated file: netpol-allow-from-ns1-${NS2}.yaml"
    oc apply -f "netpol-allow-from-ns1-${NS2}.yaml"
    print_ok "allow-access-from-project1 applied (namespace: ${NS2}, allowed source: ${NS1})"
}

# =============================================================================
# Step 5: Deploy VMs
# =============================================================================
step_vms() {
    print_step "5/${TOTAL_STEPS}  Deploy VMs (poc template)"

    for NS in "$NS1" "$NS2"; do
        local suffix
        suffix=$(echo "$NS" | awk -F'-' '{print $NF}')
        local VM_NAME="poc-vm-${suffix}"

        if oc get vm "$VM_NAME" -n "$NS" &>/dev/null; then
            print_ok "VM $VM_NAME already exists (namespace: $NS) — skipping"
            continue
        fi

        oc process -n openshift poc -p NAME="$VM_NAME" | \
            sed 's/runStrategy: Always/runStrategy: Halted/' | \
            sed 's/  running: false/  runStrategy: Halted/' > "${VM_NAME}-${NS}.yaml"
        echo "Generated file: ${VM_NAME}-${NS}.yaml"
        oc apply -n "$NS" -f "${VM_NAME}-${NS}.yaml"

        virtctl start "$VM_NAME" -n "$NS" 2>/dev/null || true
        print_ok "VM $VM_NAME deployed (namespace: $NS)"
    done
}

# =============================================================================
# Step 6: Register ConsoleYAMLSample
# =============================================================================
step_consoleyamlsamples() {
    print_step "6/${TOTAL_STEPS}  Register ConsoleYAMLSample"

    # Deny All sample
    cat > consoleyamlsample-deny-all.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-netpol-deny-all
spec:
  title: "POC NetworkPolicy — Deny All"
  description: "Blocks all Ingress for the namespace."
  targetResource:
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
  yaml: |
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: deny-all
      namespace: ${NS1}
    spec:
      podSelector: {}
      policyTypes:
        - Ingress
EOF
    echo "Generated file: consoleyamlsample-deny-all.yaml"
    oc apply -f consoleyamlsample-deny-all.yaml
    print_ok "ConsoleYAMLSample poc-netpol-deny-all registered"

    # Allow Same Network sample
    cat > consoleyamlsample-allow-same-network.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-netpol-allow-same-network
spec:
  title: "POC NetworkPolicy — Allow Same Network"
  description: "Allows Ingress communication between Pods in the same namespace."
  targetResource:
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
  yaml: |
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: allow-same-network
      namespace: ${NS1}
    spec:
      podSelector: {}
      policyTypes:
        - Ingress
      ingress:
        - from:
            - podSelector: {}
EOF
    echo "Generated file: consoleyamlsample-allow-same-network.yaml"
    oc apply -f consoleyamlsample-allow-same-network.yaml
    print_ok "ConsoleYAMLSample poc-netpol-allow-same-network registered"

    # Allow Access From Project1 sample
    cat > consoleyamlsample-allow-from-project1.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-netpol-allow-from-project1
spec:
  title: "POC NetworkPolicy — Allow Access From Project1"
  description: "Allows Ingress access from a specific namespace (project1)."
  targetResource:
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
  yaml: |
    apiVersion: networking.k8s.io/v1
    kind: NetworkPolicy
    metadata:
      name: allow-access-from-project1
      namespace: ${NS2}
    spec:
      podSelector: {}
      policyTypes:
        - Ingress
      ingress:
        - from:
            - namespaceSelector:
                matchLabels:
                  kubernetes.io/metadata.name: ${NS1}
EOF
    echo "Generated file: consoleyamlsample-allow-from-project1.yaml"
    oc apply -f consoleyamlsample-allow-from-project1.yaml
    print_ok "ConsoleYAMLSample poc-netpol-allow-from-project1 registered"
}

# =============================================================================
# Completion summary
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Done! NetworkPolicy practice environment is ready.${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Applied NetworkPolicies:"
    echo -e "    - deny-all                  : Block all Ingress (${NS1}, ${NS2})"
    echo -e "    - allow-same-network        : Allow intra-namespace communication (${NS1}, ${NS2})"
    echo -e "    - allow-access-from-project1: Allow ${NS1} → ${NS2} Ingress"
    echo ""
    echo -e "  Check policies:"
    echo -e "    ${CYAN}oc get networkpolicy -n ${NS1}${NC}"
    echo -e "    ${CYAN}oc get networkpolicy -n ${NS2}${NC}"
    echo ""
    echo -e "  Check VM status:"
    echo -e "    ${CYAN}oc get vmi -n ${NS1}${NC}"
    echo -e "    ${CYAN}oc get vmi -n ${NS2}${NC}"
    echo ""
    echo -e "  Next steps: Refer to 05-network-policy.md"
    echo -e "    1. After VM startup, run communication tests from VM console"
    echo -e "    2. ${NS1} VM → ${NS2} VM: allowed (allow-access-from-project1)"
    echo -e "    3. ${NS2} VM → ${NS1} VM: blocked (deny-all)"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: Delete 05-network-policy resources"
    oc delete project poc-network-policy-1 poc-network-policy-2 --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample \
        poc-netpol-deny-all \
        poc-netpol-allow-same-network \
        poc-netpol-allow-from-project1 \
        --ignore-not-found 2>/dev/null || true
    print_ok "05-network-policy resources deleted"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  05-network-policy: NetworkPolicy Practice${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    preflight
    step_namespaces
    step_deny_all
    step_allow_same_network
    step_allow_from_ns1
    step_vms
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
