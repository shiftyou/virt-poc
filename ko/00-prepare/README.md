# Air-gapped 준비 가이드

OpenShift Virtualization POC를 Air-gapped 환경에서 실행하기 위한 준비 가이드입니다.

## 스크립트

| 스크립트 | 용도 |
|----------|------|
| `download.sh` | 인터넷 연결 환경에서 필요한 파일 다운로드 |
| `package.sh` | 전체 프로젝트와 다운로드 파일을 tarball로 패키징 |
| `install.sh` | Air-gapped 환경에서 패키지 설치 (자동 생성됨) |

## 1단계: 인터넷 연결 환경

### 1. 프로젝트 클론

```bash
git clone https://github.com/shiftyou/virt-poc.git
cd virt-poc/00-prepare
```

### 2. 필요한 파일 다운로드

```bash
./download.sh
```

다운로드되는 파일:
- **RHEL9 qcow2 이미지** - VM 템플릿용 (수동 다운로드 필요)
- **Garage 컨테이너** - S3 스토리지 (podman export)
- **node_exporter 바이너리** - 모니터링
- **mc 클라이언트** - S3/Garage 관리 도구

### 3. 패키지 생성

```bash
./package.sh
```

생성되는 파일: `virt-poc-YYYYMMDD-HHMMSS.tar.gz`

### 4. Air-gapped 환경으로 전송

```bash
# USB, 공유 스토리지, 또는 파일 전송 서비스 사용
scp virt-poc-*.tar.gz bastion.airgap.local:/tmp/
```

## 2단계: Air-gapped 환경

### 1. 패키지 추출

```bash
cd /tmp
tar xzf virt-poc-*.tar.gz
cd virt-poc-*/
```

### 2. OpenShift 로그인

```bash
oc login https://api.cluster.example.com:6443
```

### 3. 설치 스크립트 실행

```bash
cd 00-prepare
./install.sh
```

이 스크립트는:
- Garage 컨테이너 이미지 로드 (podman)
- 바이너리 파일 복사 (node_exporter, mc)
- 다운로드 파일 검증

### 4. 환경 설정

```bash
cd ..
./setup.sh
```

### 5. 전체 Lab 실행

```bash
./poc.sh
```

또는 개별 Lab 실행:
```bash
cd 01-template
./01-template.sh
```

## 다운로드 디렉토리 구조

```
downloads/
├── images/
│   ├── rhel-9.5-x86_64-kvm.qcow2
│   └── README.txt (RHEL 다운로드 가이드)
├── containers/
│   └── garage-v1.0.1.tar
├── binaries/
│   ├── node_exporter-1.10.2.linux-amd64.tar.gz
│   └── mc
└── METADATA.txt
```

## 컨테이너 레지스트리 설정 (선택 사항)

Air-gapped 환경에서 내부 레지스트리 사용 시:

### Garage 이미지 미러링

```bash
# 1. 로컬 podman에 로드
podman load -i downloads/containers/garage-v1.0.1.tar

# 2. 내부 레지스트리로 태그
podman tag dxflrs/garage:v1.0.1 registry.internal:5000/garage:v1.0.1

# 3. Push
podman push registry.internal:5000/garage:v1.0.1
```

### Deployment 수정

`14-oadp/14-oadp.md`의 Garage deployment에서 이미지 경로 변경:
```yaml
image: registry.internal:5000/garage:v1.0.1
```

## RHEL9 이미지 수동 다운로드

RHEL9 이미지는 Red Hat 구독이 필요하므로 수동으로 다운로드해야 합니다:

1. 방문: https://access.redhat.com/downloads/content/rhel
2. 다운로드: **RHEL 9.5 KVM Guest Image** (rhel-9.5-x86_64-kvm.qcow2)
3. 저장 위치: `downloads/images/rhel-9.5-x86_64-kvm.qcow2`
4. `package.sh` 재실행하여 최종 tarball 생성

## 검증

### 다운로드 검증

```bash
cd 00-prepare
ls -lh downloads/images/
ls -lh downloads/containers/
ls -lh downloads/binaries/
```

### 설치 검증

```bash
# Garage 이미지 확인
podman images | grep garage

# 바이너리 확인
ls -l ../10-node-exporter/node_exporter-*.tar.gz
ls -l ../14-oadp/mc

# RHEL9 이미지 확인
ls -l downloads/images/rhel-*.qcow2
```

## 문제 해결

### "Garage image not found"
- `downloads/containers/` 디렉토리 확인
- `download.sh` 재실행
- podman이 설치되어 있는지 확인

### "RHEL9 image placeholder"
- Red Hat 포털에서 수동 다운로드 필요
- `downloads/images/README.txt` 참조

### "Permission denied"
```bash
chmod +x download.sh package.sh
chmod +x ../10-node-exporter/*.sh
chmod +x ../14-oadp/mc
```

## 팁

1. **대역폭 최적화**: 큰 파일은 외부 저장소에서 다운로드 후 복사
2. **버전 관리**: 다운로드한 파일 버전을 `METADATA.txt`에 기록
3. **체크섬 검증**: 중요 파일은 SHA256 검증 권장
4. **증분 업데이트**: 변경된 파일만 재다운로드/재패키징

## 관련 문서

- [README.md](../README.md) - 전체 프로젝트 가이드
- [01-template/01-template.md](../01-template/01-template.md) - RHEL9 이미지 업로드
- [14-oadp/14-oadp.md](../14-oadp/14-oadp.md) - Garage 설치 가이드

## 라이선스 및 규정 준수

- RHEL 이미지: Red Hat 구독 필요
- Garage: Apache License 2.0
- node_exporter: Apache License 2.0
- MinIO Client (mc): Apache License 2.0
