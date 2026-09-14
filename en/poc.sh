#!/bin/bash
# =============================================================================
# poc.sh
#
# Runs the .sh files in numbered directories (01-, 02-, ...) in order.
# Run setup.sh first to generate env.conf.
#   e.g.) 01-template/01-template.sh
#         02-network/02-network.sh
#         03-vm-workload/03-vm-workload.sh
#
# Usage:
#   ./poc.sh            Print usage
#   ./poc.sh start      Run all steps
#   ./poc.sh 7          Run only step 07
#   ./poc.sh from 7     Run from step 07 to the end
#   ./poc.sh reset      Delete all poc- namespaces
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/env.conf"

source "$(dirname "${BASH_SOURCE[0]}")/utils/common.sh"

print_info()  { echo -e "${CYAN}[make]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[make]${NC} $1"; }
print_error() { echo -e "${RED}[make]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[make]${NC} $1"; }

# Parse arguments
ARG1="${1:-}"
ARG2="${2:-}"

# =============================================================================
# No arguments → print usage
# =============================================================================
if [ -z "$ARG1" ]; then
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  virt-poc poc.sh${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  Usage:"
    echo -e "    ${CYAN}./poc.sh start${NC}        Run all steps"
    echo -e "    ${CYAN}./poc.sh 7${NC}            Run only step 07"
    echo -e "    ${CYAN}./poc.sh from 7${NC}       Run from step 07 to the end"
    echo -e "    ${CYAN}./poc.sh status${NC}       Show lab completion status"
    echo -e "    ${CYAN}./poc.sh reset${NC}        Delete poc- namespaces + generated files"
    echo -e "    ${CYAN}./poc.sh cleanup${NC}      Run --cleanup for each step in reverse order"
    echo -e "    ${CYAN}./poc.sh cleanup 7${NC}    Run --cleanup for step 07 only"
    echo ""
    exit 0
fi

# =============================================================================
# reset subcommand
# =============================================================================
if [ "$ARG1" = "reset" ]; then
    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift."
        exit 1
    fi

    NAMESPACES=$(oc get namespace --no-headers \
        -o custom-columns=NAME:.metadata.name 2>/dev/null | grep '^poc-' || true)

    if [ -z "$NAMESPACES" ]; then
        print_info "No poc- namespaces to delete."
        exit 0
    fi

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  poc.sh reset — Deleting the following namespaces${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "$NAMESPACES" | while read -r ns; do
        echo -e "    ${YELLOW}●${NC} ${ns}"
    done
    echo ""
    echo -n -e "${YELLOW}  Are you sure you want to delete? (y/N): ${NC}"
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Cancelled."
        exit 0
    fi

    echo ""
    echo "$NAMESPACES" | while read -r ns; do
        print_info "Deleting: ${ns}"
        oc delete namespace "$ns" --wait=false 2>/dev/null && \
            print_ok "${ns} deletion requested" || \
            print_warn "${ns} deletion failed (already gone or insufficient permissions)"
    done

    echo ""
    print_info "Waiting for namespace deletion to complete..."
    echo ""
    while true; do
        REMAINING=$(oc get namespace --no-headers \
            -o custom-columns=NAME:.metadata.name 2>/dev/null | grep '^poc-' || true)
        if [ -z "$REMAINING" ]; then
            break
        fi
        echo -e "  ${YELLOW}Remaining namespaces:${NC}"
        echo "$REMAINING" | while read -r ns; do
            echo -e "    ${YELLOW}●${NC} ${ns}"
        done
        sleep 5
        echo ""
    done
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  All poc- namespaces deleted!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # Clean up generated files
    print_info "Cleaning up generated files..."
    echo ""

    # Find and remove generated YAML files (exclude git-tracked source files)
    YAML_FILES=$(find . -maxdepth 2 -path './[0-9][0-9]-*' -type f \( \
        -name "*.yaml" -o \
        -name "*.yml" \
        \) 2>/dev/null | while read -r f; do
        git ls-files --error-unmatch "$f" &>/dev/null || echo "$f"
    done)

    if [ -n "$YAML_FILES" ]; then
        echo -e "${YELLOW}  Generated YAML files:${NC}"
        echo "$YAML_FILES" | while read -r file; do
            [ -n "$file" ] && echo -e "    ${DIM}✗${NC} ${file}" && rm -f "$file"
        done
    fi

    # Clean up temporary files
    find . -type f \( \
        -name "*.tmp" -o \
        -name "*.log" -o \
        -name ".DS_Store" -o \
        -name "*.swp" -o \
        -name "*~" \
        \) -delete 2>/dev/null || true

    # Clean up downloaded files (optional - ask user)
    if [ -d "../downloads" ]; then
        echo ""
        echo -n -e "${YELLOW}  Remove downloaded files in ../downloads/? (y/N): ${NC}"
        read -r confirm_downloads
        if [[ "$confirm_downloads" =~ ^[Yy]$ ]]; then
            rm -rf ../downloads
            print_ok "Downloaded files removed"
        else
            print_info "Downloaded files kept"
        fi
    fi

    # Clean up packaged tarballs
    TARBALLS=$(find . -maxdepth 1 -name "virt-poc-*.tar.gz" 2>/dev/null || true)
    if [ -n "$TARBALLS" ]; then
        echo ""
        echo -n -e "${YELLOW}  Remove packaged tarballs? (y/N): ${NC}"
        read -r confirm_tarballs
        if [[ "$confirm_tarballs" =~ ^[Yy]$ ]]; then
            rm -f virt-poc-*.tar.gz
            print_ok "Tarballs removed"
        else
            print_info "Tarballs kept"
        fi
    fi

    echo ""
    print_ok "Cleanup complete!"
    echo ""
    exit 0
fi

# =============================================================================
# cleanup subcommand
# =============================================================================
if [ "$ARG1" = "cleanup" ]; then
    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift."
        exit 1
    fi

    if [ -f "$ENV_FILE" ]; then
        set -a
        source "$ENV_FILE"
        set +a
    fi

    if [[ "$ARG2" =~ ^[0-9]+$ ]]; then
        TARGET_NUM=$(printf "%02d" "$ARG2")
        TARGET_DIR=$(find "$SCRIPT_DIR" -maxdepth 1 -type d -name "${TARGET_NUM}-*" | head -1)
        if [ -z "$TARGET_DIR" ]; then
            print_error "Directory not found: ${TARGET_NUM}-*"
            exit 1
        fi
        dir_name=$(basename "$TARGET_DIR")
        script="${TARGET_DIR}/${dir_name}.sh"
        if [ ! -f "$script" ]; then
            print_error "Script not found: ${script}"
            exit 1
        fi
        print_info "--cleanup: ${dir_name}"
        bash "$script" --cleanup || true
        exit 0
    fi

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  poc.sh cleanup — Running --cleanup for all steps${NC}"
    echo -e "${YELLOW}  Deletes resources created by each script in reverse order.${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -n -e "${YELLOW}  Are you sure you want to run this? (y/N): ${NC}"
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "Cancelled."
        exit 0
    fi

    echo ""
    CLEANUP_STEPS=()
    while IFS= read -r dir; do
        CLEANUP_STEPS+=("$(basename "$dir")")
    done < <(find "$SCRIPT_DIR" -maxdepth 1 -type d -name '[0-9][0-9]-*' | grep -v '/00-' | sort -r)

    for dir_name in "${CLEANUP_STEPS[@]}"; do
        script="${SCRIPT_DIR}/${dir_name}/${dir_name}.sh"
        if [ -f "$script" ]; then
            print_info "--cleanup: ${dir_name}"
            bash "$script" --cleanup || true
        fi
    done

    echo ""
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  Full --cleanup complete!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    exit 0
fi

# =============================================================================
# status subcommand
# =============================================================================
if [ "$ARG1" = "status" ]; then
    if [ ! -f "$ENV_FILE" ]; then
        print_error "env.conf not found. Please run setup.sh first."
        exit 1
    fi
    set -a; source "$ENV_FILE"; set +a

    if ! oc whoami &>/dev/null; then
        print_error "Not logged into OpenShift."
        exit 1
    fi

    check_ns()       { oc get ns "$1" &>/dev/null; }
    check_resource() { oc get "$1" "$2" -n "$3" &>/dev/null; }

    lab_status() {
        case "$1" in
            01) check_resource template poc openshift ;;
            02) check_ns poc-network ;;
            03) check_ns poc-vm ;;
            04) check_ns poc-multitenancy-1 ;;
            05) check_ns poc-network-policy-1 ;;
            06) check_ns poc-resource-quota ;;
            07) check_ns poc-descheduler ;;
            08) check_ns poc-liveness-probe ;;
            09) check_ns poc-alert ;;
            10) check_ns poc-node-exporter ;;
            11) check_resource monitoringstack poc-monitoring-stack poc-monitoring 2>/dev/null ;;
            12) check_resource configmap poc-vm-overview-dashboard openshift-config-managed 2>/dev/null ;;
            13) check_ns poc-mtv ;;
            14) check_ns poc-oadp ;;
            15) check_ns poc-maintenance ;;
            16) check_ns poc-snr ;;
            17) check_ns poc-far ;;
            18) return 2 ;;
            19) return 2 ;;
            20) check_resource lokistack logging-loki openshift-logging 2>/dev/null ;;
            21) return 2 ;;
            *)  return 1 ;;
        esac
    }

    lab_operators() {
        case "$1" in
            01) echo "VIRT:${VIRT_INSTALLED:-false}" ;;
            02) echo "NMSTATE:${NMSTATE_INSTALLED:-false}" ;;
            03|04|05|06|08|10) echo "VIRT:${VIRT_INSTALLED:-false}" ;;
            07) echo "VIRT:${VIRT_INSTALLED:-false} DESCHEDULER:${DESCHEDULER_INSTALLED:-false}" ;;
            09) echo "" ;;
            11) echo "COO:${COO_INSTALLED:-false}" ;;
            12) echo "" ;;
            13) echo "MTV:${MTV_INSTALLED:-false}" ;;
            14) echo "OADP:${OADP_INSTALLED:-false}" ;;
            15) echo "VIRT:${VIRT_INSTALLED:-false} NMO:${NMO_INSTALLED:-false}" ;;
            16) echo "SNR:${SNR_INSTALLED:-false} NHC:${NHC_INSTALLED:-false}" ;;
            17) echo "FAR:${FAR_INSTALLED:-false} NHC:${NHC_INSTALLED:-false}" ;;
            18|19|21) echo "" ;;
            20) echo "LOGGING:${LOGGING_INSTALLED:-false} LOKI:${LOKI_INSTALLED:-false}" ;;
            *)  echo "" ;;
        esac
    }

    operators_ok() {
        local ops="$1"
        [ -z "$ops" ] && return 0
        for pair in $ops; do
            local val="${pair#*:}"
            [ "$val" != "true" ] && return 1
        done
        return 0
    }

    format_operators() {
        local ops="$1"
        [ -z "$ops" ] && { echo "—"; return; }
        local result=""
        for pair in $ops; do
            local name="${pair%%:*}" val="${pair#*:}"
            if [ "$val" = "true" ]; then
                result+="${GREEN}${name}${NC} "
            else
                result+="${RED}${name}${NC} "
            fi
        done
        echo -e "$result"
    }

    step_desc() {
        case "$1" in
            01) echo "Template Registration" ;;
            02) echo "Secondary Network" ;;
            03) echo "VM Workload" ;;
            04) echo "Multi-tenancy" ;;
            05) echo "NetworkPolicy" ;;
            06) echo "ResourceQuota" ;;
            07) echo "Descheduler" ;;
            08) echo "Liveness Probe" ;;
            09) echo "VM Alert" ;;
            10) echo "Node Exporter" ;;
            11) echo "COO MonitoringStack" ;;
            12) echo "Grafana Dashboard" ;;
            13) echo "MTV Migration" ;;
            14) echo "OADP Backup/Restore" ;;
            15) echo "Node Maintenance" ;;
            16) echo "SNR Self-Recovery" ;;
            17) echo "FAR Fence Agent" ;;
            18) echo "Add/Remove Node" ;;
            19) echo "HyperConverged Config" ;;
            20) echo "Audit Logging" ;;
            21) echo "Airgap Upgrade" ;;
            *)  echo "$1" ;;
        esac
    }

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  virt-poc Lab Status${NC}   $(oc whoami) @ $(oc whoami --show-server)"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    printf "  ${CYAN}%-4s %-24s %-20s %s${NC}\n" "Lab" "Description" "Status" "Operators"
    echo "  ──────────────────────────────────────────────────────────────────────"

    DONE=0 NOT_DONE=0 SKIP=0 NA=0
    for num in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21; do
        dir_exists=$(find "$SCRIPT_DIR" -maxdepth 1 -type d -name "${num}-*" 2>/dev/null | head -1)
        [ -z "$dir_exists" ] && continue

        desc=$(step_desc "$num")
        ops=$(lab_operators "$num")
        ops_fmt=$(format_operators "$ops")

        lab_status "$num" && rc=0 || rc=$?

        if [ $rc -eq 2 ]; then
            printf "  %-4s %-24s ${DIM}%-20s${NC} %b\n" "$num" "$desc" "—  N/A" "$ops_fmt"
            NA=$((NA+1))
        elif ! operators_ok "$ops"; then
            printf "  %-4s %-24s ${YELLOW}%-20s${NC} %b\n" "$num" "$desc" "⚠  Operator N/A" "$ops_fmt"
            SKIP=$((SKIP+1))
        elif [ $rc -eq 0 ]; then
            printf "  %-4s %-24s ${GREEN}%-20s${NC} %b\n" "$num" "$desc" "✔  Done" "$ops_fmt"
            DONE=$((DONE+1))
        else
            printf "  %-4s %-24s ${DIM}%-20s${NC} %b\n" "$num" "$desc" "·  Not done" "$ops_fmt"
            NOT_DONE=$((NOT_DONE+1))
        fi
    done

    echo "  ──────────────────────────────────────────────────────────────────────"
    printf "  Done: ${GREEN}%d${NC}  Not done: %d  Operator N/A: ${YELLOW}%d${NC}  N/A: %d\n" \
        "$DONE" "$NOT_DONE" "$SKIP" "$NA"
    echo ""
    exit 0
fi

# Check and load env.conf
if [ ! -f "$ENV_FILE" ]; then
    print_error "env.conf not found. Please run setup.sh first."
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

POC_SETUP_DIR="${SCRIPT_DIR}/poc-setup"

# Determine execution mode
MODE="all"
START_NUM=""

if [ "$ARG1" = "from" ] && [[ "$ARG2" =~ ^[0-9]+$ ]]; then
    MODE="from"
    START_NUM=$(printf "%02d" "$ARG2")
elif [[ "$ARG1" =~ ^[0-9]+$ ]]; then
    MODE="only"
    START_NUM=$(printf "%02d" "$ARG1")
elif [ "$ARG1" != "start" ]; then
    print_error "Unknown argument: $ARG1"
    echo -e "  Run ${CYAN}./poc.sh${NC} to see usage."
    exit 1
fi

# Collect numbered directories in sorted order
ALL_STEPS=()
while IFS= read -r dir; do
    ALL_STEPS+=("$(basename "$dir")")
done < <(find "$SCRIPT_DIR" -maxdepth 1 -type d -name '[0-9][0-9]-*' | grep -v '/00-' | sort)

if [ ${#ALL_STEPS[@]} -eq 0 ]; then
    print_error "No steps to run. No 01-, 02-... directories found."
    exit 1
fi

# Filter steps to run based on mode
STEPS=()
for dir in "${ALL_STEPS[@]}"; do
    NUM="${dir:0:2}"
    NUM_INT=$((10#$NUM))
    START_INT=$((10#${START_NUM:-0}))
    case "$MODE" in
        only) [ "$NUM_INT" -eq "$START_INT" ] && STEPS+=("$dir") ;;
        from) [ "$NUM_INT" -ge "$START_INT" ] && STEPS+=("$dir") ;;
        all)  STEPS+=("$dir") ;;
    esac
done

if [ ${#STEPS[@]} -eq 0 ]; then
    print_error "No steps to run. (No directory matching step ${START_NUM})"
    exit 1
fi

# Clean poc-setup directory
if [ "$MODE" = "all" ]; then
    if [ -d "$POC_SETUP_DIR" ]; then
        print_info "Deleting poc-setup and starting fresh..."
        rm -rf "$POC_SETUP_DIR"
    fi
elif [ "$MODE" = "only" ]; then
    for dir in "${STEPS[@]}"; do
        if [ -d "${POC_SETUP_DIR}/${dir}" ]; then
            print_info "Deleting poc-setup/${dir} and starting fresh..."
            rm -rf "${POC_SETUP_DIR:?}/${dir}"
        fi
    done
fi

TOTAL=${#STEPS[@]}

# Step status array (index-aligned): pending / ok / skip / fail
STEP_RESULTS=()
for i in $(seq 0 $((TOTAL - 1))); do
    STEP_RESULTS+=("pending")
done

# Step description
step_desc() {
    case "$1" in
        01-template)         echo "DataVolume upload → DataSource → Template registration" ;;
        02-network)          echo "NNCP $(nncp_type_label "${NNCP_IFACE_TYPE:-linux-bridge}") (${BRIDGE_NAME:-br-poc}) + NAD + VM creation" ;;
        03-vm-workload)      echo "VM Workload — Namespace + NAD + VM (poc template + bridge network)" ;;
        04-multitenancy)     echo "Multi-tenancy — Namespaces, Users, RBAC, VMs" ;;
        05-network-policy)   echo "NetworkPolicy / MultiNetworkPolicy — eth0 or eth1 policy practice" ;;
        06-resource-quota)   echo "ResourceQuota — CPU, Memory, Pod, PVC limits" ;;
        07-descheduler)      echo "Descheduler — VM automatic rescheduling (Operator required)" ;;
        08-liveness-probe)   echo "VM Liveness Probe — HTTP, TCP, Exec" ;;
        09-alert)            echo "VM Alert — PrometheusRule notification" ;;
        10-node-exporter)    echo "Node Exporter — Custom metric collection" ;;
        11-coo)              echo "COO — Cluster Observability Operator MonitoringStack + VM node_exporter" ;;
        12-grafana)          echo "Grafana — OpenShift console built-in dashboards (no operator)" ;;
        13-mtv)              echo "MTV — VMware → OpenShift migration (Operator required)" ;;
        14-oadp)             echo "OADP — VM backup/restore (Operator required)" ;;
        15-node-maintenance) echo "Node Maintenance — Node maintenance VM Migration (Operator required)" ;;
        16-snr)              echo "SNR — Node self-restart recovery (Operator required)" ;;
        17-far)              echo "FAR — IPMI/BMC power restart recovery (Operator required)" ;;
        18-add-node)         echo "Worker node removal and rejoin" ;;
        19-hyperconverged)   echo "HyperConverged — CPU Overcommit configuration" ;;
        20-logging)          echo "Audit Logging — LokiStack, ClusterLogForwarder" ;;
        21-upgrade)          echo "Airgap Upgrade — oc-mirror, IDMS, OSUS" ;;
        *)                   echo "$1" ;;
    esac
}

# Print progress table
print_progress() {
    local completed=0 skipped=0 failed=0
    for r in "${STEP_RESULTS[@]}"; do
        case "$r" in
            ok)   completed=$((completed+1)) ;;
            skip) skipped=$((skipped+1)) ;;
            fail) failed=$((failed+1)) ;;
        esac
    done

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "${CYAN}  Progress  Completed:%-3d Skipped:%-3d Failed:%-3d / Total:%-3d${NC}\n" \
        "$completed" "$skipped" "$failed" "$TOTAL"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "  %-28s %s\n" "Step" "Status"
    echo "  ──────────────────────────────────────────────────────────"

    local i=0
    for dir in "${STEPS[@]}"; do
        local result="${STEP_RESULTS[$i]}"
        local desc
        desc=$(step_desc "$dir")
        case "$result" in
            ok)
                printf "  ${GREEN}[✔]${NC} %-26s ${GREEN}→ Done${NC}  ${DIM}%s${NC}\n" \
                    "$dir" "$desc"
                ;;
            skip)
                printf "  ${YELLOW}[~]${NC} %-26s ${YELLOW}→ Skipped${NC}  ${DIM}%s${NC}\n" \
                    "$dir" "$desc"
                ;;
            fail)
                printf "  ${RED}[✘]${NC} %-26s ${RED}→ Failed${NC}  ${DIM}%s${NC}\n" \
                    "$dir" "$desc"
                ;;
            pending)
                printf "  ${DIM}[·] %-26s   Pending  %s${NC}\n" \
                    "$dir" "$desc"
                ;;
        esac
        i=$((i+1))
    done
    echo "  ──────────────────────────────────────────────────────────"
    echo ""
}

# =============================================================================
# oc patch wrapper — saves final YAML to poc-setup/<step>/ after patch execution
# =============================================================================
_OC_WRAP_DIR=""
if command -v oc &>/dev/null; then
    _OC_REAL=$(command -v oc)
    _OC_WRAP_DIR=$(mktemp -d)
    echo "${_OC_REAL}" > "${_OC_WRAP_DIR}/.oc_real"
    cat > "${_OC_WRAP_DIR}/oc" <<'OC_WRAPPER_EOF'
#!/bin/bash
# oc wrapper: saves final YAML to POC_PATCH_SAVE_DIR after 'oc patch' execution
_R=$(cat "$(dirname "${BASH_SOURCE[0]}")/.oc_real")
"$_R" "$@"
_X=$?
if [ "${1:-}" = "patch" ] && [ "$_X" -eq 0 ] && [ -n "${POC_PATCH_SAVE_DIR:-}" ]; then
    _K="${2:-}"; _N="${3:-}"; _NS=""; _P=""
    for _A in "$@"; do
        { [ "$_P" = "-n" ] || [ "$_P" = "--namespace" ]; } && _NS="$_A"
        case "$_A" in --namespace=*) _NS="${_A#--namespace=}" ;; esac
        _P="$_A"
    done
    if [ -n "$_K" ] && [ -n "$_N" ]; then
        _FNAME=$(echo "${_K}-${_N}" | tr '/' '-')
        _OUT="${POC_PATCH_SAVE_DIR}/${_FNAME}-patched.yaml"
        if [ -n "$_NS" ]; then
            "$_R" get "$_K" "$_N" -n "$_NS" -o yaml > "$_OUT" 2>/dev/null && \
                echo -e "\033[0;34m[patch-save]\033[0m ${_FNAME}-patched.yaml" || true
        else
            "$_R" get "$_K" "$_N" -o yaml > "$_OUT" 2>/dev/null && \
                echo -e "\033[0;34m[patch-save]\033[0m ${_FNAME}-patched.yaml" || true
        fi
    fi
fi
exit "$_X"
OC_WRAPPER_EOF
    chmod +x "${_OC_WRAP_DIR}/oc"
fi

# Start header
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
case "$MODE" in
    only) echo -e "${CYAN}  virt-poc — Running step ${START_NUM} only${NC}" ;;
    from) echo -e "${CYAN}  virt-poc — Running from step ${START_NUM} (total ${TOTAL} steps)${NC}" ;;
    all)  echo -e "${CYAN}  virt-poc running all steps (total ${TOTAL} steps)${NC}" ;;
esac
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Print initial status table
print_progress

# Run in order
IDX=0
for dir in "${STEPS[@]}"; do
    SH_FILE="${SCRIPT_DIR}/${dir}/${dir}.sh"

    echo ""
    IDX=$((IDX + 1))
    echo -e "${CYAN}━━━ [${IDX}/${TOTAL}] ${dir} ━━━${NC}"

    if [ ! -f "$SH_FILE" ]; then
        print_error "Script not found: ${dir}/${dir}.sh — skipping"
        STEP_RESULTS[$((IDX-1))]="skip"
        print_progress
        continue
    fi

    OUT_DIR="${POC_SETUP_DIR}/${dir}"
    mkdir -p "$OUT_DIR"

    print_info "Running: ${dir}/${dir}.sh  (generated files → poc-setup/${dir}/)"
    set +e
    if [ -n "${_OC_WRAP_DIR:-}" ]; then
        (cd "$OUT_DIR" && PATH="${_OC_WRAP_DIR}:${PATH}" POC_PATCH_SAVE_DIR="$OUT_DIR" bash "$SH_FILE")
    else
        (cd "$OUT_DIR" && bash "$SH_FILE")
    fi
    EXIT_CODE=$?
    set -e

    if [ $EXIT_CODE -eq 0 ]; then
        STEP_RESULTS[$((IDX-1))]="ok"
        print_ok "${dir} done"
    elif [ $EXIT_CODE -eq 77 ]; then
        STEP_RESULTS[$((IDX-1))]="skip"
        echo -e "${YELLOW}[make]${NC} ${dir} skipped (operator not installed)"
    else
        STEP_RESULTS[$((IDX-1))]="fail"
        print_error "${dir} failed (exit code: ${EXIT_CODE})"
        print_progress
        exit $EXIT_CODE
    fi

    print_progress
done

# Clean up oc wrapper
if [ -n "${_OC_WRAP_DIR:-}" ]; then
    rm -rf "${_OC_WRAP_DIR}"
fi

if [ "$MODE" != "only" ]; then
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  All steps complete!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${CYAN}  poc- namespace list:${NC}"
echo ""
ns_desc() {
    case "$1" in
        poc-vm)             echo "03 VM Workload lab — VM creation, storage, networking, Live Migration" ;;
        tenant-ns1)               echo "04 Multi-tenancy — NS1 (user1 admin / user3 view)" ;;
        tenant-ns2)               echo "04 Multi-tenancy — NS2 (user2 admin / user4 view)" ;;
        poc-network-policy-1)     echo "05 NetworkPolicy lab — NS1 (Deny All / Allow Same NS)" ;;
        poc-network-policy-2)     echo "05 NetworkPolicy lab — NS2 (Deny All / Allow Same NS)" ;;
        poc-resource-quota)       echo "06 ResourceQuota lab — CPU, Memory, Pod, PVC limits" ;;
        poc-descheduler)          echo "07 Descheduler lab — VM automatic rescheduling on node overload" ;;
        poc-liveness-probe)       echo "08 Liveness Probe lab — HTTP, TCP, Exec Probe configuration and auto-restart" ;;
        poc-alert)                echo "09 VM Alert lab — PrometheusRule VM status notification" ;;
        poc-node-exporter)        echo "10 Node Exporter lab — Custom metric collection" ;;
        poc-monitoring)           echo "10-12 Monitoring lab — node-exporter, COO, Grafana" ;;
        poc-mtv)                  echo "13 MTV lab — VMware → OpenShift migration" ;;
        poc-oadp)                 echo "14 OADP lab — VM backup/restore" ;;
        poc-maintenance)          echo "15 Node Maintenance lab — VM Live Migration during node maintenance" ;;
        poc-snr)                  echo "16 SNR lab — NHC detection → node self-restart recovery" ;;
        poc-far)                  echo "17 FAR lab — NHC detection → IPMI/BMC power restart recovery" ;;
        *)                  echo "" ;;
    esac
}
oc get namespace --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep '^poc-' | \
    while read -r ns; do
        desc=$(ns_desc "$ns")
        if [ -n "$desc" ]; then
            echo -e "    ${GREEN}●${NC} ${ns}  ${YELLOW}# ${desc}${NC}"
        else
            echo -e "    ${GREEN}●${NC} ${ns}"
        fi
    done
echo ""
fi
