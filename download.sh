#!/bin/bash
# =============================================================================
# download.sh
#
# Download all required files for air-gapped OpenShift Virtualization POC
#
# This script downloads:
#   - RHEL9 qcow2 image
#   - Garage container image (exported as tar)
#   - Node exporter binary
#   - MC client binary (for S3 testing)
#   - Sample VM disk images (optional)
#
# Usage: ./download.sh
# =============================================================================

set -xeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# Configuration
# =============================================================================

# Golden image
GOLDEN_IMAGE_URL="${GOLDEN_IMAGE_URL:-http://146.56.160.95/poc-golden.qcow2}"
GOLDEN_IMAGE_NAME="poc-golden.qcow2"

# Garage container image
GARAGE_VERSION="v1.0.1"
GARAGE_IMAGE="docker.io/dxflrs/garage:${GARAGE_VERSION}"

# MC (MinIO Client) version
MC_VERSION="latest"
MC_URL="https://dl.min.io/client/mc/release/linux-amd64/mc"

# VMware VDDK
VDDK_URL="${VDDK_URL:-http://146.56.160.95/VMware-vix-disklib-8.0.3-23950268.x86_64.tar.gz}"
VDDK_NAME="VMware-vix-disklib-8.0.3-23950268.x86_64.tar.gz"

# =============================================================================
# Preflight checks
# =============================================================================
preflight() {
    print_step "Pre-flight checks"

    # Check required commands
    local required_cmds=("curl")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            print_error "Required command not found: $cmd"
            print_error "Please install: $cmd"
            exit 1
        fi
    done
    print_ok "Required commands available"

    CONTAINER_CMD=""
    if command -v podman &>/dev/null; then
        CONTAINER_CMD="podman"
    elif command -v docker &>/dev/null; then
        CONTAINER_CMD="docker"
    fi

    if [ -n "$CONTAINER_CMD" ]; then
        print_ok "Container runtime: $CONTAINER_CMD"
    else
        print_warn "No container runtime (podman/docker) — Garage image export will be skipped"
    fi

    # Create download directory
    mkdir -p "$DOWNLOAD_DIR"/{images,binaries,containers}
    print_ok "Download directory created: ${DOWNLOAD_DIR}"
}

# =============================================================================
# Download golden qcow2 image
# =============================================================================
download_golden() {
    print_step "1/5  Download golden qcow2 image"

    local target="${DOWNLOAD_DIR}/images/${GOLDEN_IMAGE_NAME}"

    if [ -f "$target" ]; then
        print_ok "Golden image already exists: ${target}"
        return
    fi

    print_info "Downloading from: ${GOLDEN_IMAGE_URL}"
    curl -L -o "$target" "${GOLDEN_IMAGE_URL}"

    print_ok "Golden image downloaded: ${target}"
    ls -lh "$target"
}

# =============================================================================
# Export Garage container image
# =============================================================================
download_garage() {
    print_step "2/5  Export Garage container image"

    local target="${DOWNLOAD_DIR}/containers/garage-${GARAGE_VERSION}.tar"

    if [ -f "$target" ]; then
        print_ok "Garage image already exported: ${target}"
        return
    fi

    if [ -z "$CONTAINER_CMD" ]; then
        print_warn "Skipping Garage export (podman/docker not available)"
        return
    fi

    print_info "Pulling Garage image: ${GARAGE_IMAGE} (via $CONTAINER_CMD)"
    $CONTAINER_CMD pull "${GARAGE_IMAGE}"

    print_info "Exporting to tar: ${target}"
    $CONTAINER_CMD save -o "$target" "${GARAGE_IMAGE}"

    print_ok "Garage image exported: ${target}"
    ls -lh "$target"
}

# =============================================================================
# Download mc (MinIO Client) binary
# =============================================================================
download_mc() {
    print_step "3/5  Download mc (MinIO/Garage Client) binary"

    local target="${DOWNLOAD_DIR}/binaries/mc"

    if [ -f "$target" ]; then
        print_ok "mc binary already exists: ${target}"
        return
    fi

    print_info "Downloading from: ${MC_URL}"
    curl -L -o "$target" "${MC_URL}"
    chmod +x "$target"

    print_ok "mc binary downloaded: ${target}"
    ls -lh "$target"
}

# =============================================================================
# Download VMware VDDK
# =============================================================================
download_vddk() {
    print_step "4/5  Download VMware VDDK"

    local target="${DOWNLOAD_DIR}/binaries/${VDDK_NAME}"

    if [ -f "$target" ]; then
        print_ok "VDDK already exists: ${target}"
        return
    fi

    print_info "Downloading from: ${VDDK_URL}"
    curl -L -o "$target" "${VDDK_URL}"

    print_ok "VDDK downloaded: ${target}"
    ls -lh "$target"
}

# =============================================================================
# Create metadata file
# =============================================================================
create_metadata() {
    print_step "5/5  Create metadata file"

    cat > "${DOWNLOAD_DIR}/METADATA.txt" <<EOF
OpenShift Virtualization POC - Downloaded Files
================================================

Download Date: $(date '+%Y-%m-%d %H:%M:%S')
Script Version: 1.0

Files:
------
1. Golden Image:
   - Path: images/${GOLDEN_IMAGE_NAME}
   - Purpose: VM template creation (01-template)

2. Garage Container:
   - Path: containers/garage-${GARAGE_VERSION}.tar
   - Version: ${GARAGE_VERSION}
   - Purpose: S3 object storage for OADP/Logging (14-oadp, 20-logging)

3. MC Client:
   - Path: binaries/mc
   - Purpose: S3/Garage bucket management

4. VMware VDDK:
   - Path: binaries/${VDDK_NAME}
   - Purpose: VMware migration (13-mtv)

Installation:
-------------
1. Extract this package on the bastion host
2. Run: ./install.sh
3. Follow the setup guide

For air-gapped installation:
- All container images should be mirrored to your registry
- RHEL9 image will be uploaded via virtctl
- Binaries will be copied to target VMs/nodes

EOF

    print_ok "Metadata file created: ${DOWNLOAD_DIR}/METADATA.txt"
    cat "${DOWNLOAD_DIR}/METADATA.txt"
}

# =============================================================================
# Main
# =============================================================================
main() {
    print_step "OpenShift Virtualization POC - Download Script"
    echo ""
    print_info "This script downloads required files for air-gapped installation."
    print_info "Target directory: ${DOWNLOAD_DIR}"
    echo ""

    preflight
    download_golden
    download_garage
    download_mc
    download_vddk
    create_metadata

    echo ""
    print_step "Download Summary"
    echo ""
    print_ok "All downloads completed!"
    print_info "Downloaded to: ${DOWNLOAD_DIR}"
    echo ""
    print_info "Total size:"
    du -sh "$DOWNLOAD_DIR"
    echo ""
    print_info "Next step: Run ./package.sh to create distribution tarball"
}

main "$@"
