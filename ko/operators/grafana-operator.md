# Grafana Operator 설치

## 개요

Grafana Operator는 OpenShift 클러스터에 Grafana 인스턴스를 배포하고 관리합니다.
OpenShift Virtualization의 VM 메트릭(CPU, 메모리, 네트워크, 디스크)을 시각화하는 대시보드를 구성할 수 있습니다.

---

## 사전 요구 사항

- cluster-admin 권한
- OpenShift User Workload Monitoring 활성화

---

## 설치 방법

### 방법 1: OpenShift Console (Web UI)

1. **Operators > OperatorHub** 메뉴로 이동
2. `Grafana` 검색
3. **Grafana Operator** (Community) 선택
4. `Install` 클릭
5. 설정:
   - Installation mode: `A specific namespace on the cluster`
   - Installed Namespace: `poc-grafana` (새로 생성)
6. `Install` 클릭

### 방법 2: CLI (YAML)

```bash
# Namespace 생성
oc new-project poc-grafana

# Operator 설치
cat <<'EOF' | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: grafana-operator
  namespace: poc-grafana
spec:
  targetNamespaces:
  - poc-grafana
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: grafana-operator
  namespace: poc-grafana
spec:
  channel: v5
  name: grafana-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF
```

### 설치 확인

```bash
oc get csv -n poc-grafana | grep grafana
```

---

## Grafana 인스턴스 생성

```bash
cat <<'EOF' | oc apply -f -
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: poc-grafana
  namespace: poc-grafana
  labels:
    dashboards: poc-grafana
spec:
  config:
    auth:
      disable_login_form: "false"
    security:
      admin_user: admin
      admin_password: grafana123
  route:
    spec:
      tls:
        termination: edge
EOF
```

> 레이블 `dashboards: poc-grafana`와 인스턴스 이름 `poc-grafana`는 실제로 사용되는 값입니다 — [11-coo](../11-coo/11-coo.md)와 [12-grafana](../12-grafana/12-grafana.md)는 이 레이블을 `instanceSelector`로 정확히 참조하여 `GrafanaDatasource`/`GrafanaDashboard`를 등록하며, 라우트 이름(`<이름>-route`)도 접속 URL 출력에 그대로 사용됩니다.

### 접속 URL 확인

```bash
oc get route poc-grafana-route -n poc-grafana
```

---

## 참고 — 다른 Namespace의 Dashboard/Datasource

`GrafanaDashboard`와 `GrafanaDatasource`는 `instanceSelector.matchLabels.dashboards: poc-grafana` 레이블만으로 이 Grafana 인스턴스와 연결되므로, Grafana 인스턴스와 다른 namespace에 있어도 됩니다 (예: [11-coo](../11-coo/11-coo.md)는 `poc-monitoring`에 생성합니다). 이런 cross-namespace 리소스가 동기화되지 않는다면 Grafana CR에 namespaceSelector를 추가하여 Operator가 해당 namespace도 감시하도록 하세요:

```bash
oc patch grafana poc-grafana -n poc-grafana --type=merge -p '{
  "spec": {
    "namespaceSelector": {
      "matchLabels": {}
    }
  }
}'
```

또는 Operator를 단일 namespace가 아닌 `All namespaces on the cluster` 모드로 재설치하세요.
