# Worker Node Removal and Rejoin Lab

Practice removing a worker node from an OpenShift cluster and rejoining it by restarting kubelet.

```
kubelet stop
  └─ Node NotReady
       └─ oc delete node
            └─ Removed from cluster
                 └─ kubelet start
                      └─ Re-register with API server using existing certificate
                           └─ CSR approval → Node Ready
```

---

## How It Works

### kubelet and Node Rejoin

On an OpenShift worker node (RHCOS), kubelet handles communication with the cluster.

| Situation | Behavior |
|------|------|
| kubelet stopped | Node status → `NotReady`. Node object remains in the cluster |
| `oc delete node` | Only deletes the node object from etcd. The actual node (OS) remains intact |
| kubelet restarted | Re-registration request to API server using existing certificate (`/var/lib/kubelet/pki/`) |
| CSR approval | New node object created → `Ready` |

### Certificate Flow

kubelet uses two types of certificates.

| Certificate | Path | Purpose |
|--------|------|------|
| Client certificate | `/var/lib/kubelet/pki/kubelet-client-current.pem` | Authenticates kubelet itself to the API server |
| Server certificate | `/var/lib/kubelet/pki/kubelet-server-current.pem` | Used when the API server connects to kubelet |

Even if the node object is deleted, these certificate files remain on the node's disk.
Since kubelet uses these certificates to re-register with the API server on restart, **a bootstrap token is not required, unlike when adding a node for the first time**.

Two CSRs are generated during the re-registration process.

```
csr-xxxxx   system:node:<nodename>         (client certificate renewal)
csr-yyyyy   system:serviceaccount:...      (server certificate renewal)
```

---

## Prerequisites

- 2 or more worker nodes (remaining nodes must accommodate workloads while one is being removed)
- `oc` login (cluster-admin)
- SSH access to the target node (`ssh core@<node-ip>`)

---

## Procedure

### Step 1. Check Node Status and Select Target

```bash
# Check all nodes
oc get nodes -o wide

# Check worker nodes only
oc get nodes -l node-role.kubernetes.io/worker
```

Check the IP address of the target node (e.g., `worker-2`).

```bash
TARGET_NODE="worker-2"
NODE_IP=$(oc get node "$TARGET_NODE" \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
echo "SSH: ssh core@${NODE_IP}"
```

---

### Step 2. Cordon + Drain

Set the node to Unschedulable and move running Pods/VMs to other nodes.

```bash
# Cordon — block new Pod scheduling
oc adm cordon $TARGET_NODE

# Drain — move existing Pods/VMs
oc adm drain $TARGET_NODE \
  --delete-emptydir-data \
  --ignore-daemonsets \
  --force \
  --timeout=300s
```

> VMs (VirtualMachineInstances) are moved to other nodes via Live Migration.
> `--ignore-daemonsets` ignores DaemonSet Pods (node-exporter, etc.).

---

### Step 3. Stop kubelet → Verify Node NotReady

SSH into the target node and stop kubelet.

```bash
# SSH into the node
ssh core@${NODE_IP}

# Stop kubelet (run inside the node)
sudo systemctl stop kubelet

# Check kubelet status
sudo systemctl status kubelet
```

Check the node status change in the cluster.

```bash
# Transitions to NotReady after approximately 40 seconds
watch oc get nodes
```

Expected output:
```
NAME       STATUS     ROLES    AGE   VERSION
master-0   Ready      master   10d   v1.30.x
master-1   Ready      master   10d   v1.30.x
master-2   Ready      master   10d   v1.30.x
worker-0   Ready      worker   10d   v1.30.x
worker-1   Ready      worker   10d   v1.30.x
worker-2   NotReady   worker   10d   v1.30.x   ← kubelet stopped
```

---

### Step 4. Delete Node Object

```bash
# Delete node object from the cluster
oc delete node $TARGET_NODE
```

> At this point, the node OS is still running.
> Only the node information in Kubernetes/OpenShift etcd is deleted.

```bash
# Verify the node has disappeared from the list
oc get nodes
```

---

### Step 5. Restart kubelet → Rejoin

Restart kubelet on the node.

```bash
# On the node (SSH)
sudo systemctl start kubelet

# Check kubelet logs
sudo journalctl -u kubelet -f --since "1 min ago"
```

You can see the API server registration attempt in the kubelet logs.

```
...msg="Attempting to register node" node="worker-2"
...msg="Successfully registered node" node="worker-2"
```

---

### Step 6. Approve CSR

CSRs are generated within 1-2 minutes after kubelet restarts.

```bash
# Check CSR list
oc get csr

# Approve all Pending CSRs at once
oc get csr --no-headers | awk '/Pending/ {print $1}' | xargs oc adm certificate approve
```

Expected output:
```
NAME        AGE   SIGNERNAME                                    REQUESTOR              CONDITION
csr-abc12   30s   kubernetes.io/kube-apiserver-client-kubelet   system:node:worker-2   Pending
csr-def34   45s   kubernetes.io/kubelet-serving                 system:node:worker-2   Pending
```

After approval:
```
certificatesigningrequest.certificates.k8s.io/csr-abc12 approved
certificatesigningrequest.certificates.k8s.io/csr-def34 approved
```

---

### Step 7. Verify Ready + Uncordon

```bash
# Verify node Ready (takes 1-2 minutes)
watch oc get nodes

# Uncordon after verifying Ready
oc adm uncordon $TARGET_NODE

# Check final status
oc get nodes -o wide
```

Expected output:
```
NAME       STATUS   ROLES    AGE   VERSION
master-0   Ready    master   10d   v1.30.x
master-1   Ready    master   10d   v1.30.x
master-2   Ready    master   10d   v1.30.x
worker-0   Ready    worker   10d   v1.30.x
worker-1   Ready    worker   10d   v1.30.x
worker-2   Ready    worker   10d   v1.30.x   ← rejoin complete
```

---

## When CSRs Are Not Generated

OpenShift 4.x has a `machine-approver` that automatically approves CSRs under certain conditions.
If CSRs are not visible, they may have already been automatically approved.

```bash
# Check recently approved CSRs
oc get csr | grep Approved

# Check machine-approver logs
oc logs -n openshift-cluster-machine-approver \
  deploy/machine-approver --tail=30
```

---

## Troubleshooting

### When Node Does Not Recover from NotReady

```bash
# Check kubelet status (node SSH)
sudo systemctl status kubelet

# Check kubelet logs for errors
sudo journalctl -u kubelet --since "5 min ago" | grep -i error

# Verify certificate files exist
ls -la /var/lib/kubelet/pki/
```

### Still NotReady After CSR Approval

```bash
# Check node events
oc describe node $TARGET_NODE | tail -20

# Check CNI (network plugin) status
oc get pods -n openshift-ovn-kubernetes -o wide | grep $TARGET_NODE
```

### When Node Does Not Appear in Cluster

```bash
# Check API server connectivity (node SSH)
curl -k https://<api-server>:6443/healthz

# Check kubelet config
sudo cat /etc/kubernetes/kubelet.conf
```

---

## Rollback

If node rejoin fails, reprovision the node through the Machine Config Operator.

```bash
# Force re-apply MachineConfig (node SSH)
sudo touch /run/machine-config-daemon-force

# Or check MachineConfigPool status
oc get mcp
oc describe mcp worker
```
