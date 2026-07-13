#!/bin/bash
# =============================================================================
# package.sh
#
# Package entire virt-poc with downloaded files for air-gapped transfer
#
# Creates: virt-poc-<date>.tar.gz
#
# Usage: ./package.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PACKAGE_NAME="virt-poc-$(date +%Y%m%d-%H%M%S)"
TEMP_DIR="/tmp/${PACKAGE_NAME}"

source "${SCRIPT_DIR}/../utils/common.sh"

# =============================================================================
# Preflight checks
# =============================================================================
preflight() {
    print_step "Pre-flight checks"

    if [ ! -d "${SCRIPT_DIR}/downloads" ]; then
        print_error "downloads directory not found."
        print_error "Please run ./download.sh first."
        exit 1
    fi

    print_ok "Downloads directory found"
}

# =============================================================================
# Copy project files
# =============================================================================
copy_project() {
    print_step "1/4  Copy project files"

    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"

    print_info "Copying project files to: ${TEMP_DIR}"

    # Copy all project files excluding .git and temporary files
    rsync -av \
        --exclude='.git' \
        --exclude='.gitignore' \
        --exclude='.claude' \
        --exclude='*.log' \
        --exclude='*.tmp' \
        --exclude='node_modules' \
        --exclude='__pycache__' \
        "${PROJECT_ROOT}/" "${TEMP_DIR}/"

    print_ok "Project files copied"
}

# =============================================================================
# Create installation script
# =============================================================================
create_install_script() {
    print_step "2/4  Create installation script"

    cat > "${TEMP_DIR}/00-prepare/install.sh" <<'INSTALL_EOF'
#!/bin/bash
# =============================================================================
# install.sh
#
# Air-gapped installation script for OpenShift Virtualization POC
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
# Preflight checks
# =============================================================================
preflight() {
    print_step "Pre-flight checks"

    if ! oc whoami &>/dev/null; then
        print_error "Not logged in to OpenShift cluster."
        print_error "Please login first: oc login <cluster-api>"
        exit 1
    fi
    print_ok "Connected to cluster: $(oc whoami --show-server)"

    if ! command -v podman &>/dev/null; then
        print_error "podman command not found."
        print_error "Please install podman."
        exit 1
    fi
    print_ok "podman available"
}

# =============================================================================
# Load Garage container image
# =============================================================================
load_garage_image() {
    print_step "1/3  Load Garage container image"

    local garage_tar
    garage_tar=$(ls -t "${DOWNLOAD_DIR}/containers/garage-"*.tar 2>/dev/null | head -1 || true)

    if [ -z "$garage_tar" ]; then
        print_warn "Garage container image not found in downloads"
        print_warn "You'll need to pull it manually or mirror to your registry"
        return
    fi

    print_info "Loading Garage image from: ${garage_tar}"
    podman load -i "$garage_tar"
    print_ok "Garage image loaded into local podman"

    echo ""
    print_info "To push to your registry:"
    echo "  podman tag <image-id> <your-registry>/garage:v1.0.1"
    echo "  podman push <your-registry>/garage:v1.0.1"
}

# =============================================================================
# Copy binaries
# =============================================================================
copy_binaries() {
    print_step "2/3  Copy binaries to project"

    # Copy node_exporter
    local node_exporter_tar
    node_exporter_tar=$(ls -t "${DOWNLOAD_DIR}/binaries/node_exporter-"*.tar.gz 2>/dev/null | head -1 || true)
    if [ -n "$node_exporter_tar" ]; then
        cp "$node_exporter_tar" "${PROJECT_ROOT}/10-node-exporter/"
        print_ok "node_exporter copied to 10-node-exporter/"
    fi

    # Copy mc client
    if [ -f "${DOWNLOAD_DIR}/binaries/mc" ]; then
        cp "${DOWNLOAD_DIR}/binaries/mc" "${PROJECT_ROOT}/14-oadp/"
        chmod +x "${PROJECT_ROOT}/14-oadp/mc"
        print_ok "mc client copied to 14-oadp/"
    fi
}

# =============================================================================
# Verify downloads
# =============================================================================
verify_downloads() {
    print_step "3/3  Verify downloaded files"

    echo ""
    print_info "Download verification:"

    # Check RHEL9 image
    local rhel_img
    rhel_img=$(ls -t "${DOWNLOAD_DIR}/images/rhel-"*.qcow2 2>/dev/null | head -1 || true)
    if [ -n "$rhel_img" ]; then
        print_ok "RHEL9 image: $(basename "$rhel_img") ($(du -h "$rhel_img" | cut -f1))"
    else
        print_warn "RHEL9 image not found - please download manually"
        print_warn "  See: ${DOWNLOAD_DIR}/images/README.txt"
    fi

    # Check Garage
    local garage_tar
    garage_tar=$(ls -t "${DOWNLOAD_DIR}/containers/garage-"*.tar 2>/dev/null | head -1 || true)
    if [ -n "$garage_tar" ]; then
        print_ok "Garage image: $(basename "$garage_tar") ($(du -h "$garage_tar" | cut -f1))"
    else
        print_warn "Garage image not found"
    fi

    # Check node_exporter
    local ne_tar
    ne_tar=$(ls -t "${DOWNLOAD_DIR}/binaries/node_exporter-"*.tar.gz 2>/dev/null | head -1 || true)
    if [ -n "$ne_tar" ]; then
        print_ok "node_exporter: $(basename "$ne_tar") ($(du -h "$ne_tar" | cut -f1))"
    else
        print_warn "node_exporter not found"
    fi

    # Check mc
    if [ -f "${DOWNLOAD_DIR}/binaries/mc" ]; then
        print_ok "mc client: $(du -h "${DOWNLOAD_DIR}/binaries/mc" | cut -f1)"
    else
        print_warn "mc client not found"
    fi

    echo ""
    print_info "Total downloaded size: $(du -sh "$DOWNLOAD_DIR" | cut -f1)"
}

# =============================================================================
# Main
# =============================================================================
main() {
    print_step "OpenShift Virtualization POC - Air-gapped Installation"
    echo ""
    print_info "This script prepares downloaded files for air-gapped deployment."
    echo ""

    preflight
    load_garage_image
    copy_binaries
    verify_downloads

    echo ""
    print_step "Installation Complete"
    echo ""
    print_ok "Air-gapped environment is ready!"
    echo ""
    print_info "Next steps:"
    echo "  1. Review env.conf settings"
    echo "  2. Run: ./setup.sh"
    echo "  3. Run: ./make.sh"
    echo ""
    print_info "For RHEL9 image upload:"
    echo "  cd 01-template"
    echo "  ./01-template.sh"
}

main "\$@"
INSTALL_EOF

    chmod +x "${TEMP_DIR}/00-prepare/install.sh"
    print_ok "Installation script created"
}

# =============================================================================
# Create README for the package
# =============================================================================
create_package_readme() {
    print_step "3/4  Create package README"

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
   ./make.sh
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

    print_ok "Package README created"
}

# =============================================================================
# Create tarball
# =============================================================================
create_tarball() {
    print_step "4/4  Create distribution tarball"

    local output_file="${PROJECT_ROOT}/${PACKAGE_NAME}.tar.gz"

    print_info "Creating tarball: ${output_file}"
    print_info "This may take several minutes..."

    cd /tmp
    tar czf "$output_file" "${PACKAGE_NAME}/"

    print_ok "Tarball created: ${output_file}"

    echo ""
    print_info "Package details:"
    ls -lh "$output_file"
    echo ""
    print_info "Package contents:"
    tar tzf "$output_file" | head -20
    echo "  ... (use 'tar tzf' to see full list)"
}

# =============================================================================
# Cleanup
# =============================================================================
cleanup() {
    print_step "Cleanup"

    print_info "Removing temporary directory: ${TEMP_DIR}"
    rm -rf "$TEMP_DIR"
    print_ok "Cleanup complete"
}

# =============================================================================
# Main
# =============================================================================
main() {
    print_step "OpenShift Virtualization POC - Package Script"
    echo ""
    print_info "Creating distribution package for air-gapped installation"
    echo ""

    preflight
    copy_project
    create_install_script
    create_package_readme
    create_tarball
    cleanup

    echo ""
    print_step "Packaging Complete!"
    echo ""
    print_ok "Distribution package ready: ${PACKAGE_NAME}.tar.gz"
    echo ""
    print_info "Transfer this file to your air-gapped bastion host and extract it."
    print_info "See 00-prepare/README-AIRGAP.md for installation instructions."
}

main "$@"
