# OpenShift Audit Logging 랩

OpenShift APIServer의 Audit Policy를 구성하고,
OpenShift Logging Operator를 통해 Audit 로그를 수집/저장합니다.

```
APIServer (kube-apiserver)
  │  Audit Log 생성 (WriteRequestBodies / AllRequestBodies)
  ▼
Vector Collector (DaemonSet)
  └─ ClusterLogForwarder
       ├─ audit   ─┐
       ├─ infra    ├─ LokiStack (로그 저장, Garage S3 사용)
       └─ app    ─┘
```

---

## 사전 요구사항

- `oc` 명령어로 클러스터에 로그인 (cluster-admin 권한)
- (선택) OpenShift Logging Operator 설치 — `operators/` 참조
- (선택) Loki Operator 설치 — `operators/` 참조
- (선택) Garage 또는 ODF S3 백엔드 — `14-oadp.md`의 Garage 설치 가이드 참조
- `20-logging.sh` 실행 완료

> Logging Operator가 설치되지 않아도 **APIServer Audit Policy 구성**은 단독으로 동작합니다.

---

## Audit Profile 비교

| Profile | 기록 내용 | 로그 볼륨 | 권장 사용 |
|--------|----------|----------|---------|
| `Default` | 메타데이터만 (URL, Method, 응답 코드, 사용자, 시간) | 최소 | 기본 감사 |
| `WriteRequestBodies` | 쓰기 요청 본문 (create/update/patch/delete) | 중간 | **운영 환경 권장** |
| `AllRequestBodies` | 모든 요청/응답 본문 | 최대 | 상세 디버깅 |
| `None` | 비활성화 | - | 비권장 |

---

## 구성 개요

| 리소스 | Namespace | 역할 |
|--------|------------|------|
| APIServer `cluster` | cluster 범위 | Audit Profile 구성 |
| ClusterLogging `instance` | `openshift-logging` | Vector Collector 관리 |
| LokiStack `logging-loki` | `openshift-logging` | 로그 저장 (S3 사용) |
| ClusterLogForwarder `instance` | `openshift-logging` | 수집/전달 파이프라인 |
| Secret `logging-loki-s3` | `openshift-logging` | Garage S3 자격 증명 |

---

## Step 1 — APIServer Audit Policy

```bash
oc patch apiserver cluster --type=merge -p '{"spec":{"audit":{"profile":"WriteRequestBodies"}}}'

# 또는 YAML로 적용
oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: APIServer
metadata:
  name: cluster
spec:
  audit:
    profile: WriteRequestBodies
EOF

# 적용 후 kube-apiserver 롤아웃 확인 (수 분 소요)
oc get co kube-apiserver
```

현재 설정 확인:

```bash
oc get apiserver cluster -o jsonpath='{.spec.audit.profile}'
```

---

## Step 2 — ClusterLogging (Logging Operator 설치 시)

```yaml
apiVersion: logging.openshift.io/v1
kind: ClusterLogging
metadata:
  name: instance
  namespace: openshift-logging
spec:
  managementState: Managed
  logStore:
    type: lokistack
    lokiStack:
      name: logging-loki
    retentionPolicy:
      application:
        maxAge: 7d
      audit:
        maxAge: 30d
      infrastructure:
        maxAge: 7d
  collection:
    type: vector
```

---

## Step 3 — LokiStack (Loki Operator 설치 시)

Garage S3를 스토리지로 사용하는 LokiStack입니다.

### S3 Secret 생성

```bash
oc create secret generic logging-loki-s3 \
  -n openshift-logging \
  --from-literal=access_key_id=<GARAGE_ACCESS_KEY> \
  --from-literal=access_key_secret=<GARAGE_SECRET_KEY> \
  --from-literal=bucketnames=<GARAGE_BUCKET> \
  --from-literal=endpoint=<GARAGE_ENDPOINT> \
  --from-literal=region=garage
```

### LokiStack CR

```yaml
apiVersion: loki.grafana.com/v1
kind: LokiStack
metadata:
  name: logging-loki
  namespace: openshift-logging
spec:
  size: 1x.small
  storage:
    schemas:
      - version: v13
        effectiveDate: "2024-01-01"
    secret:
      name: logging-loki-s3
      type: s3
  storageClassName: <STORAGE_CLASS>
  tenants:
    mode: openshift-logging
```

---

## Step 4 — ClusterLogForwarder (Audit 포함)

### Loki 사용 시

```yaml
apiVersion: logging.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: instance
  namespace: openshift-logging
spec:
  outputs:
    - name: loki-storage
      type: lokiStack
      lokiStack:
        target:
          name: logging-loki
          namespace: openshift-logging
        authentication:
          token:
            from: serviceAccount
  pipelines:
    - name: all-to-loki
      inputRefs:
        - application
        - infrastructure
        - audit
      outputRefs:
        - loki-storage
```

### default output 사용 시 (Loki 미설치)

```yaml
apiVersion: logging.openshift.io/v1
kind: ClusterLogForwarder
metadata:
  name: instance
  namespace: openshift-logging
spec:
  pipelines:
    - name: all-to-default
      inputRefs:
        - application
        - infrastructure
        - audit
      outputRefs:
        - default
```

---

## 상태 확인

```bash
# Audit Policy 확인
oc get apiserver cluster -o jsonpath='{.spec.audit.profile}'

# kube-apiserver 롤아웃 상태
oc get co kube-apiserver

# ClusterLogging 상태
oc get clusterlogging -n openshift-logging

# ClusterLogForwarder 상태
oc get clusterlogforwarder -n openshift-logging

# LokiStack 상태
oc get lokistack -n openshift-logging

# Collector Pod 상태
oc get pods -n openshift-logging -l component=collector
```

---

## Audit 로그 직접 확인

```bash
# master 노드에서 audit 로그 스트리밍
oc adm node-logs --role=master --path=kube-apiserver/ | grep audit | tail -20

# Collector 로그 확인
oc logs -n openshift-logging -l component=collector --tail=20

# 특정 사용자의 audit 이벤트 검색
oc adm node-logs --role=master --path=kube-apiserver/ \
  | grep '"user":{"username":"system:admin"' | tail -10
```

---

## 문제 해결

```bash
# kube-apiserver 롤아웃 진행 상황 확인
oc get co kube-apiserver
oc get pods -n openshift-kube-apiserver | grep kube-apiserver

# LokiStack 이벤트 확인
oc describe lokistack logging-loki -n openshift-logging

# Collector 에러 로그
oc logs -n openshift-logging -l component=collector --tail=50 | grep -i error

# ClusterLogForwarder 상태 상세
oc describe clusterlogforwarder instance -n openshift-logging
```

---

## 롤백

```bash
# Audit Policy 초기화 (Default로 복원)
oc patch apiserver cluster --type=merge -p '{"spec":{"audit":{"profile":"Default"}}}'

# ClusterLogForwarder 삭제
oc delete clusterlogforwarder instance -n openshift-logging

# ClusterLogging 삭제
oc delete clusterlogging instance -n openshift-logging

# LokiStack 삭제
oc delete lokistack logging-loki -n openshift-logging

# S3 Secret 삭제
oc delete secret logging-loki-s3 -n openshift-logging
```
