# Migration Toolkit for Virtualization (MTV) Operator Installation

## Overview

MTV (Migration Toolkit for Virtualization) is an Operator that migrates VMs from environments
such as VMware vSphere, Red Hat Virtualization (RHV), and OpenStack to OpenShift Virtualization.
It supports cold migration and warm migration, and allows migration plans to be created and executed from the Console UI.

```
VMware vSphere / RHV / OpenStack
        │  MTV migration
        ▼
OpenShift Virtualization (KubeVirt)
```

---

## Prerequisites

- cluster-admin privileges
- OpenShift Virtualization Operator installation complete (refer to `openshift-virtualization-operator.md`)
- For VMware migration: VDDK (Virtual Disk Development Kit) image prepared

---

## Installation Methods

### Method 1: OpenShift Console (Web UI)

1. Navigate to **Operators > OperatorHub** menu
2. Search for `Migration Toolkit for Virtualization`
3. Select **Migration Toolkit for Virtualization**
4. Click `Install`
5. Settings:
   - Update channel: `release-v2.7` (select latest channel)
   - Installation mode: `All namespaces on the cluster`
   - Installed Namespace: `openshift-mtv`
6. Click `Install` and wait for completion
7. After installation, **Create ForkliftController instance**:
   - Operators > Installed Operators > Migration Toolkit for Virtualization
   - **ForkliftController** tab > Click `Create ForkliftController`
   - Create with default values

### Method 2: CLI (YAML)

```bash
# 1. Create Namespace
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-mtv
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# 2. Create OperatorGroup
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: migration
  namespace: openshift-mtv
spec:
  targetNamespaces:
    - openshift-mtv
EOF

# 3. Create Subscription
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: mtv-operator
  namespace: openshift-mtv
spec:
  channel: release-v2.7
  name: mtv-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# 4. Wait for Operator installation to complete
oc wait csv -n openshift-mtv \
  -l operators.coreos.com/mtv-operator.openshift-mtv \
  --for=jsonpath='{.status.phase}'=Succeeded \
  --timeout=5m

# 5. Create ForkliftController instance
oc apply -f - <<'EOF'
apiVersion: forklift.konveyor.io/v1beta1
kind: ForkliftController
metadata:
  name: forklift-controller
  namespace: openshift-mtv
spec:
  olm_managed: true
EOF
```

---

## Verify Installation

```bash
# Check Operator installation status
oc get csv -n openshift-mtv | grep mtv

# Check ForkliftController status
oc get forkliftcontroller -n openshift-mtv

# Check all Pod statuses
oc get pods -n openshift-mtv

# Check MTV Console plugin activation
oc get consolePlugin forklift-console-plugin
```

---

## VMware Migration Preparation (VDDK)

A VDDK image is required when migrating from VMware.

```bash
# 1. Download VDDK from VMware site
#    https://developer.vmware.com/web/sdk/8.0/vddk

# 2. Build VDDK image and push to internal registry
# Dockerfile example:
cat > Dockerfile.vddk <<'EOF'
FROM registry.access.redhat.com/ubi8/ubi-minimal
COPY vmware-vix-disklib-distrib /vmware-vix-disklib-distrib
RUN mkdir -p /opt
ENTRYPOINT ["cp", "-r", "/vmware-vix-disklib-distrib", "/opt"]
EOF

# 3. Build and Push
VDDK_IMAGE="image-registry.openshift-image-registry.svc:5000/openshift/vddk:latest"
podman build -f Dockerfile.vddk -t ${VDDK_IMAGE} .
podman push ${VDDK_IMAGE}

# 4. Register VDDK image in MTV
oc patch forkliftcontroller forklift-controller -n openshift-mtv \
  --type=merge \
  -p "{\"spec\":{\"vddk_job_image\":\"${VDDK_IMAGE}\"}}"
```

---

## Migration Procedure Overview

```bash
# 1. Register Provider (VMware vCenter)
#    Migration > Providers > Add Provider

# 2. Create Network Mapping
#    Migration > NetworkMaps > Create NetworkMap

# 3. Create Storage Mapping
#    Migration > StorageMaps > Create StorageMap

# 4. Create and run Migration Plan
#    Migration > Plans > Create Plan

# Check Provider list
oc get providers -n openshift-mtv

# Check Migration Plan status
oc get migrationplans -n openshift-mtv

# Check VM migration status
oc get migrations -n openshift-mtv
```

---

## Troubleshooting

```bash
# Check ForkliftController events
oc describe forkliftcontroller -n openshift-mtv forklift-controller

# Check Operator logs
oc logs -n openshift-mtv deployment/forklift-operator

# Individual component logs
oc logs -n openshift-mtv deployment/forklift-controller
oc logs -n openshift-mtv deployment/forklift-api

# Check VMware Provider connection status
oc get providers -n openshift-mtv
oc describe provider <provider-name> -n openshift-mtv
```
