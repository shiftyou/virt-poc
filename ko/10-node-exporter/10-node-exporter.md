# Node Exporter 실습

VM(Linux) 내부에 node_exporter를 직접 설치하고 OpenShift에 Service를 등록하여 해당 메트릭을 수집하는 과정을 설명합니다.

---

## 구성 개요

```
VM (Linux)                          OpenShift
┌─────────────────────┐             ┌──────────────────────────────┐
│  node_exporter      │             │  Namespace: poc-node-exporter         │
│  (systemd service)  │◄────────────│                              │
│  :9100/metrics      │             │  Service: node-exporter-service│
└─────────────────────┘             │  selector: monitor: metrics  │
                                    └──────────────────────────────┘
```

- node_exporter는 **binary + systemd** 방식으로 VM 내부에 설치됩니다.
- 최신 릴리스: https://github.com/prometheus/node_exporter/releases
- VM Pod를 가리키는 **ClusterIP Service**가 OpenShift에 등록됩니다.

---

## 1. VM에 node_exporter 설치

SSH를 통해 VM(또는 Bare-metal 호스트)에 접속한 후 `node-exporter-install.sh`를 실행합니다.

```bash
# 기본 버전(1.10.2)으로 설치
bash node-exporter-install.sh

# 특정 버전 지정
VERSION=1.10.2 bash node-exporter-install.sh
```

### node-exporter-install.sh

```bash
#!/bin/bash

# 환경 변수에서 버전을 설정하거나, 기본값 1.10.2 사용
VERSION=${VERSION:-"1.10.2"}
BINARY_NAME="node_exporter-${VERSION}.linux-amd64.tar.gz"
DOWNLOAD_URL="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/${BINARY_NAME}"

echo "Starting installation of node_exporter version: ${VERSION}"

# 1. node_exporter 바이너리 다운로드
echo "Downloading $DOWNLOAD_URL..."
wget -q $DOWNLOAD_URL
if [ $? -ne 0 ]; then
    echo "Error: Failed to download the file. Please check the version: $VERSION"
    exit 1
fi

# 2. 바이너리 압축 해제 후 /usr/bin으로 이동
# --strip 1은 상위 폴더 없이 파일을 직접 추출하기 위해 사용
echo "Extracting binary to /usr/bin..."
sudo tar xvf $BINARY_NAME --directory /usr/bin --strip 1 '*/node_exporter'

# 3. node_exporter 전용 시스템 사용자 생성 (존재하지 않는 경우)
if ! id "node_exporter" &>/dev/null; then
    echo "Creating system user: node_exporter"
    sudo useradd --system --no-create-home --shell /sbin/nologin node_exporter
fi

# 4. 소유권 및 권한 설정
sudo chown node_exporter:node_exporter /usr/bin/node_exporter

# 5. Systemd Service 파일 생성
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

# 6. systemd 리로드, 서비스 활성화 및 시작
echo "Reloading systemd and starting service..."
sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter

# 7. 최종 확인
echo "--------------------------------------------------------"
echo "Installation complete. Checking service status..."
sudo systemctl status node_exporter --no-pager
echo "--------------------------------------------------------"
echo "Metrics available at: http://localhost:9100/metrics"

# 정리
rm -f $BINARY_NAME
```

### 설치 요약

| 단계 | 내용 |
|------|------|
| 1 | GitHub Releases에서 바이너리 다운로드 |
| 2 | `/usr/bin/node_exporter`로 압축 해제 |
| 3 | 전용 시스템 사용자 `node_exporter` 생성 |
| 4 | 파일 소유권 설정 |
| 5 | systemd service 파일 생성 (`/etc/systemd/system/node_exporter.service`) |
| 6 | 서비스 활성화 및 시작 (`systemctl enable --now`) |

### 설치 검증

```bash
# 서비스 상태 확인
systemctl status node_exporter

# 메트릭 수집 확인
curl http://localhost:9100/metrics | head -20

# 주요 메트릭 확인
curl -s http://localhost:9100/metrics | grep -E '^node_(cpu|memory|filesystem|load)'
```

---

## 2. OpenShift Service 등록

node_exporter가 설치된 VM Pod에 `monitor: metrics` label이 있어야 합니다.

```bash
# VM Pod의 label 확인
oc get pods -n poc-node-exporter --show-labels | grep monitor

# label이 없는 경우 추가
oc label pod <pod-name> -n poc-node-exporter monitor=metrics
```

Service를 적용합니다.

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

### Service 검증

```bash
# Service 상태
oc get svc node-exporter-service -n poc-node-exporter

# Endpoints 확인 (VM Pod IP:9100이 등록되어 있어야 함)
oc get endpoints node-exporter-service -n poc-node-exporter
```

> **네트워크 참고사항**
> poc template은 기본적으로 **masquerade (NAT) networking**을 사용합니다.
> 이 경우 virt-launcher Pod IP로 도착하는 9100 포트 트래픽이 VM 내부의 node_exporter에 도달하지 않습니다.
> Prometheus scraping이 정상적으로 동작하려면 **VM에 bridge network (NAD)를 추가하고 해당 IP로 Service를 구성**하거나,
> VM 내부에서 직접 메트릭을 확인해야 합니다.

---

## 3. ServiceMonitor 등록 (Prometheus scrape)

Service만으로는 Prometheus가 자동으로 수집하지 않습니다. **ServiceMonitor**를 등록해야 합니다.

```bash
# user-workload-monitoring 활성화 확인
oc get configmap cluster-monitoring-config -n openshift-monitoring -o yaml | grep enableUserWorkload

# namespace에 monitoring label 설정
oc label namespace poc-node-exporter openshift.io/cluster-monitoring=true

# ServiceMonitor 적용
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

### ServiceMonitor 검증

```bash
# ServiceMonitor 등록 확인
oc get servicemonitor -n poc-node-exporter

# Prometheus가 scrape 대상으로 인식하는지 확인
oc get pods -n openshift-user-workload-monitoring
```

---

## 4. PromQL로 메트릭 확인

OpenShift Console → **Observe → Metrics**에서 아래 쿼리를 입력합니다.

ServiceMonitor의 `relabelings` 설정으로 모든 메트릭에 `job="vm-node-exporter"` label이 추가됩니다.

### CPU

```promql
# CPU 사용률 (%)
100 - (avg by(instance) (rate(node_cpu_seconds_total{job="vm-node-exporter", mode="idle"}[5m])) * 100)

# 모드별 CPU 사용 시간
rate(node_cpu_seconds_total{job="vm-node-exporter"}[5m])
```

### 메모리

```promql
# 가용 메모리 (bytes)
node_memory_MemAvailable_bytes{job="vm-node-exporter"}

# 메모리 사용률 (%)
(1 - node_memory_MemAvailable_bytes{job="vm-node-exporter"} / node_memory_MemTotal_bytes{job="vm-node-exporter"}) * 100
```

### 디스크

```promql
# 파일시스템 여유 공간 (bytes)
node_filesystem_avail_bytes{job="vm-node-exporter", mountpoint="/"}

# 디스크 사용률 (%)
(1 - node_filesystem_avail_bytes{job="vm-node-exporter", mountpoint="/"} / node_filesystem_size_bytes{job="vm-node-exporter", mountpoint="/"}) * 100
```

### Load Average

```promql
node_load1{job="vm-node-exporter"}
node_load5{job="vm-node-exporter"}
node_load15{job="vm-node-exporter"}
```

### 네트워크

```promql
# 수신 속도 (bytes/s)
rate(node_network_receive_bytes_total{job="vm-node-exporter"}[5m])

# 송신 속도 (bytes/s)
rate(node_network_transmit_bytes_total{job="vm-node-exporter"}[5m])
```

---

## 5. 메트릭 직접 확인 (port-forward)

```bash
# Service를 통한 메트릭 접근 (port-forward)
oc port-forward svc/node-exporter-service 9100:9100 -n poc-node-exporter &

curl http://localhost:9100/metrics | grep node_memory_MemAvailable_bytes
```

---

## 문제 해결

```bash
# node_exporter 서비스 재시작 (VM 내부)
sudo systemctl restart node_exporter
sudo journalctl -u node_exporter -f

# 방화벽 확인 (VM 내부, 9100 포트 허용 확인)
sudo firewall-cmd --list-ports
sudo firewall-cmd --add-port=9100/tcp --permanent && sudo firewall-cmd --reload

# Endpoints가 비어 있는 경우 → Pod label 확인
oc describe svc node-exporter-service -n poc-node-exporter
oc get pods -n poc-node-exporter --show-labels
```

---

## 롤백

```bash
# OpenShift Service 삭제
oc delete -f node-exporter-service.yaml

# VM 내부 node_exporter 제거
sudo systemctl disable --now node_exporter
sudo rm /etc/systemd/system/node_exporter.service
sudo rm /usr/bin/node_exporter
sudo userdel node_exporter
sudo systemctl daemon-reload
```
