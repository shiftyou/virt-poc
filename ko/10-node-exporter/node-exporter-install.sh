#!/bin/bash

# 환경 변수에서 버전을 설정하거나, 기본값 1.10.2 사용
VERSION=${VERSION:-"1.10.2"}
BINARY_NAME="node_exporter-${VERSION}.linux-amd64.tar.gz"
DOWNLOAD_URL="https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/${BINARY_NAME}"

echo "node_exporter 버전 ${VERSION} 설치를 시작합니다"

# 1. node_exporter 바이너리 다운로드
echo "$DOWNLOAD_URL 다운로드 중..."
wget -q $DOWNLOAD_URL
if [ $? -ne 0 ]; then
    echo "오류: 파일 다운로드에 실패했습니다. 버전을 확인하세요: $VERSION"
    exit 1
fi

# 2. 바이너리 추출 및 /usr/bin으로 이동
# --strip 1은 상위 폴더 없이 파일을 직접 추출하기 위해 사용
echo "바이너리를 /usr/bin으로 추출 중..."
sudo tar xvf $BINARY_NAME --directory /usr/bin --strip 1 '*/node_exporter'

# 3. node_exporter용 시스템 사용자 생성 (존재하지 않는 경우)
if ! id "node_exporter" &>/dev/null; then
    echo "시스템 사용자 생성: node_exporter"
    sudo useradd --system --no-create-home --shell /sbin/nologin node_exporter
fi

# 4. 소유권 및 권한 설정
sudo chown node_exporter:node_exporter /usr/bin/node_exporter

# 5. Systemd Service 파일 생성
echo "systemd service 파일 생성 중..."
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

# 6. systemd 재로드, 서비스 활성화 및 시작
echo "systemd 재로드 및 서비스 시작 중..."
sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter

# 7. 최종 확인
echo "--------------------------------------------------------"
echo "설치 완료. 서비스 상태 확인 중..."
sudo systemctl status node_exporter --no-pager
echo "--------------------------------------------------------"
echo "메트릭 확인 주소: http://localhost:9100/metrics"

# 정리
rm -f $BINARY_NAME
