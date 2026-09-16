#!/bin/bash
# =============================================================================
# poc.sh
#
# 번호가 매겨진 디렉토리 (01-, 02-, ...)의 .sh 파일을 순서대로 실행합니다.
# setup.sh를 먼저 실행하여 env.conf를 생성하세요.
#   예) 01-template/01-template.sh
#       02-network/02-network.sh
#       03-vm-workload/03-vm-workload.sh
#
# 사용법:
#   ./poc.sh            사용법 출력
#   ./poc.sh start      모든 단계 실행
#   ./poc.sh 7          07번 단계만 실행
#   ./poc.sh from 7     07번 단계부터 끝까지 실행
#   ./poc.sh reset      모든 poc- namespace 삭제
# =============================================================================

set -euo pipefail
POC_VERSION="v2026.09.16-1"
trap 'echo -e "\n\033[0;31m[오류]\033[0m ${LINENO}번째 줄에서 명령 실패: ${BASH_COMMAND}" >&2' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/env.conf"

source "$(dirname "${BASH_SOURCE[0]}")/utils/common.sh"

print_info()  { echo -e "${CYAN}[make]${NC} $1"; }
print_ok()    { echo -e "${GREEN}[make]${NC} $1"; }
print_error() { echo -e "${RED}[make]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[make]${NC} $1"; }

# 인자 파싱
ARG1="${1:-}"
ARG2="${2:-}"

# =============================================================================
# 인자 없음 → 사용법 출력
# =============================================================================
if [ -z "$ARG1" ]; then
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  virt-poc poc.sh${NC}"
    echo -e "${DIM}  ${POC_VERSION}${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  사용법:"
    echo -e "    ${CYAN}./poc.sh start${NC}        모든 단계 실행"
    echo -e "    ${CYAN}./poc.sh 7${NC}            07번 단계만 실행"
    echo -e "    ${CYAN}./poc.sh from 7${NC}       07번 단계부터 끝까지 실행"
    echo -e "    ${CYAN}./poc.sh status${NC}       Lab 완료 상태 확인"
    echo -e "    ${CYAN}./poc.sh reset${NC}        poc- namespace + 생성된 파일 삭제"
    echo -e "    ${CYAN}./poc.sh cleanup${NC}      각 단계를 역순으로 --cleanup 실행"
    echo -e "    ${CYAN}./poc.sh cleanup 7${NC}    07번 단계만 --cleanup 실행"
    echo ""
    exit 0
fi

# =============================================================================
# reset 하위 명령
# =============================================================================
if [ "$ARG1" = "reset" ]; then
    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
        exit 1
    fi

    NAMESPACES=$(oc get namespace --no-headers \
        -o custom-columns=NAME:.metadata.name 2>/dev/null | grep '^poc-' || true)

    if [ -z "$NAMESPACES" ]; then
        print_info "삭제할 poc- namespace가 없습니다."
        exit 0
    fi

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  poc.sh reset — 다음 namespace를 삭제합니다${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo "$NAMESPACES" | while read -r ns; do
        echo -e "    ${YELLOW}●${NC} ${ns}"
    done
    echo ""
    echo -n -e "${YELLOW}  정말 삭제하시겠습니까? (y/N): ${NC}"
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "취소됨."
        exit 0
    fi

    echo ""
    echo "$NAMESPACES" | while read -r ns; do
        print_info "삭제 중: ${ns}"
        oc delete namespace "$ns" --wait=false 2>/dev/null && \
            print_ok "${ns} 삭제 요청됨" || \
            print_warn "${ns} 삭제 실패 (이미 삭제되었거나 권한 부족)"
    done

    echo ""
    print_info "namespace 삭제 완료를 대기 중..."
    echo ""
    while true; do
        REMAINING=$(oc get namespace --no-headers \
            -o custom-columns=NAME:.metadata.name 2>/dev/null | grep '^poc-' || true)
        if [ -z "$REMAINING" ]; then
            break
        fi
        echo -e "  ${YELLOW}남은 namespace:${NC}"
        echo "$REMAINING" | while read -r ns; do
            echo -e "    ${YELLOW}●${NC} ${ns}"
        done
        sleep 5
        echo ""
    done
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${GREEN}  모든 poc- namespace가 삭제되었습니다!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    # 생성된 파일 정리
    print_info "생성된 파일을 정리하는 중..."
    echo ""

    # 생성된 YAML 파일 찾아서 삭제 (git 추적되는 소스 파일은 제외)
    YAML_FILES=$(find . -maxdepth 2 -path './[0-9][0-9]-*' -type f \( \
        -name "*.yaml" -o \
        -name "*.yml" \
        \) 2>/dev/null | while read -r f; do
        git ls-files --error-unmatch "$f" &>/dev/null || echo "$f"
    done)

    if [ -n "$YAML_FILES" ]; then
        echo -e "${YELLOW}  생성된 YAML 파일:${NC}"
        echo "$YAML_FILES" | while read -r file; do
            [ -n "$file" ] && echo -e "    ${DIM}✗${NC} ${file}" && rm -f "$file"
        done
    fi

    # 임시 파일 정리
    find . -type f \( \
        -name "*.tmp" -o \
        -name "*.log" -o \
        -name ".DS_Store" -o \
        -name "*.swp" -o \
        -name "*~" \
        \) -delete 2>/dev/null || true

    # 다운로드된 파일 정리 (선택 사항 - 사용자에게 확인)
    if [ -d "../downloads" ]; then
        echo ""
        echo -n -e "${YELLOW}  ../downloads/의 다운로드된 파일을 삭제하시겠습니까? (y/N): ${NC}"
        read -r confirm_downloads
        if [[ "$confirm_downloads" =~ ^[Yy]$ ]]; then
            rm -rf ../downloads
            print_ok "다운로드된 파일 삭제됨"
        else
            print_info "다운로드된 파일 유지됨"
        fi
    fi

    # 패키징된 tarball 정리
    TARBALLS=$(find . -maxdepth 1 -name "virt-poc-*.tar.gz" 2>/dev/null || true)
    if [ -n "$TARBALLS" ]; then
        echo ""
        echo -n -e "${YELLOW}  패키징된 tarball을 삭제하시겠습니까? (y/N): ${NC}"
        read -r confirm_tarballs
        if [[ "$confirm_tarballs" =~ ^[Yy]$ ]]; then
            rm -f virt-poc-*.tar.gz
            print_ok "Tarball 삭제됨"
        else
            print_info "Tarball 유지됨"
        fi
    fi

    echo ""
    print_ok "정리 완료!"
    echo ""
    exit 0
fi

# =============================================================================
# cleanup 하위 명령
# =============================================================================
if [ "$ARG1" = "cleanup" ]; then
    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
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
            print_error "디렉토리를 찾을 수 없습니다: ${TARGET_NUM}-*"
            exit 1
        fi
        dir_name=$(basename "$TARGET_DIR")
        script="${TARGET_DIR}/${dir_name}.sh"
        if [ ! -f "$script" ]; then
            print_error "스크립트를 찾을 수 없습니다: ${script}"
            exit 1
        fi
        print_info "--cleanup: ${dir_name}"
        bash "$script" --cleanup || true
        exit 0
    fi

    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${YELLOW}  poc.sh cleanup — 모든 단계에 대해 --cleanup 실행${NC}"
    echo -e "${YELLOW}  각 스크립트가 생성한 리소스를 역순으로 삭제합니다.${NC}"
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -n -e "${YELLOW}  정말 실행하시겠습니까? (y/N): ${NC}"
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        print_info "취소됨."
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
    echo -e "${GREEN}  전체 --cleanup 완료!${NC}"
    echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    exit 0
fi

# =============================================================================
# status 하위 명령
# =============================================================================
if [ "$ARG1" = "status" ]; then
    if [ ! -f "$ENV_FILE" ]; then
        print_error "env.conf를 찾을 수 없습니다. setup.sh를 먼저 실행하세요."
        exit 1
    fi
    set -a; source "$ENV_FILE"; set +a

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift에 로그인되어 있지 않습니다."
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

    pad_right() {
        local str="$1" target="$2"
        local len=${#str}
        local byte_len
        byte_len=$(printf '%s' "$str" | LC_ALL=C wc -c | tr -d ' ')
        local dw=$(( (len + byte_len) / 2 ))
        local pad=$(( target - dw ))
        [ $pad -lt 0 ] && pad=0
        printf '%s%*s' "$str" "$pad" ""
    }

    step_desc() {
        case "$1" in
            01) echo "Template 등록" ;;
            02) echo "Secondary 네트워크" ;;
            03) echo "VM Workload" ;;
            04) echo "멀티테넌시" ;;
            05) echo "NetworkPolicy" ;;
            06) echo "ResourceQuota" ;;
            07) echo "Descheduler" ;;
            08) echo "Liveness Probe" ;;
            09) echo "VM Alert" ;;
            10) echo "Node Exporter" ;;
            11) echo "COO MonitoringStack" ;;
            12) echo "Grafana 대시보드" ;;
            13) echo "MTV 마이그레이션" ;;
            14) echo "OADP 백업/복원" ;;
            15) echo "노드 유지보수" ;;
            16) echo "SNR 자체 복구" ;;
            17) echo "FAR Fence Agent" ;;
            18) echo "노드 추가/제거" ;;
            19) echo "HyperConverged 설정" ;;
            20) echo "감사 로깅" ;;
            21) echo "Airgap 업그레이드" ;;
            *)  echo "$1" ;;
        esac
    }

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}  virt-poc Lab 상태${NC}   $(oc whoami) @ $(oc whoami --show-server)"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    printf "  ${CYAN}%-4s %s %-20s %s${NC}\n" "Lab" "$(pad_right "설명" 24)" "상태" "Operator"
    echo "  ──────────────────────────────────────────────────────────────────────"

    DONE=0 NOT_DONE=0 SKIP=0 NA=0
    for num in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21; do
        dir_exists=$(find "$SCRIPT_DIR" -maxdepth 1 -type d -name "${num}-*" 2>/dev/null | head -1)
        [ -z "$dir_exists" ] && continue

        desc=$(step_desc "$num")
        ops=$(lab_operators "$num")
        ops_fmt=$(format_operators "$ops")

        lab_status "$num" && rc=0 || rc=$?

        padded=$(pad_right "$desc" 24)

        if [ $rc -eq 2 ]; then
            printf "  %-4s %s ${DIM}%-20s${NC} %b\n" "$num" "$padded" "—  N/A" "$ops_fmt"
            NA=$((NA+1))
        elif ! operators_ok "$ops"; then
            printf "  %-4s %s ${YELLOW}%-20s${NC} %b\n" "$num" "$padded" "⚠  Operator 미설치" "$ops_fmt"
            SKIP=$((SKIP+1))
        elif [ $rc -eq 0 ]; then
            printf "  %-4s %s ${GREEN}%-20s${NC} %b\n" "$num" "$padded" "✔  완료" "$ops_fmt"
            DONE=$((DONE+1))
        else
            printf "  %-4s %s ${DIM}%-20s${NC} %b\n" "$num" "$padded" "·  미완료" "$ops_fmt"
            NOT_DONE=$((NOT_DONE+1))
        fi
    done

    echo "  ──────────────────────────────────────────────────────────────────────"
    printf "  완료: ${GREEN}%d${NC}  미완료: %d  Operator 미설치: ${YELLOW}%d${NC}  N/A: %d\n" \
        "$DONE" "$NOT_DONE" "$SKIP" "$NA"
    echo ""
    exit 0
fi

# env.conf 확인 및 로드
if [ ! -f "$ENV_FILE" ]; then
    print_error "env.conf를 찾을 수 없습니다. setup.sh를 먼저 실행하세요."
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

POC_SETUP_DIR="${SCRIPT_DIR}/poc-setup"

# 실행 모드 결정
MODE="all"
START_NUM=""

if [ "$ARG1" = "from" ] && [[ "$ARG2" =~ ^[0-9]+$ ]]; then
    MODE="from"
    START_NUM=$(printf "%02d" "$ARG2")
elif [[ "$ARG1" =~ ^[0-9]+$ ]]; then
    MODE="only"
    START_NUM=$(printf "%02d" "$ARG1")
elif [ "$ARG1" != "start" ]; then
    print_error "알 수 없는 인자: $ARG1"
    echo -e "  ${CYAN}./poc.sh${NC}를 실행하여 사용법을 확인하세요."
    exit 1
fi

# 번호가 매겨진 디렉토리를 정렬하여 수집
ALL_STEPS=()
while IFS= read -r dir; do
    ALL_STEPS+=("$(basename "$dir")")
done < <(find "$SCRIPT_DIR" -maxdepth 1 -type d -name '[0-9][0-9]-*' | grep -v '/00-' | sort)

if [ ${#ALL_STEPS[@]} -eq 0 ]; then
    print_error "실행할 단계가 없습니다. 01-, 02-... 디렉토리를 찾을 수 없습니다."
    exit 1
fi

# 모드에 따라 실행할 단계 필터링
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
    print_error "실행할 단계가 없습니다. (${START_NUM}번 단계에 해당하는 디렉토리 없음)"
    exit 1
fi

# poc-setup 디렉토리 정리
if [ "$MODE" = "all" ]; then
    if [ -d "$POC_SETUP_DIR" ]; then
        print_info "poc-setup을 삭제하고 새로 시작합니다..."
        rm -rf "$POC_SETUP_DIR"
    fi
elif [ "$MODE" = "only" ]; then
    for dir in "${STEPS[@]}"; do
        if [ -d "${POC_SETUP_DIR}/${dir}" ]; then
            print_info "poc-setup/${dir}을 삭제하고 새로 시작합니다..."
            rm -rf "${POC_SETUP_DIR:?}/${dir}"
        fi
    done
fi

TOTAL=${#STEPS[@]}

# 단계 상태 배열 (인덱스 정렬): pending / ok / skip / fail
STEP_RESULTS=()
for i in $(seq 0 $((TOTAL - 1))); do
    STEP_RESULTS+=("pending")
done

# 단계 설명
step_desc() {
    case "$1" in
        01-template)         echo "DataVolume 업로드 → DataSource → Template 등록" ;;
        02-network)          echo "NNCP $(nncp_type_label "${NNCP_IFACE_TYPE:-linux-bridge}") (${BRIDGE_NAME:-br-poc}) + NAD + VM 생성" ;;
        03-vm-workload)      echo "VM Workload — Namespace + NAD + VM (poc template + bridge 네트워크)" ;;
        04-multitenancy)     echo "멀티테넌시 — Namespace, 사용자, RBAC, VM" ;;
        05-network-policy)   echo "NetworkPolicy / MultiNetworkPolicy — eth0 또는 eth1 정책 실습" ;;
        06-resource-quota)   echo "ResourceQuota — CPU, Memory, Pod, PVC 제한" ;;
        07-descheduler)      echo "Descheduler — VM 자동 재스케줄링 (Operator 필요)" ;;
        08-liveness-probe)   echo "VM Liveness Probe — HTTP, TCP, Exec" ;;
        09-alert)            echo "VM Alert — PrometheusRule 알림" ;;
        10-node-exporter)    echo "Node Exporter — 커스텀 메트릭 수집" ;;
        11-coo)              echo "COO — Cluster Observability Operator MonitoringStack + VM node_exporter" ;;
        12-grafana)          echo "Grafana — OpenShift 콘솔 내장 대시보드 (Operator 불필요)" ;;
        13-mtv)              echo "MTV — VMware → OpenShift 마이그레이션 (Operator 필요)" ;;
        14-oadp)             echo "OADP — VM 백업/복원 (Operator 필요)" ;;
        15-node-maintenance) echo "노드 유지보수 — 노드 유지보수 시 VM Live Migration (Operator 필요)" ;;
        16-snr)              echo "SNR — 노드 자체 재시작 복구 (Operator 필요)" ;;
        17-far)              echo "FAR — IPMI/BMC 전원 재시작 복구 (Operator 필요)" ;;
        18-add-node)         echo "워커 노드 제거 및 재합류" ;;
        19-hyperconverged)   echo "HyperConverged — CPU Overcommit 설정" ;;
        20-logging)          echo "감사 로깅 — LokiStack, ClusterLogForwarder" ;;
        21-upgrade)          echo "Airgap 업그레이드 — oc-mirror, IDMS, OSUS" ;;
        *)                   echo "$1" ;;
    esac
}

# 진행 상황 테이블 출력
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
    printf "${CYAN}  진행 상황  완료:%-3d 건너뜀:%-3d 실패:%-3d / 전체:%-3d${NC}\n" \
        "$completed" "$skipped" "$failed" "$TOTAL"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    printf "  %-28s %s\n" "단계" "상태"
    echo "  ──────────────────────────────────────────────────────────"

    local i=0
    for dir in "${STEPS[@]}"; do
        local result="${STEP_RESULTS[$i]}"
        local desc
        desc=$(step_desc "$dir")
        case "$result" in
            ok)
                printf "  ${GREEN}[✔]${NC} %-26s ${GREEN}→ 완료${NC}  ${DIM}%s${NC}\n" \
                    "$dir" "$desc"
                ;;
            skip)
                printf "  ${YELLOW}[~]${NC} %-26s ${YELLOW}→ 건너뜀${NC}  ${DIM}%s${NC}\n" \
                    "$dir" "$desc"
                ;;
            fail)
                printf "  ${RED}[✘]${NC} %-26s ${RED}→ 실패${NC}  ${DIM}%s${NC}\n" \
                    "$dir" "$desc"
                ;;
            pending)
                printf "  ${DIM}[·] %-26s   대기 중  %s${NC}\n" \
                    "$dir" "$desc"
                ;;
        esac
        i=$((i+1))
    done
    echo "  ──────────────────────────────────────────────────────────"
    echo ""
}

# =============================================================================
# oc patch 래퍼 — patch 실행 후 최종 YAML을 poc-setup/<step>/에 저장
# =============================================================================
_OC_WRAP_DIR=""
if command -v oc &>/dev/null; then
    _OC_REAL=$(command -v oc)
    _OC_WRAP_DIR=$(mktemp -d)
    echo "${_OC_REAL}" > "${_OC_WRAP_DIR}/.oc_real"
    cat > "${_OC_WRAP_DIR}/oc" <<'OC_WRAPPER_EOF'
#!/bin/bash
# oc 래퍼: 'oc patch' 실행 후 최종 YAML을 POC_PATCH_SAVE_DIR에 저장
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

# 시작 헤더
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
case "$MODE" in
    only) echo -e "${CYAN}  virt-poc — ${START_NUM}번 단계만 실행${NC}" ;;
    from) echo -e "${CYAN}  virt-poc — ${START_NUM}번 단계부터 실행 (전체 ${TOTAL}개 단계)${NC}" ;;
    all)  echo -e "${CYAN}  virt-poc 모든 단계 실행 (전체 ${TOTAL}개 단계)${NC}" ;;
esac
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# 초기 상태 테이블 출력
print_progress

# 순서대로 실행
IDX=0
for dir in "${STEPS[@]}"; do
    SH_FILE="${SCRIPT_DIR}/${dir}/${dir}.sh"

    echo ""
    IDX=$((IDX + 1))
    echo -e "${CYAN}━━━ [${IDX}/${TOTAL}] ${dir} ━━━${NC}"

    if [ ! -f "$SH_FILE" ]; then
        print_error "스크립트를 찾을 수 없습니다: ${dir}/${dir}.sh — 건너뜁니다"
        STEP_RESULTS[$((IDX-1))]="skip"
        print_progress
        continue
    fi

    OUT_DIR="${POC_SETUP_DIR}/${dir}"
    mkdir -p "$OUT_DIR"

    print_info "실행 중: ${dir}/${dir}.sh  (생성된 파일 → poc-setup/${dir}/)"
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
        print_ok "${dir} 완료"
    elif [ $EXIT_CODE -eq 77 ]; then
        STEP_RESULTS[$((IDX-1))]="skip"
        echo -e "${YELLOW}[make]${NC} ${dir} 건너뜀 (Operator 미설치)"
    else
        STEP_RESULTS[$((IDX-1))]="fail"
        print_error "${dir} 실패 (종료 코드: ${EXIT_CODE})"
        print_progress
        exit $EXIT_CODE
    fi

    print_progress
done

# oc 래퍼 정리
if [ -n "${_OC_WRAP_DIR:-}" ]; then
    rm -rf "${_OC_WRAP_DIR}"
fi

if [ "$MODE" != "only" ]; then
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  모든 단계 완료!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${CYAN}  poc- namespace 목록:${NC}"
echo ""
ns_desc() {
    case "$1" in
        poc-vm)             echo "03 VM Workload lab — VM 생성, 스토리지, 네트워킹, Live Migration" ;;
        tenant-ns1)               echo "04 멀티테넌시 — NS1 (user1 admin / user3 view)" ;;
        tenant-ns2)               echo "04 멀티테넌시 — NS2 (user2 admin / user4 view)" ;;
        poc-network-policy-1)     echo "05 NetworkPolicy lab — NS1 (전체 거부 / 동일 NS 허용)" ;;
        poc-network-policy-2)     echo "05 NetworkPolicy lab — NS2 (전체 거부 / 동일 NS 허용)" ;;
        poc-resource-quota)       echo "06 ResourceQuota lab — CPU, Memory, Pod, PVC 제한" ;;
        poc-descheduler)          echo "07 Descheduler lab — 노드 과부하 시 VM 자동 재스케줄링" ;;
        poc-liveness-probe)       echo "08 Liveness Probe lab — HTTP, TCP, Exec Probe 설정 및 자동 재시작" ;;
        poc-alert)                echo "09 VM Alert lab — PrometheusRule VM 상태 알림" ;;
        poc-node-exporter)        echo "10 Node Exporter lab — 커스텀 메트릭 수집" ;;
        poc-monitoring)           echo "10-12 Monitoring lab — node-exporter, COO, Grafana" ;;
        poc-mtv)                  echo "13 MTV lab — VMware → OpenShift 마이그레이션" ;;
        poc-oadp)                 echo "14 OADP lab — VM 백업/복원" ;;
        poc-maintenance)          echo "15 노드 유지보수 lab — 노드 유지보수 중 VM Live Migration" ;;
        poc-snr)                  echo "16 SNR lab — NHC 감지 → 노드 자체 재시작 복구" ;;
        poc-far)                  echo "17 FAR lab — NHC 감지 → IPMI/BMC 전원 재시작 복구" ;;
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
