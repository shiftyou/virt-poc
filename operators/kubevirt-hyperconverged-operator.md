# OpenShift Virtualization Operator Installation

## Overview

OpenShift Virtualization (CNV, Container Native Virtualization) is an Operator that enables
running and managing virtual machines (VMs) on OpenShift on the same platform as containers.
It operates based on KubeVirt and provides features such as VM creation, migration, snapshots, and backup.

---

## Prerequisites

- cluster-admin privileges
- OpenShift 4.12 or higher
- Worker node CPU virtualization support (Intel VT-x / AMD-V)

```bash
# Check worker node virtualization support
oc get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.capacity.cpu

# Check directly on the node
oc debug node/<worker-node> -- chroot /host grep -m1 -E 'vmx|svm' /proc/cpuinfo
```

---

## Installation Methods

### Method 1: OpenShift Console (Web UI)

1. Navigate to **Operators > OperatorHub** menu
2. Search for `OpenShift Virtualization`
3. Select **OpenShift Virtualization**
4. Click `Install`
5. Settings:
   - Update channel: `stable`
   - Installation mode: `All namespaces on the cluster`
   - Installed Namespace: `openshift-cnv`
6. Click `Install` and wait for completion
7. After installation, **Create HyperConverged instance**:
   - Operators > Installed Operators > OpenShift Virtualization
   - **HyperConverged** tab > Click `Create HyperConverged`
   - Create with default values

### Method 2: CLI (YAML)

```bash
# 1. Create Namespace
oc apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-cnv
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# 2. Create OperatorGroup
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kubevirt-hyperconverged-group
  namespace: openshift-cnv
spec:
  targetNamespaces:
    - openshift-cnv
EOF

# 3. Create Subscription
oc apply -f - <<'EOF'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: hco-operatorhub
  namespace: openshift-cnv
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: kubevirt-hyperconverged
  channel: stable
EOF

# 4. Wait for Operator installation to complete
oc wait csv -n openshift-cnv \
  -l operators.coreos.com/kubevirt-hyperconverged.openshift-cnv \
  --for=jsonpath='{.status.phase}'=Succeeded \
  --timeout=5m

# 5. Create HyperConverged instance
oc apply -f - <<'EOF'
apiVersion: hco.kubevirt.io/v1beta1
kind: HyperConverged
metadata:
  name: kubevirt-hyperconverged
  namespace: openshift-cnv
EOF
```

---

## Verify Installation

```bash
# Check Operator installation status
oc get csv -n openshift-cnv | grep kubevirt

# Check HyperConverged status (Available: True)
oc get hco -n openshift-cnv kubevirt-hyperconverged

# Check all Pod statuses
oc get pods -n openshift-cnv

# Check virtualization feature readiness
oc get infrastructure.config.openshift.io cluster -o jsonpath='{.status.platform}'
```

---

## Post-Installation Verification

```bash
# Check if VM creation is possible (default Template list)
oc get template -n openshift | grep rhel

# Check virtctl CLI download path
oc get ConsoleCLIDownload virtctl-clidownloads-kubevirt-hyperconverged \
  -o jsonpath='{.spec.links[0].href}'

# Virtualization feature status
oc get kubevirt -n openshift-cnv
```

---

## Troubleshooting

```bash
# Check HyperConverged events
oc describe hco -n openshift-cnv kubevirt-hyperconverged

# Check Operator logs
oc logs -n openshift-cnv deployment/hco-operator

# Check individual component status
oc get kubevirt,cdi,networkaddonsconfig,ssp -n openshift-cnv

# When node virtualization is not supported
oc get nodes -l kubevirt.io/schedulable=true
```
