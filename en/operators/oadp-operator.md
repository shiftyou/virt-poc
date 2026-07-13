# OADP (OpenShift API for Data Protection) Operator Installation

## Overview

OADP is an Operator that provides backup/restore for applications and VMs in OpenShift.
It operates based on Velero and uses S3-compatible storage (Garage or ODF MCG) as the backup storage.

---

## Prerequisites

- cluster-admin privileges
- S3-compatible storage (Garage or ODF MCG)

---

## Installation Methods

### Method 1: OpenShift Console (Web UI)

1. Navigate to **Operators > OperatorHub** menu
2. Search for `OADP` or `OpenShift API for Data Protection`
3. Select **OADP Operator**
4. Click `Install`
5. Settings:
   - Update channel: `stable-1.4`
   - Installation mode: `A specific namespace on the cluster`
   - Installed Namespace: `openshift-adp` (default)
6. Click `Install` and wait for completion

### Method 2: CLI (YAML)

```bash
# 1. Create Namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-adp
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# 2. Create OperatorGroup
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: redhat-oadp-operator
  namespace: openshift-adp
spec:
  targetNamespaces:
    - openshift-adp
EOF

# 3. Create Subscription
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: redhat-oadp-operator
  namespace: openshift-adp
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: redhat-oadp-operator
  channel: "stable-1.4"
EOF
```

---

## Verify Installation

```bash
# Check Operator installation status
oc get csv -n openshift-adp

# Check OADP Pod status
oc get pods -n openshift-adp

# Check Velero
oc get deployment velero -n openshift-adp
```

---

## DataProtectionApplication (DPA) Configuration

After installation, running `12-oadp/12-oadp.sh` will automatically configure DPA and BackupStorageLocation.

```bash
cd 12-oadp
./12-oadp.sh
```

---

## Troubleshooting

```bash
# Check OADP Operator logs
oc logs -n openshift-adp deployment/openshift-adp-controller-manager

# Check Velero logs
oc logs -n openshift-adp deployment/velero

# Check BackupStorageLocation status
oc get backupstoragelocation -n openshift-adp
```
