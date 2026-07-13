# Node Exporter Practice

Explains the process of directly installing node_exporter inside a VM (Linux) and registering a Service in OpenShift to collect those metrics.

---

## Configuration Overview

```
VM (Linux)                          OpenShift
┌─────────────────────┐             ┌──────────────────────────────┐
│  node_exporter      │             │  Namespace: poc-node-exporter         │
│  (systemd service)  │◄────────────│                              │
│  :9100/metrics      │             │  Service: node-exporter-service│
└─────────────────────┘             │  selector: monitor: metrics  │
                                    └──────────────────────────────┘
```

- node_exporter is installed inside the VM using the **binary + systemd** method.
- Latest release: https://github.com/prometheus/node_exporter/releases
- A **ClusterIP Service** pointing to the VM Pod is registered in OpenShift.

---

## 1. Install node_exporter on VM

Connect to the VM (or Bare-metal host) via SSH and run `node-exporter-install.sh`.

```bash
# Install with default version (1.10.2)
bash node-exporter-install.sh

# Specify a particular version
VERSION=1.10.2 bash node-exporter-install.sh
```

### node-exporter-install.sh

```bash
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
```

### Installation Summary

| Step | Content |
|------|---------|
| 1 | Download binary from GitHub Releases |
| 2 | Extract to `/usr/bin/node_exporter` |
| 3 | Create dedicated system user `node_exporter` |
| 4 | Set file ownership |
| 5 | Create systemd service file (`/etc/systemd/system/node_exporter.service`) |
| 6 | Enable and start service (`systemctl enable --now`) |

### Verify Installation

```bash
# Check service status
systemctl status node_exporter

# Verify metrics collection
curl http://localhost:9100/metrics | head -20

# Check key metrics
curl -s http://localhost:9100/metrics | grep -E '^node_(cpu|memory|filesystem|load)'
```

---

## 2. Register OpenShift Service

The VM Pod where node_exporter is installed must have the label `monitor: metrics`.

```bash
# Check label on VM Pod
oc get pods -n poc-node-exporter --show-labels | grep monitor

# Add label if missing
oc label pod <pod-name> -n poc-node-exporter monitor=metrics
```

Apply the Service.

```bash
oc apply -f node-exporter-service.yaml
```

### node-exporter-service.yaml

```yaml
kind: Service
apiVersion: v1
metadata:
  name: node-exporter-service
  namespace: poc-node-exporter
  labels:
    servicetype: metrics
spec:
  ipFamilies:
    - IPv4
  ports:
    - name: metric
      protocol: TCP
      port: 9100
      targetPort: 9100
  internalTrafficPolicy: Cluster
  type: ClusterIP
  ipFamilyPolicy: SingleStack
  sessionAffinity: None
  selector:
    monitor: metrics
```

### Verify Service

```bash
# Service status
oc get svc node-exporter-service -n poc-node-exporter

# Check Endpoints (VM Pod IP:9100 must be registered)
oc get endpoints node-exporter-service -n poc-node-exporter
```

> **⚠️ Network note**
> The poc template uses **masquerade (NAT) networking** by default.
> In this case, port 9100 traffic arriving at the virt-launcher Pod IP will not reach the node_exporter inside the VM.
> For Prometheus scraping to work properly, either **add a bridge network (NAD) to the VM and configure the Service with that IP**,
> or verify metrics directly inside the VM.

---

## 3. Register ServiceMonitor (Prometheus scrape)

A Service alone does not cause Prometheus to automatically collect. A **ServiceMonitor** must be registered.

```bash
# Verify user-workload-monitoring is enabled
oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml | grep enableUserWorkload

# Set monitoring label on namespace
oc label namespace poc-node-exporter openshift.io/cluster-monitoring=true

# Apply ServiceMonitor
oc apply -f servicemonitor-node-exporter.yaml
```

### servicemonitor-node-exporter.yaml

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: node-exporter-monitor
  namespace: poc-node-exporter
  labels:
    servicetype: metrics
spec:
  selector:
    matchLabels:
      servicetype: metrics
  endpoints:
    - port: metric
      interval: 30s
      path: /metrics
      relabelings:
        - targetLabel: job
          replacement: vm_prometheus-metric
        - sourceLabels: [__meta_kubernetes_endpoint_hostname]
          targetLabel: vmname
        - sourceLabels: [__address__]
          targetLabel: instance
```

### Verify ServiceMonitor

```bash
# Verify ServiceMonitor registration
oc get servicemonitor -n poc-node-exporter

# Verify Prometheus recognizes it as a scrape target
oc get pods -n openshift-user-workload-monitoring
```

---

## 4. Check Metrics via PromQL

Enter the queries below in OpenShift Console → **Observe → Metrics**.

The `relabelings` configuration in ServiceMonitor adds the label `job="vm-node-exporter"` to all metrics.

### CPU

```promql
# CPU utilization (%)
100 - (avg by(instance) (rate(node_cpu_seconds_total{job="vm-node-exporter", mode="idle"}[5m])) * 100)

# CPU usage time by mode
rate(node_cpu_seconds_total{job="vm-node-exporter"}[5m])
```

### Memory

```promql
# Available memory (bytes)
node_memory_MemAvailable_bytes{job="vm-node-exporter"}

# Memory utilization (%)
(1 - node_memory_MemAvailable_bytes{job="vm-node-exporter"} / node_memory_MemTotal_bytes{job="vm-node-exporter"}) * 100
```

### Disk

```promql
# Filesystem free space (bytes)
node_filesystem_avail_bytes{job="vm-node-exporter", mountpoint="/"}

# Disk utilization (%)
(1 - node_filesystem_avail_bytes{job="vm-node-exporter", mountpoint="/"} / node_filesystem_size_bytes{job="vm-node-exporter", mountpoint="/"}) * 100
```

### Load Average

```promql
node_load1{job="vm-node-exporter"}
node_load5{job="vm-node-exporter"}
node_load15{job="vm-node-exporter"}
```

### Network

```promql
# Receive speed (bytes/s)
rate(node_network_receive_bytes_total{job="vm-node-exporter"}[5m])

# Transmit speed (bytes/s)
rate(node_network_transmit_bytes_total{job="vm-node-exporter"}[5m])
```

---

## 5. Check Metrics Directly (port-forward)

```bash
# Access metrics via Service (port-forward)
oc port-forward svc/node-exporter-service 9100:9100 -n poc-node-exporter &

curl http://localhost:9100/metrics | grep node_memory_MemAvailable_bytes
```

---

## Troubleshooting

```bash
# Restart node_exporter service (inside VM)
sudo systemctl restart node_exporter
sudo journalctl -u node_exporter -f

# Check firewall (inside VM, verify port 9100 is allowed)
sudo firewall-cmd --list-ports
sudo firewall-cmd --add-port=9100/tcp --permanent && sudo firewall-cmd --reload

# If Endpoints are empty → Check Pod labels
oc describe svc node-exporter-service -n poc-node-exporter
oc get pods -n poc-node-exporter --show-labels
```

---

## Rollback

```bash
# Delete OpenShift Service
oc delete -f node-exporter-service.yaml

# Remove node_exporter inside VM
sudo systemctl disable --now node_exporter
sudo rm /etc/systemd/system/node_exporter.service
sudo rm /usr/bin/node_exporter
sudo userdel node_exporter
sudo systemctl daemon-reload
```
