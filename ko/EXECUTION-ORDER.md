# 실행 순서 가이드

OpenShift Virtualization POC 환경 구축을 위한 단계별 실행 순서입니다.

---

## 시나리오 A: 인터넷 연결 환경 (일반 사용)

OpenShift 클러스터가 인터넷에 연결되어 있는 경우

### 1단계: 저장소 클론

```bash
git clone https://github.com/shiftyou/virt-poc.git
cd virt-poc
```

### 2단계: OpenShift 로그인

```bash
oc login https://api.cluster.example.com:6443
# cluster-admin 권한 필요
```

### 3단계: Operator 설치 (필수)

```bash
# OpenShift Console에서 설치:
# OperatorHub → "OpenShift Virtualization" 검색 → Install

# 또는 CLI로 설치 (operators/ 가이드 참조)
```

**필수 Operator:**
- OpenShift Virtualization
- Kubernetes NMState (네트워크 설정용)

**선택 Operator:** (필요한 기능에 따라)
- OADP (백업/복구)
- Grafana (모니터링)
- MTV (마이그레이션)
- 기타 (operators/ 참조)

### 4단계: 환경 설정

```bash
./setup.sh
```

이 스크립트는:
- 설치된 Operator 자동 감지
- 환경 변수 입력 받기
- `env.conf` 파일 생성

### 5단계: 전체 Lab 실행

```bash
./poc.sh
```

또는 개별 실행:

```bash
cd 01-template
./01-template.sh

cd ../02-network
./02-network.sh

# ... 순서대로 실행
```

### 6단계: 기능 검증

```bash
./check-features.sh
```

---

## 시나리오 B: Air-gapped 환경 (폐쇄망)

인터넷 연결이 없는 환경에서 실행하는 경우

### 1단계: 인터넷 연결된 PC/서버에서 준비

#### 1-1. 저장소 클론

```bash
git clone https://github.com/shiftyou/virt-poc.git
cd virt-poc
```

#### 1-2. 필요 파일 다운로드

```bash
./download.sh
```

**다운로드되는 파일:**
- Garage 컨테이너 이미지 (자동)
- node_exporter 바이너리 (자동)
- mc 클라이언트 (자동)
- RHEL9 qcow2 (수동 - Red Hat 포털에서)

**RHEL9 이미지 수동 다운로드:**
1. https://access.redhat.com/downloads/content/rhel 접속
2. RHEL 9.5 KVM Guest Image 다운로드
3. `downloads/images/` 폴더에 저장

#### 1-3. 배포 패키지 생성

```bash
./package.sh
```

생성되는 파일: `virt-poc-YYYYMMDD-HHMMSS.tar.gz`

#### 1-4. Bastion 호스트로 전송

```bash
# USB, 파일 공유, 또는 승인된 전송 방법 사용
scp virt-poc-*.tar.gz bastion.airgap.local:/tmp/

# 또는 USB 복사
cp virt-poc-*.tar.gz /media/usb/
```

---

### 2단계: Air-gapped 환경의 Bastion에서 배포

#### 2-1. 패키지 추출

```bash
cd /tmp
tar xzf virt-poc-*.tar.gz
cd virt-poc-*/
```

#### 2-2. OpenShift 로그인

```bash
oc login https://api.cluster.example.com:6443
# cluster-admin 권한 필요
```

#### 2-3. Air-gapped 설치

```bash
./install.sh
```

이 스크립트는:
- Garage 컨테이너 이미지 로드 (podman)
- 바이너리 파일 복사
- 다운로드 검증

#### 2-4. 컨테이너 이미지 미러링 (선택)

내부 레지스트리 사용 시:

```bash
# Garage 이미지를 내부 레지스트리로 push
podman tag dxflrs/garage:v1.0.1 registry.internal:5000/garage:v1.0.1
podman push registry.internal:5000/garage:v1.0.1

# 14-oadp/14-oadp.md의 이미지 경로를 내부 레지스트리로 수정
```

#### 2-5. Operator 설치 확인

```bash
# OpenShift Console 접속
# OperatorHub에서 필요한 Operator 설치

# 또는 CLI로 확인
oc get csv -A | grep -i "virtualization\|nmstate"
```

#### 2-6. 환경 설정

```bash
cd en   # 또는 cd ko
./setup.sh
```

#### 2-7. 전체 Lab 실행

```bash
./poc.sh
```

#### 2-8. 기능 검증

```bash
./check-features.sh
```

---

## 상세 실행 순서 (개별 Lab)

`./poc.sh` 대신 개별 Lab을 순서대로 실행하려면:

### 기본 설정 (필수)

```bash
# 1. VM 템플릿 생성
cd 01-template
./01-template.sh
# → RHEL9 이미지 업로드, DataSource, Template 생성

# 2. 네트워크 설정
cd ../02-network
./02-network.sh
# → NNCP 생성/선택, NAD 생성, 테스트 VM 배포

# 3. VM 워크로드 관리
cd ../03-vm-workload
./03-vm-workload.sh
# → VM 생성, 라이브 마이그레이션 테스트
```

### 보안 및 격리 (선택)

```bash
# 4. 멀티테넌시
cd ../04-multitenancy
./04-multitenancy.sh

# 5. 네트워크 정책
cd ../05-network-policy
./05-network-policy.sh

# 6. 리소스 쿼터
cd ../06-resource-quota
./06-resource-quota.sh
```

### 운영 최적화 (선택)

```bash
# 7. Descheduler
cd ../07-descheduler
./07-descheduler.sh

# 8. Liveness Probe
cd ../08-liveness-probe
./08-liveness-probe.sh

# 9. Alert
cd ../09-alert
./09-alert.sh

# 10. Node Exporter
cd ../10-node-exporter
./10-node-exporter.sh
```

### 모니터링 (선택)

```bash
# 11. COO (Cluster Observability Operator)
cd ../11-coo
./11-coo.sh

# 12. Grafana
cd ../12-grafana
./12-grafana.sh
```

### 마이그레이션 및 백업 (선택)

```bash
# 13. MTV (VMware 마이그레이션)
cd ../13-mtv
./13-mtv.sh

# 14. OADP (백업/복구)
cd ../14-oadp
./14-oadp.sh
# → Garage S3 스토리지 자동 생성 또는 선택
```

### 노드 관리 (선택)

```bash
# 15. 노드 유지보수
cd ../15-node-maintenance
./15-node-maintenance.sh

# 16. SNR (Self Node Remediation)
cd ../16-snr
./16-snr.sh

# 17. FAR (Fence Agents Remediation)
cd ../17-far
./17-far.sh

# 18. 노드 추가
cd ../18-add-node
./18-add-node.sh
```

### 고급 설정 (선택)

```bash
# 19. HyperConverged
cd ../19-hyperconverged
./19-hyperconverged.sh

# 20. 로깅
cd ../20-logging
./20-logging.sh

# 21. 업그레이드
cd ../21-upgrade
./21-upgrade.sh
```

---

## 체크포인트

각 단계 후 확인:

### setup.sh 실행 후

```bash
# env.conf 파일 확인
cat env.conf

# Operator 설치 상태 확인
oc get csv -A | grep -i "virtualization\|nmstate\|oadp\|grafana"
```

### 각 Lab 실행 후

```bash
# 해당 Lab의 리소스 확인
# 예: 01-template 후
oc get datasource -n openshift-virtualization-os-images
oc get template -n openshift-virtualization-os-images

# 예: 02-network 후
oc get nncp
oc get network-attachment-definitions -A

# 예: 03-vm-workload 후
oc get vm,vmi -A
```

### poc.sh 완료 후

```bash
# 전체 기능 검증
./check-features.sh

# VM 상태 확인
oc get vm,vmi -A

# 네트워크 확인
oc get nncp,nad -A

# 백업 확인 (OADP 실행한 경우)
oc get backup -n openshift-adp
```

---

## 문제 해결 시 실행 순서

### 1. 현재 상태 확인

```bash
./check-features.sh --verbose
```

### 2. 실패한 Lab만 재실행

```bash
cd <실패한-lab-번호>
./<실패한-lab-번호>.sh
```

### 3. 로그 확인

```bash
# Virtualization operator 로그
oc logs -n openshift-cnv -l app.kubernetes.io/component=virt-operator --tail=50

# HyperConverged 상태
oc get hco -n openshift-cnv -o yaml

# VM 상태
oc describe vm <vm-name> -n <namespace>
```

### 4. 특정 기능만 재설정

```bash
# 예: NNCP 재설정
cd 02-network
./02-network.sh
# → 기존 NNCP 선택 또는 새로 생성

# 예: Garage 재배포
cd 14-oadp
# 14-oadp.md의 Garage 섹션 참조하여 재배포
```

---

## 권장 실행 순서 (최소 POC)

최소한의 기능만 테스트하려면:

```bash
# 1. 기본 설정
./setup.sh

# 2. 필수 Lab만 실행
cd 01-template && ./01-template.sh
cd ../02-network && ./02-network.sh
cd ../03-vm-workload && ./03-vm-workload.sh

# 3. 검증
cd ..
./check-features.sh
```

---

## 전체 POC 실행 순서 (모든 기능)

모든 기능을 테스트하려면:

```bash
# 1. 환경 설정
./setup.sh

# 2. 전체 Lab 실행 (자동)
./poc.sh

# 3. 검증
./check-features.sh

# 4. 개별 기능 테스트
# - VM 생성 및 마이그레이션
# - 백업 및 복구
# - 모니터링 대시보드 확인
# - 네트워크 정책 테스트
```

---

## iSCSI 스토리지 사용 시

iSCSI를 VM 디스크로 사용하려면:

```bash
# 1. iSCSI 설정 가이드 참조
less operators/iscsi-storage.md

# 2. Worker 노드에 iSCSI initiator 설정
# (MachineConfig 적용 - 가이드 참조)

# 3. PV/PVC 생성
# (가이드의 예제 YAML 사용)

# 4. VM에서 iSCSI PVC 사용
# (03-vm-workload 또는 가이드 참조)
```

---

## 요약

### 인터넷 연결 환경
1. `git clone` → 2. `oc login` → 3. Operator 설치 → 4. `./setup.sh` → 5. `./poc.sh` → 6. `./check-features.sh`

### Air-gapped 환경
**준비:** `git clone` → `./download.sh` → `./package.sh` → 전송

**배포:** 추출 → `oc login` → `./install.sh` → `cd ko` → `./setup.sh` → `./poc.sh` → `./check-features.sh`

---

## 환경 초기화 (Clean Up)

전체 환경을 초기화하려면:

```bash
# 모든 POC 리소스 삭제 및 파일 정리
./poc.sh reset
```

### 삭제되는 항목

**자동 삭제:**
- 모든 `poc-*` namespace (확인 후)
- 생성된 YAML 파일 (*.yaml, nncp-*.yaml, nad-*.yaml 등)
- 임시 파일 (*.tmp, *.log, *.swp)
- .DS_Store 파일

**선택적 삭제 (확인 메시지):**
- `../downloads/` - 다운로드된 파일
- `virt-poc-*.tar.gz` - 패키징된 tarball

### 유지되는 항목

- `env.conf` - 환경 설정 파일 (재사용 가능)
- Lab 스크립트 및 문서
- Git 저장소 파일

### 재시작하기

초기화 후 처음부터 다시 시작:

```bash
# 1. 초기화 (이미 실행했다면 생략)
./poc.sh reset

# 2. 환경 재설정 (env.conf 재생성하려면)
./setup.sh

# 3. 전체 Lab 재실행
./poc.sh start

# 4. 검증
./check-features.sh
```

### 부분 초기화

특정 Lab만 재실행하려면:

```bash
# 해당 Lab의 namespace만 삭제
oc delete namespace poc-network

# Lab 재실행
cd 02-network
./02-network.sh
```
