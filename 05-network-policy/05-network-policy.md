# NetworkPolicy / MultiNetworkPolicy Practice

Deploy VMs in two namespaces and control traffic with network policies.
When running `04-network-policy.sh`, select one of two methods.

---

## Method Comparison

| Item | NetworkPolicy | MultiNetworkPolicy |
|------|--------------|-------------------|
| API | `networking.k8s.io/v1` | `k8s.cni.cncf.io/v1beta1` |
| Target | pod network (eth0, masquerade) | secondary NIC (eth1) |
| Network | Linux Bridge (02-network method 1/3) | OVN Localnet (02-network method 2/4) |
| Namespace | `poc-network-policy-1/2` | `poc-multi-network-policy-1/2` |
| NAD | `poc-bridge-nad` | `poc-localnet-nad` |
| Prerequisites | NNCP Linux Bridge | NNCP OVN Localnet + `useMultiNetworkPolicy: true` |

> **Key difference**: NetworkPolicy applies only to pod network (eth0).
> Traffic through Linux Bridge secondary NIC (eth1) is outside the scope of NetworkPolicy.
> MultiNetworkPolicy directly controls secondary NIC (eth1).

---

## Method 1. NetworkPolicy (Linux Bridge)

```
poc-network-policy-1                      poc-network-policy-2
┌────────────────────┐            ┌────────────────────┐
│  poc-vm-1          │            │  poc-vm-2          │
│  eth0 ──────────── │──✗ deny────│ ──────── eth0      │
│  (NetworkPolicy    │            │    NetworkPolicy)   │
│  eth1: br1 bypass) │            │  (eth1: br1 bypass) │
└────────────────────┘            └────────────────────┘
         │   after allow-from-ns1-vm-ip applied (eth0)   ▲
         └─────────────────────────────────────────────┘
```

### Prerequisites

- 02-network method 1 (Linux Bridge) or 3 (Linux Bridge + VLAN) complete

### Applied policies

```yaml
# Default Deny All
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: poc-network-policy-1
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

```yaml
# Allow Same Namespace
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: poc-network-policy-1
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector: {}
  egress:
    - to:
        - podSelector: {}
```

### Check policies

```bash
oc get networkpolicy -n poc-network-policy-1
oc get networkpolicy -n poc-network-policy-2
```

---

## Method 2. MultiNetworkPolicy (OVN Localnet)

```
poc-multi-network-policy-1                poc-multi-network-policy-2
┌────────────────────┐            ┌────────────────────┐
│  poc-vm-1          │            │  poc-vm-2          │
│  eth0 (pod net)    │            │  eth0 (pod net)    │
│  eth1 ─────────── │──✗ deny────│ ─────────── eth1   │
│  (MultiNetPolicy   │            │   MultiNetPolicy)  │
│   OVN Localnet)    │            │   OVN Localnet)    │
└────────────────────┘            └────────────────────┘
         │   after allow-from-ns1-vm-ip applied (eth1)    ▲
         └─────────────────────────────────────────────┘
```

### Prerequisites

- 02-network method 2 (OVN Localnet) or 4 (OVN Localnet + VLAN) complete
- `useMultiNetworkPolicy: true` enabled (script handles automatically)

### Enable MultiNetworkPolicy

```bash
# Script runs this automatically, but to enable manually:
oc patch network.operator.openshift.io cluster --type=merge \
  -p '{"spec":{"useMultiNetworkPolicy":true}}'

# Verify enabled
oc get network.operator.openshift.io cluster \
  -o jsonpath='{.spec.useMultiNetworkPolicy}'
```

### Applied policies

MultiNetworkPolicy uses the `k8s.v1.cni.cncf.io/policy-for` annotation to specify which NAD (secondary NIC) to apply to.

```yaml
# Default Deny All (eth1 basis)
apiVersion: k8s.cni.cncf.io/v1beta1
kind: MultiNetworkPolicy
metadata:
  name: default-deny-all
  namespace: poc-multi-network-policy-1
  annotations:
    k8s.v1.cni.cncf.io/policy-for: poc-multi-network-policy-1/poc-localnet-nad
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

```yaml
# Allow Same Namespace (eth1 basis)
apiVersion: k8s.cni.cncf.io/v1beta1
kind: MultiNetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: poc-multi-network-policy-1
  annotations:
    k8s.v1.cni.cncf.io/policy-for: poc-multi-network-policy-1/poc-localnet-nad
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector: {}
  egress:
    - to:
        - podSelector: {}
```

### Check policies

```bash
oc get multinetworkpolicy -n poc-multi-network-policy-1
oc get multinetworkpolicy -n poc-multi-network-policy-2
```

---

## VM IP Assignment (cloud-init networkData)

`04-network-policy.sh` automatically configures a static IP on eth1 via cloud-init during VM creation.

| VM | Namespace | eth1 IP |
|----|-----------|---------|
| poc-vm-1 (NS1) | poc-network-policy-1 / poc-multi-network-policy-1 | `SECONDARY_IP_PREFIX`.11/24 |
| poc-vm-2 (NS2) | poc-network-policy-2 / poc-multi-network-policy-2 | `SECONDARY_IP_PREFIX`.12/24 |

> `SECONDARY_IP_PREFIX` default: `192.168.100` (can be changed in env.conf)

```yaml
# cloud-init networkData format (version 2)
version: 2
ethernets:
  eth1:
    dhcp4: false
    addresses:
      - 192.168.100.11/24       # NS1 VM
    gateway4: 192.168.100.1
    nameservers:
      addresses:
        - 8.8.8.8
```

## VM Status and IP Verification

```bash
# Method 1 (NetworkPolicy) — uses pod network IP
NS1="poc-network-policy-1"
NS2="poc-network-policy-2"

# Method 2 (MultiNetworkPolicy) — uses secondary NIC IP
NS1="poc-multi-network-policy-1"
NS2="poc-multi-network-policy-2"

# VM running status
oc get vmi -n $NS1
oc get vmi -n $NS2

# Method 1: pod network IP (eth0)
oc get vmi -n $NS1 \
  -o jsonpath='{.items[0].status.interfaces[0].ipAddress}'

# Method 2: secondary NIC IP (eth1, OVN Localnet)
oc get vmi -n $NS1 \
  -o jsonpath='{.items[0].status.interfaces[?(@.name=="secondary")].ipAddress}'
```

---

## Allow Specific IP from NS1 to NS2

### Method 1 — Modify netpol-allow-from-ns1-ip.yaml and apply

```bash
# Check NS1 VM IP (eth0)
NS1_VM_IP=$(oc get vmi -n poc-network-policy-1 \
  -o jsonpath='{.items[0].status.interfaces[0].ipAddress}')
echo "NS1 VM IP: ${NS1_VM_IP}"

# Replace 192.168.0.1/32 → actual IP/32 in netpol-allow-from-ns1-ip.yaml and apply
sed -i "s|192.168.0.1/32|${NS1_VM_IP}/32|" netpol-allow-from-ns1-ip.yaml
oc apply -f netpol-allow-from-ns1-ip.yaml
```

### Method 2 — Modify multi-netpol-allow-from-ns1-ip.yaml and apply

```bash
# Check NS1 VM secondary NIC IP (eth1)
NS1_VM_IP=$(oc get vmi -n poc-multi-network-policy-1 \
  -o jsonpath='{.items[0].status.interfaces[?(@.name=="secondary")].ipAddress}')
echo "NS1 VM secondary IP: ${NS1_VM_IP}"

# Replace IP in multi-netpol-allow-from-ns1-ip.yaml and apply
sed -i "s|192.168.0.1/32|${NS1_VM_IP}/32|" multi-netpol-allow-from-ns1-ip.yaml
oc apply -f multi-netpol-allow-from-ns1-ip.yaml
```

---

## Communication Test

```bash
# Access NS1 VM console (change namespace based on method)
virtctl console poc-vm-1 -n poc-network-policy-1
# or
virtctl console poc-vm-1 -n poc-multi-network-policy-1

# Ping test from inside VM to NS2 VM
# Before applying allow-from-ns1-vm-ip → fail
# After applying allow-from-ns1-vm-ip → success
ping -c 3 <NS2_VM_IP>
curl -v http://<NS2_VM_IP>
```

---

## Troubleshooting

### MultiNetworkPolicy not working

```bash
# Check useMultiNetworkPolicy is enabled
oc get network.operator.openshift.io cluster \
  -o jsonpath='{.spec.useMultiNetworkPolicy}'

# Check network operator status
oc get network.operator.openshift.io cluster \
  -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}'

# Check MultiNetworkPolicy controller Pod
oc get pods -n openshift-multus | grep multi-networkpolicy

# Check policy annotation (verify NAD name mismatch)
oc get multinetworkpolicy -n poc-multi-network-policy-1 -o yaml \
  | grep "policy-for"
```

### NetworkPolicy not applying to secondary NIC

NetworkPolicy applies only to pod network (eth0).
To control traffic through Linux Bridge secondary NIC (eth1), use MultiNetworkPolicy (Method 2).

---

## Rollback

```bash
# Method 1
oc delete networkpolicy --all -n poc-network-policy-1
oc delete networkpolicy --all -n poc-network-policy-2
oc delete vm --all -n poc-network-policy-1
oc delete vm --all -n poc-network-policy-2
oc delete namespace poc-network-policy-1 poc-network-policy-2

# Method 2
oc delete multinetworkpolicy --all -n poc-multi-network-policy-1
oc delete multinetworkpolicy --all -n poc-multi-network-policy-2
oc delete vm --all -n poc-multi-network-policy-1
oc delete vm --all -n poc-multi-network-policy-2
oc delete namespace poc-multi-network-policy-1 poc-multi-network-policy-2
```
