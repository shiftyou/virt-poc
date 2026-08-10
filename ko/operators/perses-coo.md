# Red Hat build of Perses (Cluster Observability Operator 기반)

## 개요

이 POC의 다른 곳에서 사용하는 [Grafana Operator](grafana-operator.md)는 **Community Operators** 카탈로그(`source: community-operators`)에서 설치됩니다 — Red Hat 구독 지원 대상이 아니므로, 문제가 발생해도 Red Hat 기술지원을 받을 수 없습니다.

OpenShift에서 Red Hat이 공식 지원하는 커스텀 대시보드 경로는 **Cluster Observability Operator (COO)** — 이 자체가 Red Hat이 제공하는 Operator입니다 — 와 그 `Monitoring` `UIPlugin`이 활성화하는 **Red Hat build of Perses**입니다. 이는 CNCF [Perses](https://perses.dev/) 프로젝트를 Red Hat이 유지보수하는 다운스트림 빌드로, OpenShift 웹 콘솔의 **Observe → Dashboards (Perses)** 안에서 대시보드를 네이티브로 렌더링하며, 별도의 Grafana 사용자 DB 대신 Kubernetes 네이티브 RBAC를 사용하고, RHACM과 통합되어 멀티 클러스터 화면을 제공합니다.

## 이 POC 안에서 Grafana Operator 경로와의 비교

| | [Grafana Operator](grafana-operator.md) (`12-grafana.md` → "Grafana Operator 사용") | COO + Red Hat build of Perses (본 문서) |
|---|---|---|
| 지원 여부 | Community Operator — Red Hat 구독 지원 **대상 아님** | 완전 지원 — COO와 Perses 모두 Red Hat 컴포넌트로 제공됨 |
| 콘솔 통합 | 별도의 Grafana UI + Route, OpenShift 콘솔 밖에 위치 | 콘솔 내부 네이티브 탭 (**Observe → Dashboards (Perses)**) |
| 접근 제어 | Grafana 자체 admin/viewer 사용자 (`admin` / 설정한 비밀번호) | Kubernetes 네이티브 RBAC (`ClusterRole` / `RoleBinding`) |
| 멀티 클러스터(RHACM) | 통합 없음 | 동일한 `UIPlugin`에서 ACM 알림/대시보드 내장 지원 |
| 대시보드 포맷 | Grafana JSON (`GrafanaDashboard` CR) | `PersesDashboard` CR (`perses.dev/v1alpha2`); Grafana JSON import 지원 |
| 성숙도 | GA, 수년간 안정적인 스키마 | COO 1.5(OpenShift 4.15+)부터 GA; `perses.dev/v1alpha2` 스키마는 버전 간 계속 변화 중 |

Grafana 생태계의 성숙도보다 Red Hat 지원 범위나 네이티브 RBAC가 더 중요한 경우 이 경로를 사용하세요. Grafana 고유 기능(완전한 Alerting 엔진, 커뮤니티 패널 플러그인, 기존 Grafana 기반 워크플로우)이 필요하다면 [Grafana Operator](grafana-operator.md) 경로도 계속 사용할 수 있습니다 — 두 방식은 상호 배타적이지 않습니다.

---

## 사전 요구사항

- cluster-admin 권한
- OpenShift 4.15 이상
- Cluster Observability Operator 1.5 이상, **Red Hat 카탈로그**에서 설치됨(OperatorHub → "Cluster Observability Operator", `source: redhat-operators` — `community-operators`가 아님). [11-coo](../11-coo/11-coo.md)에서 사용하는 것과 동일한 COO 인스턴스이므로, 해당 랩을 이미 실행했다면 별도 설치가 필요 없습니다.

확인:

```bash
oc get csv --all-namespaces | grep cluster-observability-operator
oc get crd uiplugins.observability.openshift.io
```

---

## 1. Perses 대시보드 UI 활성화

```bash
oc apply -f - <<'EOF'
apiVersion: observability.openshift.io/v1alpha1
kind: UIPlugin
metadata:
  name: monitoring
spec:
  type: Monitoring
  monitoring:
    perses:
      enabled: true
EOF
```

이 설정은 (COO에 내장된 Perses Operator가 관리하는) Perses 서버를 `openshift-cluster-observability-operator`에 배포하고, 웹 콘솔의 **Observe** 메뉴 아래에 **Dashboards (Perses)** 페이지를 추가합니다. 적용 후 콘솔 탭을 강력 새로고침하세요 — 내비게이션 메뉴는 페이지 세션당 한 번만 구성됩니다.

```bash
oc get uiplugin monitoring -o jsonpath='{.status.conditions}'
oc get pods -n openshift-cluster-observability-operator | grep -i perses
```

---

## 2. 클러스터 내장 Thanos Querier를 데이터소스로 등록

클러스터 전체 범위(`PersesGlobalDatasource`)로 등록하여 어떤 namespace의 `PersesDashboard`에서도 사용할 수 있게 합니다 — [12-grafana.md](../12-grafana/12-grafana.md)에서 Grafana용 `thanos-querier-datasource`가 하는 역할과 동일합니다:

```bash
oc apply -f - <<'EOF'
apiVersion: perses.dev/v1alpha2
kind: PersesGlobalDatasource
metadata:
  name: thanos-querier-global-datasource
spec:
  config:
    display:
      name: "Thanos Querier"
    default: true
    plugin:
      kind: "PrometheusDatasource"
      spec:
        proxy:
          kind: HTTPProxy
          spec:
            url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
  client:
    tls:
      enable: true
      caCert:
        type: file
        certPath: /ca/service-ca.crt
EOF
```

확인:

```bash
oc get persesglobaldatasource thanos-querier-global-datasource
```

> **쿼리가 "Unauthorized"를 반환하는 경우**: Thanos Querier는 `cluster-monitoring-view` ClusterRole을 가진 Bearer 토큰 identity를 요구합니다 — Grafana Operator 경로가 전용 ServiceAccount로 우회하는 것과 동일한 제약입니다(`12-grafana.sh` 3/3 단계 참조). Perses용으로도 동일하게 구성하세요:
> ```bash
> oc create serviceaccount poc-perses-view -n openshift-cluster-observability-operator
> oc create clusterrolebinding perses-cluster-monitoring-view \
>   --clusterrole=cluster-monitoring-view \
>   --serviceaccount=openshift-cluster-observability-operator:poc-perses-view
> oc create token poc-perses-view -n openshift-cluster-observability-operator --duration=8760h
> ```
> 발급된 토큰을 Perses secret으로 만들어 `spec.config.plugin.spec.proxy.spec.secret`에서 참조하세요. `perses.dev/v1alpha2` 스키마는 아직 계속 변화하고 있어 정확한 secret 필드/형태가 COO 릴리스마다 달라질 수 있습니다 — 설치된 클러스터에서 `oc explain persesglobaldatasource.spec.config.plugin.spec.proxy.spec`를 실행하거나 [Perses datasource 문서](https://perses.dev/perses/docs/api/datasource/)를 참고하여 설치된 버전이 기대하는 필드를 확인하세요.

---

## 3. VM 대시보드 배포

### 방법 A (권장) — 기존 Grafana 대시보드 Import

Perses 콘솔 UI는 Grafana 대시보드 JSON을 `PersesDashboard` CR로 자동 변환하는 **Grafana import 도구**를 제공합니다 — 새로 Perses YAML을 작성하는 대신, 이 POC가 [12-grafana.sh](../12-grafana/12-grafana.sh)에 이미 정의해둔 대시보드를 재사용하세요:

1. `12-grafana/12-grafana.sh`를 한 번 이상 실행하거나, JSON을 직접 추출합니다:
   ```bash
   oc get configmap poc-vm-overview-dashboard -n openshift-config-managed \
     -o jsonpath='{.data.poc-vm-overview\.json}' > poc-vm-overview.json
   oc get configmap poc-ocpv-overview-dashboard -n openshift-config-managed \
     -o jsonpath='{.data.poc-ocpv-overview\.json}' > poc-ocpv-overview.json
   ```
2. 콘솔에서: **Observe → Dashboards (Perses) → Create → Import** → JSON 붙여넣기 → 대상 namespace 선택 → **Import**.
3. 콘솔이 해당 namespace에 `PersesDashboard` 커스텀 리소스를 생성합니다.

### 방법 B — PersesDashboard 직접 작성

단일 패널로 구성된 최소 예시입니다(예시용 — CPU/Memory/Network/Storage 패널은 [Dashboard 1](../12-grafana/12-grafana.md#dashboard-1-kubevirt-vm-overall-status-poc-vm-overview)의 PromQL을 참고하여 동일한 패턴으로 panels/layouts 항목을 추가하세요):

```bash
oc apply -f - <<'EOF'
apiVersion: perses.dev/v1alpha2
kind: PersesDashboard
metadata:
  name: poc-vm-running-count
  namespace: openshift-cluster-observability-operator
spec:
  config:
    display:
      name: "KubeVirt VM Running Count"
    duration: 1h
    panels:
      vmRunning:
        kind: Panel
        spec:
          display:
            name: "Running VMs — Cluster Total"
          plugin:
            kind: StatChart
            spec: {}
          queries:
            - kind: TimeSeriesQuery
              spec:
                plugin:
                  kind: PrometheusTimeSeriesQuery
                  spec:
                    query: sum(kubevirt_vmi_phase_count{phase=~"Running|running"}) or vector(0)
    layouts:
      - kind: Grid
        spec:
          items:
            - x: 0
              y: 0
              width: 6
              height: 4
              content:
                $ref: "#/spec/config/panels/vmRunning"
EOF
```

`spec.config.panels`/`spec.config.layouts` 하위 필드명은 upstream [Perses dashboard 스키마](https://perses.dev/perses/docs/api/dashboard/)를 그대로 따르며, COO는 이를 `spec.config`로 감싸기만 합니다. 확장하기 전에 설치된 COO 버전이 제공하는 스키마를 `oc explain persesdashboard.spec.config`로 확인하세요.

---

## 4. 조회 권한 부여 (RBAC)

Perses 대시보드는 Grafana 사용자 DB 대신 Kubernetes 네이티브 RBAC를 사용합니다. Operator는 `persesdashboard-viewer-role` / `persesdashboard-editor-role` / `persesdatasource-viewer-role` / `persesdatasource-editor-role` / `persesglobaldatasource-viewer-role` / `persesglobaldatasource-editor-role` ClusterRole을 제공하며, namespace별로 viewer 역할을 바인딩하면 됩니다:

```bash
oc apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: poc-perses-dashboard-viewer
  namespace: openshift-cluster-observability-operator
subjects:
  - kind: Group
    name: system:authenticated
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: persesdashboard-viewer-role
  apiGroup: rbac.authorization.k8s.io
EOF
```

POC 범위를 벗어나 사용할 때는 `system:authenticated` 대신 특정 사용자나 그룹으로 교체하세요.

---

## 5. 접속

**Administrator perspective → Observe → Dashboards (Perses)** → 드롭다운에서 대시보드 선택.

---

## 롤백

```bash
oc delete uiplugin monitoring
oc delete persesglobaldatasource thanos-querier-global-datasource --ignore-not-found
oc delete rolebinding poc-perses-dashboard-viewer -n openshift-cluster-observability-operator --ignore-not-found
oc delete clusterrolebinding perses-cluster-monitoring-view --ignore-not-found
oc delete serviceaccount poc-perses-view -n openshift-cluster-observability-operator --ignore-not-found
```
