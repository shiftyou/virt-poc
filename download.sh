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

set -euo pipefail

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

# RHEL9 image (replace with your actual download URL)
RHEL9_IMAGE_URL="${RHEL9_IMAGE_URL:-https://access.redhat.com/downloads/content/rhel}"
RHEL9_IMAGE_NAME="rhel-9.5-x86_64-kvm.qcow2"

# Garage version
GARAGE_VERSION="v1.0.1"
GARAGE_IMAGE="docker.io/dxflrs/garage:${GARAGE_VERSION}"

# Node exporter version
NODE_EXPORTER_VERSION="1.10.2"
NODE_EXPORTER_URL="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

# MC (MinIO Client) version
MC_VERSION="latest"
MC_URL="https://dl.min.io/client/mc/release/linux-amd64/mc"

# =============================================================================
# Preflight checks
# =============================================================================
preflight() {
    print_step "Pre-flight checks"

    # Check required commands
    local required_cmds=("curl" "wget" "podman")
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            print_error "Required command not found: $cmd"
            print_error "Please install: $cmd"
            exit 1
        fi
    done
    print_ok "Required commands available"

    # Create download directory
    mkdir -p "$DOWNLOAD_DIR"/{images,binaries,containers}
    print_ok "Download directory created: ${DOWNLOAD_DIR}"
}

# =============================================================================
# Download RHEL9 qcow2 image
# =============================================================================
download_rhel9() {
    print_step "1/5  Download RHEL9 qcow2 image"

    local target="${DOWNLOAD_DIR}/images/${RHEL9_IMAGE_NAME}"

    if [ -f "$target" ]; then
        print_ok "RHEL9 image already exists: ${target}"
        return
    fi

    echo ""
    print_warn "RHEL9 image download requires Red Hat subscription."
    print_info "Please download manually from: https://access.redhat.com/downloads/content/rhel"
    print_info "Download: RHEL 9.5 KVM Guest Image (rhel-9.5-x86_64-kvm.qcow2)"
    print_info "Save to: ${target}"
    echo ""
    read -r -p "Have you already downloaded the RHEL9 image? [y/N]: " confirm

    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        read -r -p "Enter the full path to RHEL9 qcow2 image: " rhel_path
        if [ -f "$rhel_path" ]; then
            cp "$rhel_path" "$target"
            print_ok "RHEL9 image copied: ${target}"
        else
            print_error "File not found: $rhel_path"
            exit 1
        fi
    else
        print_warn "Skipping RHEL9 image download (you can add it later)"
        touch "${target}.placeholder"
        cat > "${DOWNLOAD_DIR}/images/README.txt" <<EOF
Please download RHEL9 KVM Guest Image manually:

1. Go to: https://access.redhat.com/downloads/content/rhel
2. Download: RHEL 9.5 KVM Guest Image (rhel-9.5-x86_64-kvm.qcow2)
3. Place it here: ${target}
4. Re-run package.sh to create the final tarball
EOF
    fi
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

    print_info "Pulling Garage image: ${GARAGE_IMAGE}"
    podman pull "${GARAGE_IMAGE}"

    print_info "Exporting to tar: ${target}"
    podman save -o "$target" "${GARAGE_IMAGE}"

    print_ok "Garage image exported: ${target}"
    ls -lh "$target"
}

# =============================================================================
# Download node_exporter binary
# =============================================================================
download_node_exporter() {
    print_step "3/5  Download node_exporter binary"

    local target="${DOWNLOAD_DIR}/binaries/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz"

    if [ -f "$target" ]; then
        print_ok "node_exporter already exists: ${target}"
        return
    fi

    print_info "Downloading from: ${NODE_EXPORTER_URL}"
    curl -L -o "$target" "${NODE_EXPORTER_URL}"

    print_ok "node_exporter downloaded: ${target}"
    ls -lh "$target"
}

# =============================================================================
# Download mc (MinIO Client) binary
# =============================================================================
download_mc() {
    print_step "4/5  Download mc (MinIO/Garage Client) binary"

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
1. RHEL9 Image:
   - Path: images/${RHEL9_IMAGE_NAME}
   - Purpose: VM template creation (01-template)

2. Garage Container:
   - Path: containers/garage-${GARAGE_VERSION}.tar
   - Version: ${GARAGE_VERSION}
   - Purpose: S3 object storage for OADP/Logging (14-oadp, 20-logging)

3. Node Exporter:
   - Path: binaries/node_exporter-${NODE_EXPORTER_VERSION}.linux-amd64.tar.gz
   - Version: ${NODE_EXPORTER_VERSION}
   - Purpose: VM monitoring (10-node-exporter)

4. MC Client:
   - Path: binaries/mc
   - Purpose: S3/Garage bucket management

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
    download_rhel9
    download_garage
    download_node_exporter
    download_mc
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
