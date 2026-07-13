# Fence Agents Remediation (FAR) Operator Installation

## Overview

Fence Agents Remediation (FAR) is an Operator that automatically recovers from failure situations
by restarting (fencing) physical nodes via IPMI/BMC when a node failure occurs.

It is used together with the Node Health Check Operator to configure automatic node recovery.

---

## Prerequisites

- cluster-admin privileges
- IPMI/BMC access available on worker nodes
- Fence Agent information must be entered in setup.sh (FENCE_AGENT_IP, FENCE_AGENT_USER, FENCE_AGENT_PASS)

---

## Installation Methods

### Method 1: OpenShift Console (Web UI)

1. Navigate to **Operators > OperatorHub** menu
2. Search for `Fence Agents Remediation`
3. Select **Fence Agents Remediation Operator**
4. Click `Install`
5. Settings:
   - Installation mode: `All namespaces on the cluster`
   - Installed Namespace: `openshift-workload-availability`
6. Click `Install`

### Method 2: CLI (YAML)

```bash
# 1. Create Namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-workload-availability
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# 2. Create OperatorGroup
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: workload-availability
  namespace: openshift-workload-availability
spec:
  targetNamespaces:
    - openshift-workload-availability
EOF

# 3. Create Subscription
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: fence-agents-remediation-operator
  namespace: openshift-workload-availability
spec:
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  name: fence-agents-remediation-operator
  channel: "stable"
EOF
```

---

## Verify Installation

```bash
# Check CSV status
oc get csv -n openshift-workload-availability | grep fence

# Check Pod status
oc get pods -n openshift-workload-availability | grep fence
```

---

## FAR Configuration

After installation, refer to the guide in the `01-environment/far/` directory.

```bash
cd 01-environment/far
./apply.sh
```

---

## Troubleshooting

```bash
# Check FAR Operator logs
oc logs -n openshift-workload-availability deployment/fence-agents-remediation-operator-controller-manager

# Check FenceAgentsRemediation status
oc get fenceagentsremediation -A

# IPMI connectivity test (from node)
ipmitool -I lanplus -H <BMC_IP> -U <USER> -P <PASS> chassis power status
```
