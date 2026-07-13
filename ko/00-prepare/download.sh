#!/bin/bash
# =============================================================================
# download.sh
#
# 폐쇄망 OpenShift Virtualization POC에 필요한 모든 파일 다운로드
#
# 이 스크립트는 다음을 다운로드합니다:
#   - RHEL9 qcow2 이미지
#   - Garage 컨테이너 이미지 (tar로 내보내기)
#   - Node exporter 바이너리
#   - MC 클라이언트 바이너리 (S3 테스트용)
#   - 샘플 VM 디스크 이미지 (선택사항)
#
# 사용법: ./download.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOWNLOAD_DIR="${SCRIPT_DIR}/downloads"

source "${SCRIPT_DIR}/../utils/common.sh"

# =============================================================================
# 설정
# =============================================================================

# RHEL9 이미지 (실제 다운로드 URL로 교체하세요)
RHEL9_IMAGE_URL="${RHEL9_IMAGE_URL:-https://access.redhat.com/downloads/content/rhel}"
RHEL9_IMAGE_NAME="rhel-9.5-x86_64-kvm.qcow2"

# Garage 버전
GARAGE_VERSION="v1.0.1"
GARAGE_IMAGE="docker.io/dxflrs/garage:${GARAGE_VERSION}"

# Node exporter 버전
NODE_EXPORTER_VERSION="1.10.2"
NODE_EXPORTER_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

# MC (MinIO Client) 버전
MC_VERSION="latest"
MC_URL="https://dl.min.io/client/mc/release/linux-amd64/mc"

# =============================================================================
# 사전 점검
# =============================================================================
preflight() {
    print_step "사전 점검"

    # 필수 명령어 확인
    local required_cmds=("curl" "wget" "podman")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            print_error "필수 명령어를 찾을 수 없습니다: $cmd"
            print_error "설치해 주세요: $cmd"
            exit 1
        fi
    done
    print_ok "필수 명령어 사용 가능"

    # 다운로드 디렉토리 생성
    mkdir -p "$DOWNLOAD_DIR"/{images,binaries,containers}
    print_ok "다운로드 디렉토리 생성됨: ${DOWNLOAD_DIR}"
}

# =============================================================================
# RHEL9 qcow2 이미지 다운로드
# =============================================================================
download_rhel9() {
    print_step "1/5  RHEL9 qcow2 이미지 다운로드"

    local target="${DOWNLOAD_DIR}/images/${RHEL9_IMAGE_NAME}"

    if [ -f "$target" ]; then
        print_ok "RHEL9 이미지가 이미 존재합니다: ${target}"
        return
    fi

    echo ""
    print_warn "RHEL9 이미지 다운로드에는 Red Hat 구독이 필요합니다."
    print_info "수동으로 다운로드해 주세요: https://access.redhat.com/downloads/content/rhel"
    print_info "다운로드: RHEL 9.5 KVM Guest Image (rhel-9.5-x86_64-kvm.qcow2)"
    print_info "저장 위치: ${target}"
    echo ""
    read -r -p "RHEL9 이미지를 이미 다운로드하셨습니까? [y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        read -r -p "RHEL9 qcow2 이미지의 전체 경로를 입력하세요: " rhel_path
        if [ -f "$rhel_path" ]; then
            cp "$rhel_path" "$target"
            print_ok "RHEL9 이미지 복사됨: ${target}"
        else
            print_error "파일을 찾을 수 없습니다: $rhel_path"
            exit 1
        fi
    else
        print_warn "RHEL9 이미지 다운로드 건너뜀 (나중에 추가할 수 있습니다)"
        touch "${target}.placeholder"
        cat > "${DOWNLOAD_DIR}/images/README.txt" <<EOF
RHEL9 KVM Guest Image를 수동으로 다운로드해 주세요:

1. 이동: https://access.redhat.com/downloads/content/rhel
2. 다운로드: RHEL 9.5 KVM Guest Image (rhel-9.5-x86_64-kvm.qcow2)
3. 저장 위치: ${target}
4. package.sh를 다시 실행하여 최종 tarball을 생성하세요
EOF
    fi
}

# =============================================================================
# Garage 컨테이너 이미지 내보내기
# =============================================================================
download_garage() {
    print_step "2/5  Garage 컨테이너 이미지 내보내기"

    local target="${DOWNLOAD_DIR}/containers/garage-${GARAGE_VERSION}.tar"

    if [ -f "$target" ]; then
        print_ok "Garage 이미지가 이미 내보내기 되었습니다: ${target}"
        return
    fi

    print_info "Garage 이미지 Pull 중: ${GARAGE_IMAGE}"
    podman pull "${GARAGE_IMAGE}"

    print_info "tar로 내보내는 중: ${target}"
    podman save -o "$target" "${GARAGE_IMAGE}"

    print_ok "Garage 이미지 내보내기 완료: ${target}"
    ls -lh "$target"
}

# =============================================================================
# node_exporter 바이너리 다운로드
# =============================================================================
download_node_exporter() {
    print_step "3/5  node_exporter 바이너리 다운로드"

    local target="${DOWNLOAD_DIR}/binaries/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

    if [ -f "$target" ]; then
        print_ok "node_exporter가 이미 존재합니다: ${target}"
        return
    fi

    print_info "다운로드 중: ${NODE_EXPORTER_URL}"
    curl -L -o "$target" "${NODE_EXPORTER_URL}"

    print_ok "node_exporter 다운로드 완료: ${target}"
    ls -lh "$target"
}

# =============================================================================
# mc (MinIO Client) 바이너리 다운로드
# =============================================================================
download_mc() {
    print_step "4/5  mc (MinIO/Garage Client) 바이너리 다운로드"

    local target="${DOWNLOAD_DIR}/binaries/mc"

    if [ -f "$target" ]; then
        print_ok "mc 바이너리가 이미 존재합니다: ${target}"
        return
    fi

    print_info "다운로드 중: ${MC_URL}"
    curl -L -o "$target" "${MC_URL}"
    chmod +x "$target"

    print_ok "mc 바이너리 다운로드 완료: ${target}"
    ls -lh "$target"
}

# =============================================================================
# 메타데이터 파일 생성
# =============================================================================
create_metadata() {
    print_step "5/5  메타데이터 파일 생성"

    cat > "${DOWNLOAD_DIR}/METADATA.txt" <<EOF
OpenShift Virtualization POC - 다운로드된 파일
================================================

다운로드 날짜: $(date '+%Y-%m-%d %H:%M:%S')
스크립트 버전: 1.0

파일:
------
1. RHEL9 이미지:
   - 경로: images/${RHEL9_IMAGE_NAME}
   - 용도: VM Template 생성 (01-template)

2. Garage 컨테이너:
   - 경로: containers/garage-${GARAGE_VERSION}.tar
   - 버전: ${GARAGE_VERSION}
   - 용도: OADP/Logging용 S3 오브젝트 스토리지 (14-oadp, 20-logging)

3. Node Exporter:
   - 경로: binaries/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
   - 버전: ${NODE_EXPORTER_VERSION}
   - 용도: VM 모니터링 (10-node-exporter)

4. MC Client:
   - 경로: binaries/mc
   - 용도: S3/Garage 버킷 관리

설치:
-------------
1. bastion 호스트에서 이 패키지를 압축 해제하세요
2. 실행: ./00-prepare/install.sh
3. 설치 가이드를 따르세요

폐쇄망 설치의 경우:
- 모든 컨테이너 이미지는 내부 레지스트리에 미러링해야 합니다
- RHEL9 이미지는 virtctl을 통해 업로드됩니다
- 바이너리는 대상 VM/노드에 복사됩니다

EOF

    print_ok "메타데이터 파일 생성됨: ${DOWNLOAD_DIR}/METADATA.txt"
    cat "${DOWNLOAD_DIR}/METADATA.txt"
}

# =============================================================================
# Main
# =============================================================================
main() {
    print_step "OpenShift Virtualization POC - 다운로드 스크립트"
    echo ""
    print_info "이 스크립트는 폐쇄망 설치에 필요한 파일을 다운로드합니다."
    print_info "대상 디렉토리: ${DOWNLOAD_DIR}"
    echo ""

    preflight
    download_rhel9
    download_garage
    download_node_exporter
    download_mc
    create_metadata

    echo ""
    print_step "다운로드 요약"
    echo ""
    print_ok "모든 다운로드가 완료되었습니다!"
    print_info "다운로드 위치: ${DOWNLOAD_DIR}"
    echo ""
    print_info "전체 크기:"
    du -sh "$DOWNLOAD_DIR"
    echo ""
    print_info "다음 단계: ./package.sh를 실행하여 배포용 tarball을 생성하세요"
}

main "$@"
