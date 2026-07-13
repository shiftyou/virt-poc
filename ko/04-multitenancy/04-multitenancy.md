# 04-multitenancy: 멀티 테넌트 VM 환경

## 개요

두 개의 namespace를 격리된 테넌트로 구성하고 테넌트당 하나의 VM을 배포합니다.
RBAC를 통해 사용자별 접근 권한을 제어하여 멀티 테넌트 환경을 시연합니다.

## 사용자 / 권한 구성

```
┌────────────────────────────────────────────────────────────────────┐
│  poc-multitenancy-1                  poc-multitenancy-2            │
│  ┌──────────────────┐                ┌──────────────────┐          │
│  │  poc-mt-vm-1     │                │  poc-mt-vm-2     │          │
│  └──────────────────┘                └──────────────────┘          │
│                                                                    │
│  user1  ── admin  (VM 생성 가능)     user3  ── admin              │
│  user2  ── view   (읽기 전용)        user4  ── view               │
└────────────────────────────────────────────────────────────────────┘
```

| 사용자 | Namespace           | 역할  | VM 생성    | 다른 NS 접근    | 허용 작업 |
|--------|---------------------|-------|------------|-----------------|-----------|
| user1  | poc-multitenancy-1  | admin | **가능**   | **불가**        | VM 생성/편집/삭제, 콘솔 접속 |
| user2  | poc-multitenancy-1  | view  | **불가**   | **불가**        | VM/리소스 조회만 가능 |
| user3  | poc-multitenancy-2  | admin | **가능**   | **불가**        | VM 생성/편집/삭제, 콘솔 접속 |
| user4  | poc-multitenancy-2  | view  | **불가**   | **불가**        | VM/리소스 조회만 가능 |

- 기본 비밀번호: `Redhat1!`
- Identity Provider: HTPasswd (`poc-htpasswd`)
- VM Template: `poc` (01-template 단계에서 등록)

> 각 사용자는 자신에게 할당된 namespace에만 접근할 수 있으며, 다른 namespace는 완전히 접근 불가합니다.

## 사전 요구사항

```bash
# htpasswd 명령어 설치 (없는 경우)
dnf install -y httpd-tools

# cluster-admin 권한으로 로그인
oc login -u system:admin

# poc Template 등록 확인 (01-template 단계가 완료되어야 함)
oc get template poc -n openshift
```

## 실행

```bash
# 구성 실행
./04-multitenancy.sh

# 정리
./04-multitenancy.sh --cleanup
```

## 단계별 구성

### 1. 사용자 생성 (HTPasswd)

`htpasswd` 명령어로 4명의 사용자를 생성하고
`openshift-config` namespace의 Secret(`htpasswd-secret`)에 저장합니다.

HTPasswd Identity Provider는 OAuth CR에 등록되며,
기존 IDP가 있는 경우 append 방식으로 등록됩니다.

```bash
# 수동 확인
oc get secret htpasswd-secret -n openshift-config
oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}'
```

### 2. Namespace 생성

```bash
oc get namespace poc-multitenancy-1 poc-multitenancy-2
```

### 3. RBAC (RoleBinding)

OpenShift 기본 제공 ClusterRole을 **RoleBinding**(namespace 범위)으로 바인딩합니다.
ClusterRoleBinding이 아니므로 namespace 외부 리소스에 대한 권한은 없습니다.

| ClusterRole | 권한 |
|-------------|------|
| `admin`     | namespace 내 모든 리소스 생성/편집/삭제 (namespace 자체는 삭제 불가) |
| `view`      | namespace 내 모든 리소스 조회만 가능 |

```
user1  RoleBinding(admin) → poc-multitenancy-1 전용
user2  RoleBinding(view)  → poc-multitenancy-1 전용
user3  RoleBinding(admin) → poc-multitenancy-2 전용
user4  RoleBinding(view)  → poc-multitenancy-2 전용
```

DataSource 참조 권한 (VM 생성에 필요):
- user1, user3 → `openshift-virtualization-os-images` namespace에 `view` 권한 추가

```bash
oc get rolebindings -n poc-multitenancy-1
oc get rolebindings -n poc-multitenancy-2
```

### 4. VM 생성

namespace당 하나의 `poc` Template 기반 VM을 생성합니다.

| VM 이름       | Namespace           | CPU | Memory | 디스크 | Template |
|---------------|---------------------|-----|--------|--------|----------|
| poc-mt-vm-1   | poc-multitenancy-1  | 1   | 2Gi    | 30Gi   | poc      |
| poc-mt-vm-2   | poc-multitenancy-2  | 1   | 2Gi    | 30Gi   | poc      |

cloud-init 기본 계정: `cloud-user / changeme`

## 검증

### CLI 권한 테스트

```bash
API=$(oc whoami --show-server)

# user1: poc-multitenancy-1 admin — VM 생성 가능
oc login -u user1 -p 'Redhat1!' "$API"
oc get vm -n poc-multitenancy-1    # 성공
oc get vm -n poc-multitenancy-2    # 거부 (권한 없음)

# user2: poc-multitenancy-1 view — 조회만 가능, VM 생성 불가
oc login -u user2 -p 'Redhat1!' "$API"
oc get vm -n poc-multitenancy-1           # 성공 (조회)
oc get vm -n poc-multitenancy-2           # 거부 (권한 없음)
oc create -f vm.yaml -n poc-multitenancy-1  # 거부 (조회만 가능)

# user3: poc-multitenancy-2 admin — VM 생성 가능
oc login -u user3 -p 'Redhat1!' "$API"
oc get vm -n poc-multitenancy-2    # 성공
oc get vm -n poc-multitenancy-1    # 거부 (권한 없음)

# user4: poc-multitenancy-2 view — 조회만 가능, VM 생성 불가
oc login -u user4 -p 'Redhat1!' "$API"
oc get vm -n poc-multitenancy-2           # 성공 (조회)
oc get vm -n poc-multitenancy-1           # 거부 (권한 없음)
oc create -f vm.yaml -n poc-multitenancy-2  # 거부 (조회만 가능)
```

### 콘솔 접속 테스트

1. `https://<console-url>`로 이동
2. Identity Provider 선택: `poc-htpasswd`
3. 각 사용자로 로그인
4. **Virtualization → VirtualMachines** 메뉴 확인
   - user1 / user3: 생성 버튼 활성화, 자신의 namespace만 표시
   - user2 / user4: 조회만 가능, 생성/삭제 버튼 없음

### VM 콘솔 접속

```bash
# admin 사용자는 virtctl console 접속 가능
oc login -u user1 -p 'Redhat1!' "$API"
virtctl console poc-mt-vm-1 -n poc-multitenancy-1
# 로그인: cloud-user / changeme

oc login -u user3 -p 'Redhat1!' "$API"
virtctl console poc-mt-vm-2 -n poc-multitenancy-2
# 로그인: cloud-user / changeme
```

## 문제 해결

### 로그인 불가

HTPasswd IDP 등록 후 인증 Operator가 재시작되는 데 1-2분이 소요됩니다.

```bash
# 인증 Operator 상태 확인
oc get clusteroperator authentication

# oauth-openshift Pod 재시작 확인
oc get pods -n openshift-authentication
```

### view 사용자가 VM을 볼 수 없는 경우

OpenShift Virtualization의 view 권한은 기본 `view` ClusterRole에 집계(aggregated)됩니다.
Virtualization Operator가 정상적으로 설치되어 있으면 `view` 역할로 VM 조회가 가능합니다.

```bash
# view ClusterRole에 kubevirt 규칙이 포함되어 있는지 확인
oc get clusterrole view -o jsonpath='{.rules[*].resources}' | tr ' ' '\n' | grep -i virt
```

### DataSource를 찾을 수 없는 오류

01-template 단계를 먼저 실행하거나 env.conf에 DataSource를 지정하세요.

```bash
# 사용 가능한 DataSource 목록
oc get datasource -n openshift-virtualization-os-images

# env.conf에 추가
DATASOURCE_NAME=rhel9
DATASOURCE_NS=openshift-virtualization-os-images
```

## 정리

```bash
./04-multitenancy.sh --cleanup
```

정리 항목:
- VM (poc-mt-vm-1, poc-mt-vm-2)
- Namespace (poc-multitenancy-1, poc-multitenancy-2) 및 내부 모든 리소스
- 사용자 오브젝트 (user1~user4)
- Identity 오브젝트

> htpasswd secret 및 OAuth IDP 설정은 다른 사용자에게 영향을 줄 수 있으므로 수동으로 제거하세요:
> ```bash
> oc delete secret htpasswd-secret -n openshift-config
> # OAuth IDP 제거: oc edit oauth cluster
> ```
