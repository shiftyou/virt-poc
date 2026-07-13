#!/bin/bash
# =============================================================================
# package.sh
#
# 다운로드된 파일과 함께 전체 virt-poc를 폐쇄망 전송용으로 패키징
#
# 생성물: virt-poc-<날짜>.tar.gz
#
# 사용법: ./package.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PACKAGE_NAME="virt-poc-$(date +%Y%m%d-%H%M%S)"
TEMP_DIR="/tmp/${PACKAGE_NAME}"

source "${SCRIPT_DIR}/../utils/common.sh"

# =============================================================================
# 사전 점검
# =============================================================================
preflight() {
    print_step "사전 점검"

    if [ ! -d "${SCRIPT_DIR}/downloads" ]; then
        print_error "downloads 디렉토리를 찾을 수 없습니다."
        print_error "먼저 ./download.sh를 실행해 주세요."
        exit 1
    fi

    print_ok "downloads 디렉토리 확인됨"
}

# =============================================================================
# 프로젝트 파일 복사
# =============================================================================
copy_project() {
    print_step "1/4  프로젝트 파일 복사"

    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"

    print_info "프로젝트 파일 복사 중: ${TEMP_DIR}"

    # .git 및 임시 파일을 제외하고 모든 프로젝트 파일 복사
    rsync -av \
        --exclude='.git' \
        --exclude='.gitignore' \
        --exclude='.claude' \
        --exclude='*.log' \
        --exclude='*.tmp' \
        --exclude='node_modules' \
        --exclude='__pycache__' \
        "${PROJECT_ROOT}/" "${TEMP_DIR}/"

    print_ok "프로젝트 파일 복사 완료"
}

# =============================================================================
# 설치 스크립트 생성
# =============================================================================
create_install_script() {
    print_step "2/4  설치 스크립트 생성"

    cat > "${TEMP_DIR}/00-prepare/install.sh" <<'INSTALL_EOF'
#!/bin/bash
# =============================================================================
# install.sh
#
# OpenShift Virtualization POC 폐쇄망 설치 스크립트
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DOWNLOAD_DIR="${SCRIPT_DIR}/downloads"

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
# 사전 점검
# =============================================================================
preflight() {
    print_step "사전 점검"

    if ! oc whoami &>/dev/null; then
        print_error "OpenShift 클러스터에 로그인되어 있지 않습니다."
        print_error "먼저 로그인해 주세요: oc login <cluster-api>"
        exit 1
    fi
    print_ok "클러스터 연결: $(oc whoami --show-server)"

    if ! command -v podman &>/dev/null; then
        print_error "podman 명령어를 찾을 수 없습니다."
        print_error "podman을 설치해 주세요."
        exit 1
    fi
    print_ok "podman 사용 가능"
}

# =============================================================================
# Garage 컨테이너 이미지 로드
# =============================================================================
load_garage_image() {
    print_step "1/3  Garage 컨테이너 이미지 로드"

    local garage_tar
    garage_tar=$(ls -t "${DOWNLOAD_DIR}/containers/garage-"*.tar 2>/dev/null | head -1 || true)

    if [ -z "$garage_tar" ]; then
        print_warn "downloads에서 Garage 컨테이너 이미지를 찾을 수 없습니다"
        print_warn "수동으로 pull하거나 레지스트리에 미러링해야 합니다"
        return
    fi

    print_info "Garage 이미지 로드 중: ${garage_tar}"
    podman load -i "$garage_tar"
    print_ok "Garage 이미지가 로컬 podman에 로드됨"

    echo ""
    print_info "레지스트리에 push하려면:"
    echo "  podman tag <image-id> <your-registry>/garage:v1.0.1"
    echo "  podman push <your-registry>/garage:v1.0.1"
}

# =============================================================================
# 바이너리 복사
# =============================================================================
copy_binaries() {
    print_step "2/3  프로젝트에 바이너리 복사"

    # node_exporter 복사
    local node_exporter_tar
    node_exporter_tar=$(ls -t "${DOWNLOAD_DIR}/binaries/node_exporter-"*.tar.gz 2>/dev/null | head -1 || true)
    if [ -n "$node_exporter_tar" ]; then
        cp "$node_exporter_tar" "${PROJECT_ROOT}/10-node-exporter/"
        print_ok "node_exporter가 10-node-exporter/에 복사됨"
    fi

    # mc 클라이언트 복사
    if [ -f "${DOWNLOAD_DIR}/binaries/mc" ]; then
        cp "${DOWNLOAD_DIR}/binaries/mc" "${PROJECT_ROOT}/14-oadp/"
        chmod +x "${PROJECT_ROOT}/14-oadp/mc"
        print_ok "mc 클라이언트가 14-oadp/에 복사됨"
    fi
}

# =============================================================================
# 다운로드 파일 검증
# =============================================================================
verify_downloads() {
    print_step "3/3  다운로드된 파일 검증"

    echo ""
    print_info "다운로드 검증:"

    # RHEL9 이미지 확인
    local rhel_img
    rhel_img=$(ls -t "${DOWNLOAD_DIR}/images/rhel-"*.qcow2 2>/dev/null | head -1 || true)
    if [ -n "$rhel_img" ]; then
        print_ok "RHEL9 이미지: $(basename "$rhel_img") ($(du -h "$rhel_img" | cut -f1))"
    else
        print_warn "RHEL9 이미지를 찾을 수 없습니다 - 수동으로 다운로드해 주세요"
        print_warn "  참조: ${DOWNLOAD_DIR}/images/README.txt"
    fi

    # Garage 확인
    local garage_tar
    garage_tar=$(ls -t "${DOWNLOAD_DIR}/containers/garage-"*.tar 2>/dev/null | head -1 || true)
    if [ -n "$garage_tar" ]; then
        print_ok "Garage 이미지: $(basename "$garage_tar") ($(du -h "$garage_tar" | cut -f1))"
    else
        print_warn "Garage 이미지를 찾을 수 없습니다"
    fi

    # node_exporter 확인
    local ne_tar
    ne_tar=$(ls -t "${DOWNLOAD_DIR}/binaries/node_exporter-"*.tar.gz 2>/dev/null | head -1 || true)
    if [ -n "$ne_tar" ]; then
        print_ok "node_exporter: $(basename "$ne_tar") ($(du -h "$ne_tar" | cut -f1))"
    else
        print_warn "node_exporter를 찾을 수 없습니다"
    fi

    # mc 확인
    if [ -f "${DOWNLOAD_DIR}/binaries/mc" ]; then
        print_ok "mc 클라이언트: $(du -h "${DOWNLOAD_DIR}/binaries/mc" | cut -f1)"
    else
        print_warn "mc 클라이언트를 찾을 수 없습니다"
    fi

    echo ""
    print_info "전체 다운로드 크기: $(du -sh "$DOWNLOAD_DIR" | cut -f1)"
}

# =============================================================================
# Main
# =============================================================================
main() {
    print_step "OpenShift Virtualization POC - 폐쇄망 설치"
    echo ""
    print_info "이 스크립트는 다운로드된 파일을 폐쇄망 배포용으로 준비합니다."
    echo ""

    preflight
    load_garage_image
    copy_binaries
    verify_downloads

    echo ""
    print_step "설치 완료"
    echo ""
    print_ok "폐쇄망 환경이 준비되었습니다!"
    echo ""
    print_info "다음 단계:"
    echo "  1. env.conf 설정을 검토하세요"
    echo "  2. 실행: ./setup.sh"
    echo "  3. 실행: ./poc.sh"
    echo ""
    print_info "RHEL9 이미지 업로드:"
    echo "  cd 01-template"
    echo "  ./01-template.sh"
}

main "\$@"
INSTALL_EOF

    chmod +x "${TEMP_DIR}/00-prepare/install.sh"
    print_ok "설치 스크립트 생성됨"
}

# =============================================================================
# 패키지 README 생성
# =============================================================================
create_package_readme() {
    print_step "3/4  패키지 README 생성"

    cat > "${TEMP_DIR}/00-prepare/README-AIRGAP.md" <<'README_EOF'
# Air-gapped Installation Guide

This package contains everything needed for OpenShift Virtualization POC in an air-gapped environment.

## Package Contents

```
virt-poc/
├── 00-prepare/
│   ├── downloads/          # Downloaded files
│   │   ├── images/         # RHEL9 qcow2
│   │   ├── containers/     # Garage container tar
│   │   └── binaries/       # node_exporter, mc
│   ├── install.sh          # Air-gapped installation script
│   └── README-AIRGAP.md    # This file
├── 01-template/            # VM template lab
├── 02-network/             # Network configuration
├── ... (all other labs)
└── setup.sh                # Environment setup
```

## Prerequisites

### On Internet-connected Host (package creation)
- bash, curl, wget
- podman or docker
- Git (to clone this repository)

### On Air-gapped Bastion Host (deployment)
- OpenShift cluster access (oc login completed)
- podman (for container image management)
- Access to internal container registry (optional)

## Installation Steps

### Phase 1: Preparation (Internet-connected)

1. **Clone and download**
   ```bash
   git clone https://github.com/shiftyou/virt-poc.git
   cd virt-poc
   ```

2. **Download required files**
   ```bash
   cd 00-prepare
   ./download.sh
   ```

3. **Create package**
   ```bash
   ./package.sh
   ```
   Creates: `virt-poc-YYYYMMDD-HHMMSS.tar.gz`

4. **Transfer to air-gapped environment**
   ```bash
   # Copy the tarball to bastion host via USB/shared storage/etc
   scp virt-poc-*.tar.gz bastion:/tmp/
   ```

### Phase 2: Deployment (Air-gapped)

1. **Extract package**
   ```bash
   cd /tmp
   tar xzf virt-poc-*.tar.gz
   cd virt-poc-*/
   ```

2. **Login to OpenShift**
   ```bash
   oc login https://api.cluster.example.com:6443
   ```

3. **Run installation script**
   ```bash
   cd 00-prepare
   ./install.sh
   ```

4. **Configure environment**
   ```bash
   cd ..
   ./setup.sh
   ```
   This will detect operators and configure env.conf

5. **Run all labs**
   ```bash
   ./poc.sh
   ```
   Or run individual labs:
   ```bash
   cd 01-template
   ./01-template.sh
   ```

## Container Images

For full air-gapped deployment, you need to mirror these images to your registry:

### Garage (S3 storage)
```bash
# Load from tarball
podman load -i 00-prepare/downloads/containers/garage-v1.0.1.tar

# Tag and push to your registry
podman tag dxflrs/garage:v1.0.1 <your-registry>/garage:v1.0.1
podman push <your-registry>/garage:v1.0.1
```

Then update the Garage deployment in `14-oadp/14-oadp.md` to use your registry.

## Troubleshooting

### RHEL9 image not found
- Check: `00-prepare/downloads/images/`
- Download manually from Red Hat portal
- Place `.qcow2` file in the images directory

### Garage container load fails
- Ensure podman is installed
- Check: `00-prepare/downloads/containers/garage-*.tar`
- Manually load: `podman load -i <tar-file>`

### Binary not executable
```bash
chmod +x 00-prepare/downloads/binaries/mc
chmod +x 10-node-exporter/node_exporter
```

## Additional Notes

- All scripts are designed to work offline after installation
- No internet access required during execution
- RHEL image must be obtained separately (Red Hat subscription required)
- For iSCSI storage configuration, see lab sections

README_EOF

    print_ok "패키지 README 생성됨"
}

# =============================================================================
# tarball 생성
# =============================================================================
create_tarball() {
    print_step "4/4  배포용 tarball 생성"

    local output_file="${PROJECT_ROOT}/${PACKAGE_NAME}.tar.gz"

    print_info "tarball 생성 중: ${output_file}"
    print_info "몇 분 정도 소요될 수 있습니다..."

    cd /tmp
    tar czf "$output_file" "${PACKAGE_NAME}/"

    print_ok "tarball 생성됨: ${output_file}"

    echo ""
    print_info "패키지 상세 정보:"
    ls -lh "$output_file"
    echo ""
    print_info "패키지 내용:"
    tar tzf "$output_file" | head -20
    echo "  ... (전체 목록은 'tar tzf'를 사용하세요)"
}

# =============================================================================
# 정리
# =============================================================================
cleanup() {
    print_step "정리"

    print_info "임시 디렉토리 삭제 중: ${TEMP_DIR}"
    rm -rf "$TEMP_DIR"
    print_ok "정리 완료"
}

# =============================================================================
# Main
# =============================================================================
main() {
    print_step "OpenShift Virtualization POC - 패키징 스크립트"
    echo ""
    print_info "폐쇄망 설치를 위한 배포 패키지를 생성합니다"
    echo ""

    preflight
    copy_project
    create_install_script
    create_package_readme
    create_tarball
    cleanup

    echo ""
    print_step "패키징 완료!"
    echo ""
    print_ok "배포 패키지 준비 완료: ${PACKAGE_NAME}.tar.gz"
    echo ""
    print_info "이 파일을 폐쇄망 bastion 호스트로 전송하고 압축을 해제하세요."
    print_info "설치 방법은 00-prepare/README-AIRGAP.md를 참조하세요."
}

main "$@"
