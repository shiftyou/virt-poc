# Red Hat build of Perses (via Cluster Observability Operator)

## Overview

The [Grafana Operator](grafana-operator.md) used elsewhere in this POC is installed from the **Community Operators** catalog (`source: community-operators`) — it is not covered by a Red Hat subscription, so Red Hat support cannot be engaged if it breaks.

Red Hat's supported path for custom dashboards on OpenShift is the **Cluster Observability Operator (COO)** — itself a Red Hat-shipped operator — combined with its `Monitoring` `UIPlugin`, which enables the **Red Hat build of Perses**: a Red Hat-maintained, downstream build of the CNCF [Perses](https://perses.dev/) project. It renders dashboards natively inside the OpenShift web console under **Observe → Dashboards (Perses)**, uses native Kubernetes RBAC instead of a separate Grafana user database, and integrates with RHACM for multi-cluster views.

## Perses vs. the Grafana Operator path in this POC

| | [Grafana Operator](grafana-operator.md) (`12-grafana.md` → "Using the Grafana Operator") | COO + Red Hat build of Perses (this document) |
|---|---|---|
| Support | Community Operator — **not** covered by Red Hat subscription | Fully supported — COO and Perses both ship as Red Hat components |
| Console integration | Separate Grafana UI + Route, outside the OpenShift console | Native tab inside the console (**Observe → Dashboards (Perses)**) |
| Access control | Grafana's own admin/viewer users (`admin` / configured password) | Native Kubernetes RBAC (`ClusterRole` / `RoleBinding`) |
| Multi-cluster (RHACM) | Not integrated | Built-in ACM alerting/dashboards support in the same `UIPlugin` |
| Dashboard format | Grafana JSON (`GrafanaDashboard` CR) | `PersesDashboard` CR (`perses.dev/v1alpha2`); Grafana JSON import is supported |
| Maturity | GA, stable schema for years | GA as of COO 1.5 (OpenShift 4.15+); `perses.dev/v1alpha2` schema is still evolving between releases |

Use this path when Red Hat support coverage or native RBAC matters more than the maturity of Grafana's dashboard ecosystem. If you need Grafana-specific features (its full alerting engine, community panel plugins, an existing Grafana-based workflow), the [Grafana Operator](grafana-operator.md) path remains available — the two are not mutually exclusive.

---

## Prerequisites

- cluster-admin access
- OpenShift 4.15 or later
- Cluster Observability Operator 1.5 or later, installed **from the Red Hat catalog** (OperatorHub → "Cluster Observability Operator", `source: redhat-operators` — not `community-operators`). This is the same COO instance used by [11-coo](../11-coo/11-coo.md); no separate installation is needed if that lab has already run.

Verify:

```bash
oc get csv --all-namespaces | grep cluster-observability-operator
oc get crd uiplugins.observability.openshift.io
```

---

## 1. Enable the Perses dashboarding UI

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

This deploys a Perses server (managed by the Perses Operator, bundled inside COO) into `openshift-cluster-observability-operator` and adds a **Dashboards (Perses)** page under **Observe** in the web console. Do a hard refresh of the console tab afterward — the nav menu is built once per page session.

```bash
oc get uiplugin monitoring -o jsonpath='{.status.conditions}'
oc get pods -n openshift-cluster-observability-operator | grep -i perses
```

---

## 2. Register the in-cluster Thanos Querier as a datasource

Register it cluster-wide (`PersesGlobalDatasource`) so any namespace's `PersesDashboard` can use it, the same role `thanos-querier-datasource` plays for Grafana in [12-grafana.md](../12-grafana/12-grafana.md):

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

Verify:

```bash
oc get persesglobaldatasource thanos-querier-global-datasource
```

> **If queries return "Unauthorized"**: Thanos Querier requires a bearer-token identity carrying the `cluster-monitoring-view` ClusterRole — the same requirement the Grafana Operator path works around with a dedicated ServiceAccount (see `12-grafana.sh` step 3/3). Create an equivalent one for Perses:
> ```bash
> oc create serviceaccount poc-perses-view -n openshift-cluster-observability-operator
> oc create clusterrolebinding perses-cluster-monitoring-view \
>   --clusterrole=cluster-monitoring-view \
>   --serviceaccount=openshift-cluster-observability-operator:poc-perses-view
> oc create token poc-perses-view -n openshift-cluster-observability-operator --duration=8760h
> ```
> Attach the resulting token to the datasource as a Perses secret and reference it from `spec.config.plugin.spec.proxy.spec.secret`. The exact secret field/shape can shift between COO releases since `perses.dev/v1alpha2` is still evolving — check `oc explain persesglobaldatasource.spec.config.plugin.spec.proxy.spec` on your cluster, or the [Perses datasource documentation](https://perses.dev/perses/docs/api/datasource/), to confirm the field your installed version expects.

---

## 3. Deploy the VM dashboards

### Option A (recommended) — import the existing Grafana dashboards

The Perses console UI ships a **Grafana import tool** that converts Grafana dashboard JSON into a `PersesDashboard` CR automatically — reuse the dashboards this POC already defines in [12-grafana.sh](../12-grafana/12-grafana.sh) instead of hand-authoring new Perses YAML:

1. Run `12-grafana/12-grafana.sh` at least once, or pull the JSON directly:
   ```bash
   oc get configmap poc-vm-overview-dashboard -n openshift-config-managed \
     -o jsonpath='{.data.poc-vm-overview\.json}' > poc-vm-overview.json
   oc get configmap poc-ocpv-overview-dashboard -n openshift-config-managed \
     -o jsonpath='{.data.poc-ocpv-overview\.json}' > poc-ocpv-overview.json
   ```
2. In the console: **Observe → Dashboards (Perses) → Create → Import** → paste the JSON → pick the target namespace → **Import**.
3. The console converts it into a `PersesDashboard` custom resource in that namespace.

### Option B — author a PersesDashboard directly

A minimal, single-panel example (illustrative — extend with more panels/layout entries following the same pattern for CPU/Memory/Network/Storage, mirroring [Dashboard 1](../12-grafana/12-grafana.md#dashboard-1-kubevirt-vm-overall-status-poc-vm-overview)'s PromQL):

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

Field names under `spec.config.panels`/`spec.config.layouts` follow the upstream [Perses dashboard schema](https://perses.dev/perses/docs/api/dashboard/) — COO simply wraps it inside `spec.config`. Run `oc explain persesdashboard.spec.config` to check the schema shipped by your COO version before extending this.

---

## 4. Grant view access (RBAC)

Perses dashboards use native Kubernetes RBAC instead of a Grafana user database. The operator ships `persesdashboard-viewer-role` / `persesdashboard-editor-role` / `persesdatasource-viewer-role` / `persesdatasource-editor-role` / `persesglobaldatasource-viewer-role` / `persesglobaldatasource-editor-role` ClusterRoles; bind the viewer roles per namespace:

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

Replace `system:authenticated` with a specific user or group before using this outside a POC.

---

## 5. Access

**Administrator perspective → Observe → Dashboards (Perses)** → select the dashboard from the dropdown.

---

## Rollback

```bash
oc delete uiplugin monitoring
oc delete persesglobaldatasource thanos-querier-global-datasource --ignore-not-found
oc delete rolebinding poc-perses-dashboard-viewer -n openshift-cluster-observability-operator --ignore-not-found
oc delete clusterrolebinding perses-cluster-monitoring-view --ignore-not-found
oc delete serviceaccount poc-perses-view -n openshift-cluster-observability-operator --ignore-not-found
```
