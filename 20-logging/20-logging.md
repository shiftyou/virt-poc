# OpenShift Audit Logging Lab

Configure the Audit Policy for the OpenShift APIServer,
and collect/store Audit logs through the OpenShift Logging Operator.

```
APIServer (kube-apiserver)
  │  Audit Log generation (WriteRequestBodies / AllRequestBodies)
  ▼
Vector Collector (DaemonSet)
  └─ ClusterLogForwarder
       ├─ audit   ─┐
       ├─ infra    ├─ LokiStack (log storage, using Garage S3)
       └─ app    ─┘
```

---

## Prerequisites

- Logged in to the cluster with `oc` command (cluster-admin privileges)
- (Optional) OpenShift Logging Operator installed — refer to `operators/`
- (Optional) Loki Operator installed — refer to `operators/`
- (Optional) Garage or ODF S3 backend — refer to Garage installation guide in `14-oadp.md`
- `19-logging.sh` execution complete

> Even without Logging Operator installed, **APIServer Audit Policy configuration** works standalone.

---

## Audit Profile Comparison

| Profile | Recorded Content | Log Volume | Recommended Use |
|--------|----------|----------|---------|
| `Default` | Metadata only (URL, Method, response code, user, time) | Minimum | Basic audit |
| `WriteRequestBodies` | Write request bodies (create/update/patch/delete) | Medium | **Recommended for production** |
| `AllRequestBodies` | All request/response bodies | Maximum | Detailed debugging |
| `None` | Disabled | - | Not recommended |

---

## Configuration Overview

| Resource | Namespace | Role |
|--------|------------|------|
| APIServer `cluster` | cluster-scoped | Audit Profile configuration |
| ClusterLogging `instance` | `openshift-logging` | Vector Collector management |
| LokiStack `logging-loki` | `openshift-logging` | Log storage (using S3) |
| ClusterLogForwarder `instance` | `openshift-logging` | Collection/forwarding pipeline |
| Secret `poc-far-credentials` | `openshift-logging` | Garage S3 credentials |

---

## Step 1 — APIServer Audit Policy

```bash
oc patch apiserver cluster --type=merge -p '{"spec":{"audit":{"profile":"WriteRequestBodies"}}}'

# Or apply with YAML
oc apply -f - <<EOF
apiVersion: config.openshift.io/v1
kind: APIServer
metadata:
  name: cluster
spec:
  audit:
    profile: WriteRequestBodies
EOF

# Check kube-apiserver rollout after applying (takes several minutes)
oc get co kube-apiserver
```

Check current configuration:

```bash
oc get apiserver cluster -o jsonpath='{.spec.audit.profile}'
```

---

## Step 2 — ClusterLogging (when Logging Operator is installed)

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

## Step 3 — LokiStack (when Loki Operator is installed)

A LokiStack using Garage S3 as storage.

### Create S3 Secret

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

## Step 4 — ClusterLogForwarder (including Audit)

### When using Loki

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

### When using default output (Loki not installed)

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

## Status Check

```bash
# Check Audit Policy
oc get apiserver cluster -o jsonpath='{.spec.audit.profile}'

# kube-apiserver rollout status
oc get co kube-apiserver

# ClusterLogging status
oc get clusterlogging -n openshift-logging

# ClusterLogForwarder status
oc get clusterlogforwarder -n openshift-logging

# LokiStack status
oc get lokistack -n openshift-logging

# Collector Pod status
oc get pods -n openshift-logging -l component=collector
```

---

## Check Audit Logs Directly

```bash
# Stream audit logs from master node
oc adm node-logs --role=master --path=kube-apiserver/ | grep audit | tail -20

# Check Collector logs
oc logs -n openshift-logging -l component=collector --tail=20

# Search audit events for a specific user
oc adm node-logs --role=master --path=kube-apiserver/ \
  | grep '"user":{"username":"system:admin"' | tail -10
```

---

## Troubleshooting

```bash
# Check kube-apiserver rollout progress
oc get co kube-apiserver
oc get pods -n openshift-kube-apiserver | grep kube-apiserver

# Check LokiStack events
oc describe lokistack logging-loki -n openshift-logging

# Collector error logs
oc logs -n openshift-logging -l component=collector --tail=50 | grep -i error

# ClusterLogForwarder status detail
oc describe clusterlogforwarder instance -n openshift-logging
```

---

## Rollback

```bash
# Reset Audit Policy (restore to Default)
oc patch apiserver cluster --type=merge -p '{"spec":{"audit":{"profile":"Default"}}}'

# Delete ClusterLogForwarder
oc delete clusterlogforwarder instance -n openshift-logging

# Delete ClusterLogging
oc delete clusterlogging instance -n openshift-logging

# Delete LokiStack
oc delete lokistack logging-loki -n openshift-logging

# Delete S3 Secret
oc delete secret logging-loki-s3 -n openshift-logging
```
