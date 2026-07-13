# 20-upgrade: Airgap 환경 OpenShift 4.20 → 4.21 업그레이드

## 개요

인터넷이 차단된 airgap 환경에서 OpenShift를 업그레이드하려면 세 가지가 필요합니다.

| 구성 요소 | 역할 |
|-----------|------|
| **oc-mirror** | 업그레이드에 필요한 이미지 + graph 데이터를 내부 레지스트리에 미러링 |
| **IDMS** (ImageDigestMirrorSet) | 클러스터의 이미지 pull 요청을 내부 레지스트리로 리다이렉트 |
| **OSUS** (OpenShift Update Service) | 로컬 업그레이드 graph 제공 → **콘솔에 업그레이드 버튼 표시** |

```
[Bastion - 인터넷 연결]               [Airgap 클러스터]
  quay.io/openshift-release  →   내부 레지스트리  →  OSUS  →  CVO  →  Console
  (oc-mirror로 미러링)               (IDMS 적용)      (graph)  (상태)   (업그레이드 UI)
```

---

## 사전 요구사항

### 필수 도구 (Bastion 호스트)

```bash
# oc-mirror v2 플러그인 설치
# https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/latest/oc-mirror.tar.gz
tar xzf oc-mirror.tar.gz
chmod +x oc-mirror
mv oc-mirror /usr/local/bin/

# 버전 확인
oc mirror version
```

### 내부 레지스트리 요구사항

- TLS 인증서 구성 (자체 서명 가능, 단 클러스터의 신뢰 CA에 추가 필요)
- 충분한 저장 공간 (4.20→4.21 업그레이드 이미지: 약 20~30GB)
- 클러스터 노드에서 접근 가능한 주소

### 환경 변수 설정 (Bastion)

```bash
export REGISTRY_HOST="registry.example.com"   # 내부 레지스트리 주소
export MIRROR_PREFIX="ocp4"                   # 레지스트리 내 저장 경로 접두사
export PULL_SECRET="/path/to/pull-secret.json" # Red Hat pull secret
```

---

## Step 1: 이미지 미러링 (Bastion → 내부 레지스트리)

### 1-1. imageset-config.yaml 준비

[imageset-config.yaml](./imageset-config.yaml) 파일을 사용합니다.

```yaml
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  platform:
    graph: true          # graph 데이터 이미지도 미러링 (OSUS에서 사용)
    channels:
      - name: stable-4.21
        minVersion: 4.20.0
        maxVersion: 4.21.99
        shortestPath: true
```

> `graph: true`를 반드시 설정해야 합니다.
> 이 옵션이 없으면 OSUS가 업그레이드 경로를 제공할 수 없어 콘솔에 업그레이드가 표시되지 않습니다.

### 1-2. 미러링 실행

```bash
# 미러링 작업 디렉토리 생성
mkdir -p /mnt/mirror

# oc-mirror 실행 (인터넷 연결 필요)
oc mirror \
  --config=imageset-config.yaml \
  --workspace file:///mnt/mirror \
  docker://${REGISTRY_HOST}/${MIRROR_PREFIX} \
  --v2

# 완료 후 출력 파일 확인
ls /mnt/mirror/working-dir/mirror-to-disk/
```

> 완료 시 `/mnt/mirror/working-dir/cluster-resources/` 아래에 다음 파일이 생성됩니다:
> - `idms-oc-mirror.yaml` — ImageDigestMirrorSet
> - `itms-oc-mirror.yaml` — ImageTagMirrorSet
> - `updateService.yaml` — UpdateService CR (graphDataImage 경로 포함)
> - `release-signatures/` — 릴리스 서명

### 1-3. graphDataImage 경로 확인

```bash
# oc-mirror가 생성한 UpdateService 파일에서 실제 이미지 경로 확인
cat /mnt/mirror/working-dir/cluster-resources/updateService.yaml
```

예시 출력:
```yaml
spec:
  releases: registry.example.com/ocp4/openshift/release-images
  graphDataImage: registry.example.com/ocp4/openshift/graph-image:latest
```

> `update-service.yaml`에서 `REGISTRY_HOST`를 대체할 때 이 값을 사용합니다.

---

## Step 2: 클러스터에 IDMS 적용

```bash
# oc-mirror가 생성한 IDMS 적용
oc apply -f /mnt/mirror/working-dir/cluster-resources/idms-oc-mirror.yaml
oc apply -f /mnt/mirror/working-dir/cluster-resources/itms-oc-mirror.yaml

# 릴리스 서명 적용
oc apply -f /mnt/mirror/working-dir/cluster-resources/release-signatures/

# MachineConfig 롤아웃 대기 (IDMS는 노드 재시작 없이 적용되지만 확인 필요)
oc get mcp
```

IDMS 적용 확인:
```bash
oc get imagedigestmirrorset
oc get imagetagmirrorset
```

---

## Step 3: OpenShift Update Service (OSUS) 배포

Console에 업그레이드 버튼이 표시되려면 클러스터 내부에서 OSUS가 실행되어
업그레이드 graph를 제공해야 합니다.

### 3-1. OSUS Operator 설치

> **Airgap 환경 참고:** `redhat-operators` CatalogSource가 내부 레지스트리에 미러링되어 있어야 합니다.
> 미러링되지 않은 경우 [3-1-b 수동 설치](#3-1-b-수동-설치-olm-없이)를 참조하세요.

```bash
# Namespace + OperatorGroup + Subscription 적용
oc apply -f update-service.yaml --field-manager=apply-server
# (update-service.yaml 상단의 Namespace/OperatorGroup/Subscription 섹션만 먼저 적용)

# CSV 설치 확인
oc get csv -n openshift-update-service
# NAME                        DISPLAY                        VERSION   PHASE
# update-service.v4.x.x      OpenShift Update Service       4.x.x     Succeeded
```

#### 3-1-b. 수동 설치 (OLM 없이)

OLM 카탈로그 미러링이 불가능한 경우 OSUS 매니페스트를 직접 적용합니다:

```bash
# OSUS operator 매니페스트 다운로드 (인터넷 연결된 bastion에서)
oc adm release extract \
  --from=registry.example.com/ocp4/openshift/release-images:4.21.0 \
  --to=/tmp/release-manifests \
  --credentials-requests

# 또는 GitHub에서 직접 가져오기
# https://github.com/openshift/cincinnati-operator
```

### 3-2. UpdateService CR 적용

oc-mirror가 생성한 `updateService.yaml`을 사용하거나, `update-service.yaml`에서
`REGISTRY_HOST`를 교체하여 적용합니다.

```bash
# REGISTRY_HOST 교체 후 적용
sed 's|REGISTRY_HOST|registry.example.com|g' update-service.yaml | \
  oc apply -f - -n openshift-update-service

# 또는 oc-mirror가 생성한 파일 사용
oc apply -f /mnt/mirror/working-dir/cluster-resources/updateService.yaml
```

OSUS Pod 기동 확인:
```bash
oc get pods -n openshift-update-service
# NAME                       READY   STATUS    RESTARTS   AGE
# service-7d9f8c6b4-xxxxx    1/1     Running   0          2m
# service-7d9f8c6b4-yyyyy    1/1     Running   0          2m
```

OSUS Route 확인:
```bash
oc get route -n openshift-update-service
# NAME      HOST/PORT                                             ...
# service   service-openshift-update-service.apps.cluster.com    ...
```

---

## Step 4: ClusterVersion Upstream 구성

CVO(Cluster Version Operator)가 로컬 OSUS에서 업그레이드 graph를 가져오도록 구성합니다.

```bash
# OSUS Route 주소 조회
OSUS_HOST=$(oc get route service \
  -n openshift-update-service \
  -o jsonpath='{.status.ingress[0].host}')

echo "OSUS 엔드포인트: https://${OSUS_HOST}/graph"

# ClusterVersion upstream 변경
oc patch clusterversion version \
  --type=merge \
  -p "{\"spec\":{\"upstream\":\"https://${OSUS_HOST}/graph\"}}"

# 채널 구성 (stable-4.21)
oc patch clusterversion version \
  --type=merge \
  -p '{"spec":{"channel":"stable-4.21"}}'
```

구성 확인:
```bash
oc get clusterversion version -o yaml | grep -A5 'spec:'
# spec:
#   channel: stable-4.21
#   upstream: https://service-openshift-update-service.apps.cluster.com/graph
```

CVO가 업그레이드 경로를 감지하는 데 1-2분 소요됩니다:
```bash
oc get clusterversion version
# NAME      VERSION   AVAILABLE   PROGRESSING   SINCE   STATUS
# version   4.20.x    True        False         ...     4.21.x available
```

---

## Step 5: 콘솔에서 업그레이드 확인

1. OpenShift Console 접속
2. **Administration → Cluster Settings**로 이동
3. **Update** 탭 클릭
4. `stable-4.21` 채널에 `4.21.x` 버전이 표시되는지 확인

업그레이드 버튼이 나타나면 클릭하여 업그레이드를 시작하거나,
CLI로 실행합니다:

```bash
# 사용 가능한 업그레이드 버전 확인
oc adm upgrade

# 특정 버전으로 업그레이드 (권장)
oc adm upgrade --to=4.21.x

# 이미지 digest로 직접 업그레이드 (채널 외 버전 강제 적용 시)
OCP_VERSION="4.21.0"
DIGEST=$(oc get clusterversion version \
  -o jsonpath="{.status.availableUpdates[?(@.version==\"${OCP_VERSION}\")].image}")
oc adm upgrade --to-image="${DIGEST}" --allow-explicit-upgrade
```

---

## 업그레이드 진행 모니터링

```bash
# 전체 진행 상황
oc get clusterversion version

# 상세 이벤트
oc describe clusterversion version

# Operator별 업그레이드 상태
oc get clusteroperators

# 아직 업그레이드 중인 Operator 필터링
oc get clusteroperators \
  -o custom-columns=\
'NAME:.metadata.name,VERSION:.status.versions[0].version,AVAILABLE:.status.conditions[?(@.type=="Available")].status,PROGRESSING:.status.conditions[?(@.type=="Progressing")].status'

# 노드 업그레이드 상태 (MachineConfigPool)
oc get mcp

# 실시간 로그
oc logs -n openshift-cluster-version \
  -l app=cluster-version-operator -f
```

---

## 문제 해결

### 콘솔에 업그레이드가 표시되지 않는 경우

```bash
# 1. OSUS graph 엔드포인트 직접 확인
OSUS_HOST=$(oc get route service -n openshift-update-service \
  -o jsonpath='{.status.ingress[0].host}')

# cluster_id 및 채널 확인
CLUSTER_ID=$(oc get clusterversion version -o jsonpath='{.spec.clusterID}')
curl -sH "Accept: application/json" \
  "https://${OSUS_HOST}/graph?channel=stable-4.21&id=${CLUSTER_ID}" | \
  python3 -m json.tool 2>/dev/null || \
  echo "(JSON 파싱 실패 - 원시 응답 확인 필요)"

# 2. CVO가 OSUS 엔드포인트에 도달할 수 있는지 확인
oc get clusterversion version -o jsonpath='{.spec.upstream}'

# 3. CVO 로그에서 업그레이드 감지 에러 확인
oc logs -n openshift-cluster-version \
  -l app=cluster-version-operator --tail=50 | grep -i "error\|upstream\|graph"

# 4. graphDataImage pull 에러 확인
oc describe pod -n openshift-update-service | grep -A5 "Events:"
```

### IDMS 적용 후 이미지 Pull 실패

```bash
# IDMS 내용 확인
oc get imagedigestmirrorset -o yaml

# 레지스트리 CA 신뢰 추가
oc create configmap registry-ca \
  --from-file=registry.example.com=/path/to/ca.crt \
  -n openshift-config

oc patch image.config.openshift.io/cluster \
  --type=merge \
  -p '{"spec":{"additionalTrustedCA":{"name":"registry-ca"}}}'
```

### 업그레이드 중단/재시도

```bash
# 업그레이드 상태 강제 재확인
oc adm upgrade --force
```

---

## 관련 파일

| 파일 | 설명 |
|------|------|
| [imageset-config.yaml](./imageset-config.yaml) | oc-mirror imageset 설정 |
| [update-service.yaml](./update-service.yaml) | OSUS Namespace/OperatorGroup/Subscription/UpdateService CR |

## 참조 문서

- [OpenShift 공식 문서: 연결 해제된 환경에서 클러스터 업데이트](https://docs.openshift.com/container-platform/latest/updating/updating_a_cluster/updating_disconnected_cluster/disconnected-update.html)
- [oc-mirror v2 사용법](https://docs.openshift.com/container-platform/latest/installing/disconnected_install/installing-mirroring-disconnected-v2.html)
- [OpenShift Update Service 구성](https://docs.openshift.com/container-platform/latest/updating/updating_a_cluster/updating_disconnected_cluster/disconnected-update-osus.html)
