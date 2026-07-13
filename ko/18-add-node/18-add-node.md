# Worker 노드 제거 및 재합류 랩

OpenShift 클러스터에서 worker 노드를 제거하고, kubelet을 재시작하여 재합류시키는 실습입니다.

```
kubelet 중지
  └─ Node NotReady
       └─ oc delete node
            └─ 클러스터에서 제거
                 └─ kubelet 시작
                      └─ 기존 인증서로 API 서버에 재등록
                           └─ CSR 승인 → Node Ready
```

---

## 동작 원리

### kubelet과 노드 재합류

OpenShift worker 노드(RHCOS)에서 kubelet은 클러스터와의 통신을 담당합니다.

| 상황 | 동작 |
|------|------|
| kubelet 중지 | 노드 상태 → `NotReady`. 노드 오브젝트는 클러스터에 남아있음 |
| `oc delete node` | etcd에서 노드 오브젝트만 삭제. 실제 노드(OS)는 그대로 유지 |
| kubelet 재시작 | 기존 인증서(`/var/lib/kubelet/pki/`)를 사용하여 API 서버에 재등록 요청 |
| CSR 승인 | 새 노드 오브젝트 생성 → `Ready` |

### 인증서 흐름

kubelet은 두 종류의 인증서를 사용합니다.

| 인증서 | 경로 | 용도 |
|--------|------|------|
| Client 인증서 | `/var/lib/kubelet/pki/kubelet-client-current.pem` | kubelet 자체를 API 서버에 인증 |
| Server 인증서 | `/var/lib/kubelet/pki/kubelet-server-current.pem` | API 서버가 kubelet에 연결할 때 사용 |

노드 오브젝트가 삭제되더라도 이 인증서 파일들은 노드의 디스크에 그대로 남아있습니다.
kubelet이 재시작 시 이 인증서를 사용하여 API 서버에 재등록하므로, **처음 노드를 추가할 때와 달리 bootstrap token이 필요하지 않습니다**.

재등록 과정에서 두 개의 CSR이 생성됩니다.

```
csr-xxxxx   system:node:<nodename>         (client 인증서 갱신)
csr-yyyyy   system:serviceaccount:...      (server 인증서 갱신)
```

---

## 사전 요구사항

- 2개 이상의 worker 노드 (1개를 제거하는 동안 나머지 노드가 워크로드를 수용할 수 있어야 함)
- `oc` 로그인 (cluster-admin)
- 대상 노드에 SSH 접근 가능 (`ssh core@<node-ip>`)

---

## 절차

### Step 1. 노드 상태 확인 및 대상 선택

```bash
# 전체 노드 확인
oc get nodes -o wide

# worker 노드만 확인
oc get nodes -l node-role.kubernetes.io/worker
```

대상 노드의 IP 주소를 확인합니다 (예: `worker-2`).

```bash
TARGET_NODE="worker-2"
NODE_IP=$(oc get node "$TARGET_NODE" \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
echo "SSH: ssh core@${NODE_IP}"
```

---

### Step 2. Cordon + Drain

노드를 Unschedulable 상태로 설정하고 실행 중인 Pod/VM을 다른 노드로 이동합니다.

```bash
# Cordon — 새로운 Pod 스케줄링 차단
oc adm cordon $TARGET_NODE

# Drain — 기존 Pod/VM 이동
oc adm drain $TARGET_NODE \
  --delete-emptydir-data \
  --ignore-daemonsets \
  --force \
  --timeout=300s
```

> VM(VirtualMachineInstance)은 Live Migration을 통해 다른 노드로 이동됩니다.
> `--ignore-daemonsets`는 DaemonSet Pod(node-exporter 등)를 무시합니다.

---

### Step 3. kubelet 중지 → Node NotReady 확인

대상 노드에 SSH로 접속하여 kubelet을 중지합니다.

```bash
# 노드에 SSH 접속
ssh core@${NODE_IP}

# kubelet 중지 (노드 내부에서 실행)
sudo systemctl stop kubelet

# kubelet 상태 확인
sudo systemctl status kubelet
```

클러스터에서 노드 상태 변경을 확인합니다.

```bash
# 약 40초 후 NotReady로 전환
watch oc get nodes
```

예상 출력:
```
NAME       STATUS     ROLES    AGE   VERSION
master-0   Ready      master   10d   v1.30.x
master-1   Ready      master   10d   v1.30.x
master-2   Ready      master   10d   v1.30.x
worker-0   Ready      worker   10d   v1.30.x
worker-1   Ready      worker   10d   v1.30.x
worker-2   NotReady   worker   10d   v1.30.x   ← kubelet 중지됨
```

---

### Step 4. 노드 오브젝트 삭제

```bash
# 클러스터에서 노드 오브젝트 삭제
oc delete node $TARGET_NODE
```

> 이 시점에서 노드 OS는 여전히 실행 중입니다.
> Kubernetes/OpenShift etcd의 노드 정보만 삭제됩니다.

```bash
# 목록에서 노드가 사라졌는지 확인
oc get nodes
```

---

### Step 5. kubelet 재시작 → 재합류

노드에서 kubelet을 재시작합니다.

```bash
# 노드에서 (SSH)
sudo systemctl start kubelet

# kubelet 로그 확인
sudo journalctl -u kubelet -f --since "1 min ago"
```

kubelet 로그에서 API 서버 등록 시도를 확인할 수 있습니다.

```
...msg="Attempting to register node" node="worker-2"
...msg="Successfully registered node" node="worker-2"
```

---

### Step 6. CSR 승인

kubelet 재시작 후 1-2분 이내에 CSR이 생성됩니다.

```bash
# CSR 목록 확인
oc get csr

# Pending 상태의 모든 CSR 일괄 승인
oc get csr --no-headers | awk '/Pending/ {print $1}' | xargs oc adm certificate approve
```

예상 출력:
```
NAME        AGE   SIGNERNAME                                    REQUESTOR              CONDITION
csr-abc12   30s   kubernetes.io/kube-apiserver-client-kubelet   system:node:worker-2   Pending
csr-def34   45s   kubernetes.io/kubelet-serving                 system:node:worker-2   Pending
```

승인 후:
```
certificatesigningrequest.certificates.k8s.io/csr-abc12 approved
certificatesigningrequest.certificates.k8s.io/csr-def34 approved
```

---

### Step 7. Ready 확인 + Uncordon

```bash
# 노드 Ready 확인 (1-2분 소요)
watch oc get nodes

# Ready 확인 후 Uncordon
oc adm uncordon $TARGET_NODE

# 최종 상태 확인
oc get nodes -o wide
```

예상 출력:
```
NAME       STATUS   ROLES    AGE   VERSION
master-0   Ready    master   10d   v1.30.x
master-1   Ready    master   10d   v1.30.x
master-2   Ready    master   10d   v1.30.x
worker-0   Ready    worker   10d   v1.30.x
worker-1   Ready    worker   10d   v1.30.x
worker-2   Ready    worker   10d   v1.30.x   ← 재합류 완료
```

---

## CSR이 생성되지 않는 경우

OpenShift 4.x에는 특정 조건에서 CSR을 자동 승인하는 `machine-approver`가 있습니다.
CSR이 보이지 않으면 이미 자동 승인되었을 수 있습니다.

```bash
# 최근 승인된 CSR 확인
oc get csr | grep Approved

# machine-approver 로그 확인
oc logs -n openshift-cluster-machine-approver \
  deploy/machine-approver --tail=30
```

---

## 문제 해결

### 노드가 NotReady에서 복구되지 않는 경우

```bash
# kubelet 상태 확인 (노드 SSH)
sudo systemctl status kubelet

# kubelet 로그에서 에러 확인
sudo journalctl -u kubelet --since "5 min ago" | grep -i error

# 인증서 파일 존재 확인
ls -la /var/lib/kubelet/pki/
```

### CSR 승인 후에도 여전히 NotReady인 경우

```bash
# 노드 이벤트 확인
oc describe node $TARGET_NODE | tail -20

# CNI (네트워크 플러그인) 상태 확인
oc get pods -n openshift-ovn-kubernetes -o wide | grep $TARGET_NODE
```

### 노드가 클러스터에 나타나지 않는 경우

```bash
# API 서버 연결 확인 (노드 SSH)
curl -k https://<api-server>:6443/healthz

# kubelet 설정 확인
sudo cat /etc/kubernetes/kubelet.conf
```

---

## 롤백

노드 재합류에 실패하면 Machine Config Operator를 통해 노드를 다시 프로비저닝합니다.

```bash
# MachineConfig 강제 재적용 (노드 SSH)
sudo touch /run/machine-config-daemon-force

# 또는 MachineConfigPool 상태 확인
oc get mcp
oc describe mcp worker
```
