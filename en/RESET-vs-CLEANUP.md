# run.sh reset vs cleanup 비교

두 명령어의 차이점과 사용 시나리오를 설명합니다.

---

## 📋 요약 비교

| 항목 | `run.sh reset` | `run.sh cleanup` |
|------|----------------|-------------------|
| **목적** | 전체 환경 초기화 | 각 Lab의 정리 스크립트 실행 |
| **삭제 방법** | 네임스페이스 전체 삭제 | 각 Lab 스크립트의 --cleanup 옵션 |
| **실행 순서** | 순서 무관 (네임스페이스 일괄 삭제) | **역순** (21 → 01) |
| **로컬 파일** | YAML, tmp 파일 삭제 | Lab 스크립트가 생성한 파일만 |
| **속도** | 빠름 (한 번에 삭제) | 느림 (각 스크립트 순차 실행) |
| **사용 시기** | 완전 초기화, 빠른 리셋 | 점진적 제거, 안전한 정리 |

---

## `run.sh reset` - 전체 환경 초기화

### 동작 방식

```bash
./run.sh reset
```

1. **모든 poc-* 네임스페이스 삭제** (한 번에)
   - `oc delete namespace poc-*`
   - 네임스페이스 안의 모든 리소스도 함께 삭제

2. **생성된 파일 정리**
   - YAML 파일 (*.yaml, nncp-*.yaml, nad-*.yaml 등)
   - 임시 파일 (*.tmp, *.log, *.swp, .DS_Store)

3. **선택적 삭제 (확인 요청)**
   - `00-prepare/downloads/` - 다운로드된 파일
   - `virt-poc-*.tar.gz` - 패키징된 tarball

### 삭제되는 리소스 예시

```
Kubernetes 리소스:
  ✗ namespace/poc-template
  ✗ namespace/poc-network
  ✗ namespace/poc-workload
  ✗ namespace/poc-oadp
  ✗ namespace/poc-alert
  ... (모든 poc-* 네임스페이스)

로컬 파일:
  ✗ 02-network/nncp-br1-nncp.yaml
  ✗ 02-network/nad-poc-bridge-nad.yaml
  ✗ 14-oadp/cloud-credentials-secret.yaml
  ✗ 14-oadp/volumesnapshotclass.yaml
  ✗ **/*.tmp
  ✗ **/*.log
```

### 장점

- ✅ **빠름** - 한 번에 모든 네임스페이스 삭제
- ✅ **간단함** - 복잡한 순서 고려 불필요
- ✅ **완전함** - 모든 POC 리소스 제거 보장
- ✅ **파일 정리** - 생성된 파일도 함께 정리

### 단점

- ⚠️ **전체 삭제** - 선택적 제거 불가
- ⚠️ **비가역적** - 삭제 후 복구 불가

### 사용 시나리오

```bash
# 시나리오 1: 처음부터 다시 시작
./run.sh reset
./setup.sh
./run.sh start

# 시나리오 2: 다른 설정으로 재시작
./run.sh reset
# env.conf 수정
./run.sh start

# 시나리오 3: 데모 후 환경 정리
./run.sh reset
# 깔끔한 상태로 복원
```

---

## `run.sh cleanup` - 점진적 정리

### 동작 방식

```bash
./run.sh cleanup
```

1. **각 Lab 디렉토리를 역순으로 순회** (21 → 01)
2. **각 Lab의 스크립트에 --cleanup 옵션 전달**
   ```bash
   ./21-upgrade/21-upgrade.sh --cleanup
   ./20-logging/20-logging.sh --cleanup
   ./19-hyperconverged/19-hyperconverged.sh --cleanup
   ...
   ./01-template/01-template.sh --cleanup
   ```
3. **각 스크립트가 자신이 생성한 리소스만 제거**

### 각 Lab의 --cleanup 예시

```bash
# 01-template/01-template.sh --cleanup
# 삭제:
#   - DataSource/poc
#   - Template/poc
#   - 업로드된 DataVolume

# 02-network/02-network.sh --cleanup
# 삭제:
#   - NetworkAttachmentDefinition
#   - namespace/poc-network
#   - 테스트 VM

# 14-oadp/14-oadp.sh --cleanup
# 삭제:
#   - DataProtectionApplication
#   - BackupStorageLocation
#   - cloud-credentials Secret
#   - OBC (ObjectBucketClaim)
#   - namespace/poc-oadp
```

### 장점

- ✅ **안전함** - 의존성 순서대로 역순 삭제
- ✅ **세밀함** - 각 Lab이 자신의 리소스만 정리
- ✅ **추적 가능** - 어떤 Lab이 무엇을 삭제하는지 확인
- ✅ **선택적** - 일부 스크립트만 실행 가능

### 단점

- ⚠️ **느림** - 21개 스크립트를 순차 실행
- ⚠️ **불완전할 수 있음** - 스크립트에 --cleanup 구현 안 된 경우
- ⚠️ **복잡함** - 각 스크립트의 cleanup 로직 필요

### 사용 시나리오

```bash
# 시나리오 1: 안전한 제거 (의존성 고려)
./run.sh cleanup
# 역순으로 하나씩 정리

# 시나리오 2: 특정 Lab만 재실행
cd 14-oadp
./14-oadp.sh --cleanup  # 해당 Lab만 정리
./14-oadp.sh            # 재실행

# 시나리오 3: 디버깅
# cleanup이 어디서 실패하는지 확인
./run.sh cleanup
# 각 Lab의 cleanup 과정 확인 가능
```

---

## 실제 비교 예시

### Scenario: OADP Lab 재실행

**방법 1: reset 사용**
```bash
./run.sh reset                    # 모든 POC 네임스페이스 삭제 (5초)
./setup.sh                    # 환경 재설정 필요
cd 14-oadp && ./14-oadp.sh   # OADP만 재실행

# 장점: 빠름, 깔끔함
# 단점: 다른 Lab도 함께 삭제됨
```

**방법 2: cleanup 사용**
```bash
cd 14-oadp
./14-oadp.sh --cleanup        # OADP만 정리 (30초)
./14-oadp.sh                  # 재실행

# 장점: 다른 Lab 유지
# 단점: 느림, 수동으로 Lab 지정 필요
```

**방법 3: 직접 삭제**
```bash
oc delete namespace poc-oadp  # 해당 네임스페이스만 삭제 (3초)
cd 14-oadp && ./14-oadp.sh   # 재실행

# 장점: 가장 빠름
# 단점: 클러스터 레벨 리소스는 남을 수 있음
```

---

## 언제 무엇을 사용할까?

### `run.sh reset` 사용

✅ **완전히 처음부터 다시 시작**
```bash
./run.sh reset && ./setup.sh && ./run.sh start
```

✅ **다른 환경 설정 테스트**
```bash
./run.sh reset
# env.conf 수정 또는 삭제
./setup.sh  # 새 설정으로
./run.sh start
```

✅ **데모 후 빠른 정리**
```bash
./run.sh reset
# 1-2분 안에 모든 POC 리소스 제거
```

✅ **디스크 공간 확보**
```bash
./run.sh reset
# 모든 생성된 파일 제거
# downloads/ 및 tarball도 선택적 제거
```

---

### `run.sh cleanup` 사용

✅ **프로덕션 환경 제거 (안전)**
```bash
./run.sh cleanup
# 의존성 순서대로 안전하게 제거
```

✅ **특정 Lab만 재실행**
```bash
cd 14-oadp
./14-oadp.sh --cleanup
./14-oadp.sh
```

✅ **문제 디버깅**
```bash
./run.sh cleanup
# 각 Lab의 정리 과정 확인
# 어디서 실패하는지 파악
```

✅ **부분적 제거**
```bash
# 예: Lab 15-21만 제거
for i in {21..15}; do
  cd ${i}-*/
  ./*.sh --cleanup
  cd ..
done
```

---

## 권장 사항

### 일반적인 경우

```bash
# 빠른 초기화가 필요하면
./run.sh reset

# 안전한 제거가 필요하면
./run.sh cleanup
```

### 개발/테스트 중

```bash
# 특정 Lab만 재실행
cd <lab-dir>
./<lab>.sh --cleanup
./<lab>.sh

# 또는 직접 네임스페이스 삭제
oc delete namespace poc-<name>
cd <lab-dir> && ./<lab>.sh
```

### CI/CD 파이프라인

```bash
# 빠른 정리가 필요
./run.sh reset

# 리소스 누수 방지
./run.sh reset || ./run.sh cleanup || true
```

---

## 주의사항

### reset 사용 시

⚠️ **env.conf는 유지됨**
- 재사용하려면 그대로 두기
- 새로 설정하려면 삭제 후 `./setup.sh`

⚠️ **클러스터 레벨 리소스**
- NNCP, Template은 네임스페이스 밖에 있음
- `reset`으로는 삭제 안 됨
- 필요시 수동 삭제:
  ```bash
  oc delete nncp --all
  oc delete template poc -n openshift-virtualization-os-images
  ```

### cleanup 사용 시

⚠️ **--cleanup 미구현 스크립트**
- 모든 Lab이 --cleanup을 구현한 것은 아님
- 일부는 아무 동작 안 할 수 있음

⚠️ **역순 실행 중요**
- 순방향으로 실행하면 의존성 오류 발생 가능
- 반드시 21 → 01 순서로

---

## 요약

| 상황 | 권장 명령어 | 이유 |
|------|-----------|------|
| 처음부터 다시 시작 | `./run.sh reset` | 빠르고 완전함 |
| 특정 Lab만 재실행 | `cd <lab> && ./<lab>.sh --cleanup` | 다른 Lab 유지 |
| 안전한 전체 제거 | `./run.sh cleanup` | 의존성 고려 |
| 데모 후 정리 | `./run.sh reset` | 가장 빠름 |
| 프로덕션 환경 | `./run.sh cleanup` | 안전함 |
| CI/CD | `./run.sh reset` | 속도 중요 |

**일반 원칙:**
- 빠르게 = `./run.sh reset`
- 안전하게 = `./run.sh cleanup`
- 부분적으로 = 직접 네임스페이스 삭제 또는 개별 Lab --cleanup
