#!/bin/bash
# =============================================================================
# 05-network-policy.sh
#
# NetworkPolicy / MultiNetworkPolicy practice environment setup
#
#   Method 1 — NetworkPolicy (eth0, pod network)
#     Namespaces: poc-network-policy-1, poc-network-policy-2
#
#   Method 2 — MultiNetworkPolicy (eth1, OVN localnet secondary NIC)
#     Namespaces: poc-multi-network-policy-1, poc-multi-network-policy-2
#     Prerequisite: 02-network OVS Bridge (ovs-bridge) + useMultiNetworkPolicy
#
# Usage: ./05-network-policy.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE="${SCRIPT_DIR}/../env.conf"
if [ -f "$ENV_FILE" ]; then
    set -a; source "$ENV_FILE"; set +a
fi

POLICY_MODE="${POLICY_MODE:-}"
NNCP_IFACE_TYPE="${NNCP_IFACE_TYPE:-linux-bridge}"
NET_TYPE="${NET_TYPE:-1}"
NAD_NAME="${NAD_NAME:-}"
LOCALNET_NAME="${LOCALNET_NAME:-poc-localnet}"
VLAN_ID="${VLAN_ID:-100}"
SECONDARY_IP_PREFIX="${SECONDARY_IP_PREFIX:-192.168.100}"
NS1="poc-network-policy-1"
NS2="poc-network-policy-2"
TOTAL_STEPS=6
POLICY_KIND="networkpolicy"
SECONDARY_IFACE="secondary"

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
# Policy mode selection
# =============================================================================
choose_policy_mode() {
    if [ -n "$POLICY_MODE" ]; then
        configure_from_mode
        return 0
    fi

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  Select policy mode${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${GREEN}1)${NC} NetworkPolicy (eth0, pod network)"
    echo -e "     ${DIM}02-network Linux Bridge / Bond / VLAN${NC}"
    echo ""
    echo -e "  ${GREEN}2)${NC} MultiNetworkPolicy (eth1, OVN localnet secondary NIC)"
    echo -e "     ${DIM}02-network OVS Bridge + useMultiNetworkPolicy${NC}"
    echo ""

    local selection
    read -r -p "  Select [1/2, default: 1]: " selection
    [ -z "$selection" ] && selection="1"
    case "$selection" in
        1) POLICY_MODE="1" ;;
        2) POLICY_MODE="2" ;;
        *)
            print_error "Please enter 1 or 2."
            exit 1
            ;;
    esac
    save_to_env "POLICY_MODE" "$POLICY_MODE"
    configure_from_mode
}

configure_from_mode() {
    case "$POLICY_MODE" in
        2)
            NS1="poc-multi-network-policy-1"
            NS2="poc-multi-network-policy-2"
            TOTAL_STEPS=8
            POLICY_KIND="multinetworkpolicy"
            ;;
        *)
            POLICY_MODE="1"
            NS1="poc-network-policy-1"
            NS2="poc-network-policy-2"
            TOTAL_STEPS=6
            POLICY_KIND="networkpolicy"
            ;;
    esac
}

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

    if [ "${VIRT_INSTALLED:-false}" != "true" ]; then
        print_warn "OpenShift Virtualization Operator is not installed — skipping."
        exit 77
    fi

    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to OpenShift."
        exit 1
    fi
    print_ok "Cluster connected: $(oc whoami) @ $(oc whoami --show-server)"

    if ! oc get template poc -n openshift &>/dev/null; then
        print_error "poc Template not found. Run 01-template first."
        exit 1
    fi
    print_ok "poc Template found"

    if [ "$POLICY_MODE" = "2" ]; then
        if [ -n "${NNCP_NAME:-}" ] && oc get nncp "$NNCP_NAME" &>/dev/null; then
            detect_nncp_type "$NNCP_NAME"
        fi
        resolve_nad_name
        save_network_env
        if [ "$NNCP_IFACE_TYPE" != "ovs-bridge" ]; then
            print_warn "MultiNetworkPolicy requires OVN localnet (02-network OVS Bridge)."
            print_warn "  Current NNCP_IFACE_TYPE=${NNCP_IFACE_TYPE} — continuing anyway."
        fi
        print_info "  NAD_NAME         : ${NAD_NAME}"
        print_info "  LOCALNET_NAME    : ${LOCALNET_NAME}"
    fi

    print_info "  POLICY_MODE      : ${POLICY_MODE} (${POLICY_KIND})"
    print_info "  NS1              : ${NS1}"
    print_info "  NS2              : ${NS2}"
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
        oc label namespace "$NS" kubernetes.io/metadata.name="$NS" --overwrite > /dev/null
        print_ok "Label set: kubernetes.io/metadata.name=${NS}"
    done
}

# =============================================================================
# Step 2 (mode 2): Enable MultiNetworkPolicy
# =============================================================================
step_enable_mnp() {
    [ "$POLICY_MODE" != "2" ] && return 0
    print_step "2/${TOTAL_STEPS}  Enable MultiNetworkPolicy"

    local enabled
    enabled=$(oc get network.operator.openshift.io cluster \
        -o jsonpath='{.spec.useMultiNetworkPolicy}' 2>/dev/null || true)
    if [ "$enabled" = "true" ]; then
        print_ok "useMultiNetworkPolicy already enabled"
        return 0
    fi

    oc patch network.operator.openshift.io cluster --type=merge \
        -p '{"spec":{"useMultiNetworkPolicy":true}}'
    print_ok "useMultiNetworkPolicy enabled"
}

# =============================================================================
# Step 3 (mode 2): Register NAD
# =============================================================================
step_nad() {
    [ "$POLICY_MODE" != "2" ] && return 0
    print_step "3/${TOTAL_STEPS}  Register NAD (${NAD_NAME})"

    for NS in "$NS1" "$NS2"; do
        if oc get network-attachment-definition "$NAD_NAME" -n "$NS" &>/dev/null; then
            print_ok "NAD ${NAD_NAME} already exists (namespace: ${NS}) — skipping"
            continue
        fi

        local nad_file="nad-${NAD_NAME}-${NS}.yaml"
        if [ "$NET_TYPE" = "2" ]; then
            cat > "$nad_file" <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${NS}
spec:
  config: |-
    {
        "cniVersion": "0.3.1",
        "name": "${LOCALNET_NAME}",
        "type": "ovn-k8s-cni-overlay",
        "topology": "localnet",
        "vlanID": ${VLAN_ID},
        "netAttachDefName": "${NS}/${NAD_NAME}"
    }
EOF
        else
            cat > "$nad_file" <<EOF
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: ${NAD_NAME}
  namespace: ${NS}
spec:
  config: |-
    {
        "cniVersion": "0.3.1",
        "name": "${LOCALNET_NAME}",
        "type": "ovn-k8s-cni-overlay",
        "topology": "localnet",
        "netAttachDefName": "${NS}/${NAD_NAME}"
    }
EOF
        fi
        echo "Generated file: ${nad_file}"
        oc apply -f "$nad_file"
        print_ok "NAD ${NAD_NAME} registered (namespace: ${NS})"
    done
}

_policy_step_num() {
    case "$POLICY_MODE" in
        2) echo "$(( $1 + 2 ))" ;;
        *) echo "$1" ;;
    esac
}

# =============================================================================
# Default Deny All policy
# =============================================================================
step_deny_all() {
    local step
    step=$(_policy_step_num 2)
    print_step "${step}/${TOTAL_STEPS}  Apply Default Deny All policy"

    for NS in "$NS1" "$NS2"; do
        if [ "$POLICY_MODE" = "2" ]; then
            cat > "multi-netpol-deny-all-${NS}.yaml" <<EOF
apiVersion: k8s.cni.cncf.io/v1beta1
kind: MultiNetworkPolicy
metadata:
  name: deny-all
  namespace: ${NS}
  annotations:
    k8s.v1.cni.cncf.io/policy-for: ${NS}/${NAD_NAME}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
EOF
            echo "Generated file: multi-netpol-deny-all-${NS}.yaml"
            oc apply -f "multi-netpol-deny-all-${NS}.yaml"
        else
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
        fi
        print_ok "deny-all applied (namespace: ${NS})"
    done
}

# =============================================================================
# Allow Same Network policy
# =============================================================================
step_allow_same_network() {
    local step
    step=$(_policy_step_num 3)
    print_step "${step}/${TOTAL_STEPS}  Apply Allow Same Network policy"

    for NS in "$NS1" "$NS2"; do
        if [ "$POLICY_MODE" = "2" ]; then
            cat > "multi-netpol-allow-same-network-${NS}.yaml" <<EOF
apiVersion: k8s.cni.cncf.io/v1beta1
kind: MultiNetworkPolicy
metadata:
  name: allow-same-network
  namespace: ${NS}
  annotations:
    k8s.v1.cni.cncf.io/policy-for: ${NS}/${NAD_NAME}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}
EOF
            echo "Generated file: multi-netpol-allow-same-network-${NS}.yaml"
            oc apply -f "multi-netpol-allow-same-network-${NS}.yaml"
        else
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
        fi
        print_ok "allow-same-network applied (namespace: ${NS})"
    done
}

# =============================================================================
# Allow Access From NS1 policy (NS2 only)
# =============================================================================
step_allow_from_ns1() {
    local step
    step=$(_policy_step_num 4)
    print_step "${step}/${TOTAL_STEPS}  Apply Allow Access From ${NS1} (${NS2})"

    if [ "$POLICY_MODE" = "2" ]; then
        cat > "multi-netpol-allow-from-ns1-${NS2}.yaml" <<EOF
apiVersion: k8s.cni.cncf.io/v1beta1
kind: MultiNetworkPolicy
metadata:
  name: allow-access-from-project1
  namespace: ${NS2}
  annotations:
    k8s.v1.cni.cncf.io/policy-for: ${NS2}/${NAD_NAME}
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
        echo "Generated file: multi-netpol-allow-from-ns1-${NS2}.yaml"
        oc apply -f "multi-netpol-allow-from-ns1-${NS2}.yaml"
    else
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
    fi
    print_ok "allow-access-from-project1 applied (namespace: ${NS2}, source: ${NS1})"
}

# =============================================================================
# Deploy VMs
# =============================================================================
step_vms() {
    local step
    step=$(_policy_step_num 5)
    print_step "${step}/${TOTAL_STEPS}  Deploy VMs (poc template)"

    local ip_suffixes=(11 12)
    local idx=0

    for NS in "$NS1" "$NS2"; do
        local suffix ip_suffix
        suffix=$(echo "$NS" | awk -F'-' '{print $NF}')
        ip_suffix="${ip_suffixes[$idx]}"
        idx=$((idx + 1))
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
        ensure_runstrategy "$VM_NAME" "$NS"

        if [ "$POLICY_MODE" = "2" ]; then
            oc patch vm "$VM_NAME" -n "$NS" --type=json -p="[
              {
                \"op\": \"add\",
                \"path\": \"/spec/template/spec/domain/devices/interfaces/-\",
                \"value\": {\"name\": \"${SECONDARY_IFACE}\", \"bridge\": {}, \"model\": \"virtio\"}
              },
              {
                \"op\": \"add\",
                \"path\": \"/spec/template/spec/networks/-\",
                \"value\": {\"name\": \"${SECONDARY_IFACE}\", \"multus\": {\"networkName\": \"${NAD_NAME}\"}}
              }
            ]"

            local ci_idx
            ci_idx=$(oc get vm "$VM_NAME" -n "$NS" \
                -o jsonpath='{range .spec.template.spec.volumes[*]}{.name}{"\n"}{end}' 2>/dev/null | \
                grep -n "cloudinitdisk" | cut -d: -f1 | head -1)
            [ -n "$ci_idx" ] && ci_idx=$(( ci_idx - 1 ))

            if [ -n "$ci_idx" ]; then
                oc patch vm "$VM_NAME" -n "$NS" --type=json -p="[
                  {\"op\": \"add\",
                   \"path\": \"/spec/template/spec/volumes/${ci_idx}/cloudInitNoCloud/networkData\",
                   \"value\": \"version: 2\\nethernets:\\n  eth1:\\n    dhcp4: false\\n    addresses:\\n      - ${SECONDARY_IP_PREFIX}.${ip_suffix}/24\\n    gateway4: ${SECONDARY_IP_PREFIX}.1\\n    nameservers:\\n      addresses:\\n        - 8.8.8.8\\n\"}
                ]"
                print_ok "networkData added (eth1: ${SECONDARY_IP_PREFIX}.${ip_suffix}/24)"
            else
                print_warn "cloudinitdisk volume not found. networkData was not set."
            fi
            virtctl start "$VM_NAME" -n "$NS" 2>/dev/null || true
            print_ok "VM $VM_NAME deployed (eth0: masquerade, eth1: ${NAD_NAME}, IP: ${SECONDARY_IP_PREFIX}.${ip_suffix}/24)"
        else
            virtctl start "$VM_NAME" -n "$NS" 2>/dev/null || true
            print_ok "VM $VM_NAME deployed (namespace: $NS, eth0 pod network)"
        fi
    done
}

# =============================================================================
# Register ConsoleYAMLSample
# =============================================================================
step_consoleyamlsamples() {
    local step
    step=$(_policy_step_num 6)
    print_step "${step}/${TOTAL_STEPS}  Register ConsoleYAMLSample"

    if [ "$POLICY_MODE" = "2" ]; then
        cat > consoleyamlsample-multi-deny-all.yaml <<EOF
apiVersion: console.openshift.io/v1
kind: ConsoleYAMLSample
metadata:
  name: poc-multi-netpol-deny-all
spec:
  title: "POC MultiNetworkPolicy — Deny All"
  description: "Blocks all Ingress on the secondary NIC (OVN localnet)."
  targetResource:
    apiVersion: k8s.cni.cncf.io/v1beta1
    kind: MultiNetworkPolicy
  yaml: |
    apiVersion: k8s.cni.cncf.io/v1beta1
    kind: MultiNetworkPolicy
    metadata:
      name: deny-all
      namespace: ${NS1}
      annotations:
        k8s.v1.cni.cncf.io/policy-for: ${NS1}/${NAD_NAME}
    spec:
      podSelector: {}
      policyTypes:
        - Ingress
EOF
        echo "Generated file: consoleyamlsample-multi-deny-all.yaml"
        oc apply -f consoleyamlsample-multi-deny-all.yaml
        print_ok "ConsoleYAMLSample poc-multi-netpol-deny-all registered"
        return 0
    fi

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
# Summary
# =============================================================================
print_summary() {
    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [ "$POLICY_MODE" = "2" ]; then
        echo -e "${GREEN}  Done! MultiNetworkPolicy practice environment is ready.${NC}"
    else
        echo -e "${GREEN}  Done! NetworkPolicy practice environment is ready.${NC}"
    fi
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    if [ "$POLICY_MODE" = "2" ]; then
        echo -e "  Applied MultiNetworkPolicy (NAD: ${NAD_NAME}):"
        echo -e "    ${CYAN}oc get multinetworkpolicy -n ${NS1}${NC}"
        echo -e "    ${CYAN}oc get multinetworkpolicy -n ${NS2}${NC}"
        echo ""
        echo -e "  Check VM secondary NIC IP:"
        echo -e "    ${CYAN}oc get vmi -n ${NS1} -o jsonpath='{.items[0].status.interfaces[?(@.name==\"${SECONDARY_IFACE}\")].ipAddress}'${NC}"
    else
        echo -e "  Applied NetworkPolicy:"
        echo -e "    ${CYAN}oc get networkpolicy -n ${NS1}${NC}"
        echo -e "    ${CYAN}oc get networkpolicy -n ${NS2}${NC}"
    fi
    echo ""
    echo -e "  Check VM status:"
    echo -e "    ${CYAN}oc get vmi -n ${NS1}${NC}"
    echo -e "    ${CYAN}oc get vmi -n ${NS2}${NC}"
    echo ""
    echo -e "  Next: see 05-network-policy.md"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "--cleanup: delete 05-network-policy resources"
    oc delete project poc-network-policy-1 poc-network-policy-2 \
        poc-multi-network-policy-1 poc-multi-network-policy-2 \
        --ignore-not-found 2>/dev/null || true
    oc delete consoleyamlsample \
        poc-netpol-deny-all \
        poc-netpol-allow-same-network \
        poc-netpol-allow-from-project1 \
        poc-multi-netpol-deny-all \
        --ignore-not-found 2>/dev/null || true
    print_ok "05-network-policy resources deleted"
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  05-network-policy: NetworkPolicy / MultiNetworkPolicy practice${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    choose_policy_mode
    preflight
    step_namespaces
    step_enable_mnp
    step_nad
    step_deny_all
    step_allow_same_network
    step_allow_from_ns1
    step_vms
    step_consoleyamlsamples
    print_summary
}

[ "${1:-}" = "--cleanup" ] && { cleanup; exit 0; }
main
