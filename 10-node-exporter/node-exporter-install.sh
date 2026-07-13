#!/bin/bash

# Set the version from an environment variable, or default to 1.10.2
VERSION=${VERSION:-"1.10.2"}
BINARY_NAME="node_exporter-${VERSION}.linux-amd64.tar.gz"
DOWNLOAD_URL="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/${BINARY_NAME}"

echo "Starting installation of node_exporter version: ${VERSION}"

# 1. Download the node_exporter binary
echo "Downloading $DOWNLOAD_URL..."
wget -q $DOWNLOAD_URL
if [ $? -ne 0 ]; then
    echo "Error: Failed to download the file. Please check the version: $VERSION"
    exit 1
fi

# 2. Extract the binary and move it to /usr/bin
# --strip 1 is used to extract the file directly without the parent folder
echo "Extracting binary to /usr/bin..."
sudo tar xvf $BINARY_NAME --directory /usr/bin --strip 1 '*/node_exporter'

# 3. Create a system user for node_exporter (if it doesn't exist)
if ! id "node_exporter" &>/dev/null; then
    echo "Creating system user: node_exporter"
    sudo useradd --system --no-create-home --shell /sbin/nologin node_exporter
fi

# 4. Set ownership and permissions
sudo chown node_exporter:node_exporter /usr/bin/node_exporter

# 5. Create Systemd Service File
echo "Creating systemd service file..."
sudo bash -c "cat <<EOF > /etc/systemd/system/node_exporter.service
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/bin/node_exporter

[Install]
WantedBy=default.target
EOF"

# 6. Reload systemd, enable and start the service
echo "Reloading systemd and starting service..."
sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter

# 7. Final Check
echo "--------------------------------------------------------"
echo "Installation complete. Checking service status..."
sudo systemctl status node_exporter --no-pager
echo "--------------------------------------------------------"
echo "Metrics available at: http://localhost:9100/metrics"

# Cleanup
rm -f $BINARY_NAME
