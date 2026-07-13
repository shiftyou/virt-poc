# VM Liveness Probe Practice

Configure KubeVirt's Liveness / Readiness Probe on a VM to practice
automatic restart and traffic blocking based on HTTP server responses inside the VM.

```
VM (poc-liveness-vm)
  │
  ├─ livenessProbe  — httpGet :1500  → automatically restart VM on failure
  └─ readinessProbe — httpGet :1500  → block Service traffic on failure
         │
         └─ virt-probe (KubeVirt internal agent)
              └─ direct HTTP request to VMI internal IP
```

---

## KubeVirt Probe Operation

Unlike Kubernetes Pod Probes, KubeVirt VM Probes use the **virt-probe** process
to connect directly to the VMI (VirtualMachineInstance) internal IP.

| Item | Pod Probe | KubeVirt VM Probe |
|------|-----------|-------------------|
| Executor | kubelet | virt-probe (KubeVirt) |
| Target | container port | VMI internal IP:port |
| Supported types | HTTP / TCP / Exec | HTTP / TCP / Exec |
| On Liveness failure | container restart | VM restart (VirtualMachine CR) |
| On Readiness failure | exclude from Service endpoints | exclude from Service endpoints |

> **Why port 1500**
> In pod network masquerade environments, direct access to port 80 by virt-probe may be restricted.
> Run an HTTP server on port 1500 inside the VM to configure Probe.

---

## Prerequisites

- `01-template` complete — poc Template and DataSource registered
- `07-liveness-probe.sh` execution complete

```bash
oc get template poc -n openshift
oc get namespace poc-liveness-probe
```

---

## Probe Configuration

```yaml
spec:
  template:
    spec:
      readinessProbe:
        httpGet:
          port: 1500
        initialDelaySeconds: 120   # Wait for VM boot
        periodSeconds: 20
        timeoutSeconds: 10
        failureThreshold: 3
        successThreshold: 3
      livenessProbe:
        httpGet:
          port: 1500
        initialDelaySeconds: 120
        periodSeconds: 20
        timeoutSeconds: 10
        failureThreshold: 3        # 3 consecutive failures → VM restart
```

### Parameter Description

| Parameter | Value | Description |
|-----------|-------|-------------|
| `initialDelaySeconds` | 120 | Wait time after VM boot before first Probe |
| `periodSeconds` | 20 | Probe execution interval |
| `timeoutSeconds` | 10 | Response timeout |
| `failureThreshold` | 3 | Action taken when consecutive failures exceed threshold |
| `successThreshold` | 3 | (Readiness) Ready when consecutive successes exceed threshold |

---

## Practice Steps

### 1. VM startup and console access

```bash
# Check VM status
oc get vm,vmi -n poc-liveness-probe

# Console access
virtctl console poc-liveness-vm -n poc-liveness-probe
```

### 2. Run HTTP server inside the VM

The poc golden image has **httpd (port 80)** installed.
Additionally run a **port 1500 HTTP server** for Probe testing.

```bash
# Run inside the VM (after logging in as cloud-user)
python3 -m http.server 1500 &

# Or socket-based simple server (if python is not installed)
while true; do echo -e "HTTP/1.1 200 OK\r\n\r\nOK" | nc -l -p 1500 -q 1; done &
```

Verify server:
```bash
curl http://localhost:1500
```

### 3. Check Probe status

From outside the VM (OCP node):

```bash
# Check VMI conditions (ReadyIsFalse / AgentConnected etc.)
oc get vmi poc-liveness-vm -n poc-liveness-probe \
  -o jsonpath='{range .status.conditions[*]}{.type}: {.status}{"\n"}{end}'

# Check Probe configuration
oc get vmi poc-liveness-vm -n poc-liveness-probe \
  -o jsonpath='{.spec.livenessProbe}'

# Check events
oc describe vmi poc-liveness-vm -n poc-liveness-probe | grep -A 5 Events
```

---

## Liveness Probe Failure Simulation

### Stop HTTP server → verify VM auto-restart

```bash
# 1. Stop HTTP server from VM console
virtctl console poc-liveness-vm -n poc-liveness-probe
# Inside VM:
kill $(pgrep -f "http.server")

# 2. Monitor VM status externally (restart after failureThreshold * periodSeconds = 60 seconds)
oc get vmi poc-liveness-vm -n poc-liveness-probe -w

# 3. Check VM restart events
oc get events -n poc-liveness-probe \
  --sort-by='.lastTimestamp' | tail -10
```

Expected results:
```
NAME               AGE   PHASE     IP           NODENAME
poc-liveness-vm    2m    Running   10.128.x.x   worker-0
poc-liveness-vm    3m    Failed    <none>        worker-0   ← Probe failed
poc-liveness-vm    3m    Running   10.128.x.x   worker-0   ← auto-restarted
```

---

## Readiness Probe Failure Simulation

```bash
# 1. Stop HTTP server (same as above)

# 2. Check VMI Ready status change
oc get vmi poc-liveness-vm -n poc-liveness-probe \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'
# → False (Service traffic blocked when Readiness fails)

# 3. Verify Ready recovery after restarting HTTP server
# Inside VM:
python3 -m http.server 1500 &
```

---

## TCP Probe Example

Method that only checks TCP port connectivity instead of HTTP:

```bash
oc patch vm poc-liveness-vm -n poc-liveness-probe --type=merge -p '{
  "spec": {
    "template": {
      "spec": {
        "livenessProbe": {
          "tcpSocket": {
            "port": 22
          },
          "initialDelaySeconds": 120,
          "periodSeconds": 20,
          "failureThreshold": 3
        }
      }
    }
  }
}'
```

> VM is considered healthy while SSH (port 22) responds.

---

## Exec Probe Example

Method that judges status based on command execution results inside the VM:

```bash
oc patch vm poc-liveness-vm -n poc-liveness-probe --type=merge -p '{
  "spec": {
    "template": {
      "spec": {
        "livenessProbe": {
          "exec": {
            "command": ["cat", "/tmp/healthy"]
          },
          "initialDelaySeconds": 120,
          "periodSeconds": 20,
          "failureThreshold": 3
        }
      }
    }
  }
}'
```

Inside the VM:
```bash
# Indicate healthy state
touch /tmp/healthy

# Simulate failure
rm /tmp/healthy
```

---

## Remove Probe

```bash
oc patch vm poc-liveness-vm -n poc-liveness-probe --type=merge -p '{
  "spec": {
    "template": {
      "spec": {
        "livenessProbe": null,
        "readinessProbe": null
      }
    }
  }
}'
```

---

## Rollback

```bash
# Stop and delete VM
virtctl stop poc-liveness-vm -n poc-liveness-probe
oc delete vm poc-liveness-vm -n poc-liveness-probe

# Delete namespace
oc delete namespace poc-liveness-probe
```

---

## Reference

- [KubeVirt Liveness and Readiness Probes](https://kubevirt.io/user-guide/virtual_machines/liveness_and_readiness_probes/)
- [OpenShift Virtualization — VM Health Checks](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/virtualization/monitoring-vms#virt-about-readiness-liveness-probes_virt-monitoring-vm-health)
