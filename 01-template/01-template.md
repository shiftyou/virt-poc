# Custom VM Image Creation Guide for POC

Prepare a RHEL9-based custom VM image for use in OpenShift Virtualization POC testing.
Create a RHEL9 VM, register a subscription, install httpd, then export the PVC as qcow2
and register it as a golden image in the `openshift-virtualization-os-images` namespace.

```
RHEL9 base image (provided by OCP)
        │  VM creation (rhel9-vm)
        ▼
subscription-manager registration + httpd installation
        │  VM shutdown
        ▼
PVC → qcow2 (virtctl vmexport)
        │  virtctl image-upload
        ▼
PVC: rhel9-poc-golden  (openshift-virtualization-os-images)
        │  DataSource registration
        ▼
DataSource: rhel9-poc-golden  → VM creation available cluster-wide
```

---

## Step 1: Create RHEL9 VM

Create a RHEL9 VM using the OpenShift Virtualization UI or CLI.

### Create via CLI

```bash
# Create poc-vm-build namespace
oc new-project poc-vm-build

# Create a VM using the RHEL9 base template (using existing RHEL9 template)
oc process -n openshift rhel9-server-small \
  -p NAME=rhel9-vm \
  -p NAMESPACE=poc-vm-build | oc apply -f -
```

### Start VM and Connect

```bash
# Start VM
virtctl start rhel9-vm -n poc-vm-build

# Wait until VM is in Running state
oc wait vm/rhel9-vm -n poc-vm-build \
  --for=jsonpath='{.status.printableStatus}'=Running --timeout=300s

# VNC console access
virtctl vnc rhel9-vm -n poc-vm-build

# Or SSH (if SSH key was injected via cloud-init)
virtctl ssh cloud-user@rhel9-vm -n poc-vm-build
```

---

## Step 2: Register RHEL Subscription

Connect via VM console or SSH and register the Red Hat subscription.

```bash
# Register subscription (using Red Hat account)
subscription-manager register \
  --username <username> \
  --password <password> \
  --auto-attach

# Verify registration
subscription-manager status
subscription-manager list --installed
```

---

## Step 3: Install httpd and Configure POC Web Server

Run the following script inside the VM.

```bash
#!/bin/bash

# 1. Install required packages (httpd, firewalld, tar, wget)
echo ">>> [1/5] Installing base packages..."
dnf install -y httpd firewalld tar wget bash-completion

# 2. BMT web server configuration (index.html)
echo ">>> [4/5] Creating BMT information page..."
cat <<EOF > /var/www/html/index.html
<!DOCTYPE html>
<html>
<head>
    <meta charset="utf-8">
    <title>OpenShift BMT</title>
    <style>
        body { font-family: 'Segoe UI', sans-serif; text-align: center; margin-top: 80px; background-color: #f0f2f5; }
        .card { background: white; border-top: 8px solid #ee0000; display: inline-block; padding: 40px; border-radius: 12px; box-shadow: 0 10px 30px rgba(0,0,0,0.1); }
        h1 { color: #ee0000; margin-bottom: 5px; font-size: 2.2em; }
        h2 { color: #333; font-weight: 400; margin-top: 15px; border-top: 1px solid #eee; padding-top: 15px; }
        .info { margin-top: 20px; font-size: 0.9em; color: #666; }
    </style>
</head>
<body>
    <div class="card">
        <h1>OpenShift Virtualization PoC/BMT Test</h1>
        <h2>Node Hostname: $(hostname)</h2>
        <div class="info">CLI Tools Installed: oc, kubectl, virtctl</div>
    </div>
</body>
</html>
EOF

# 3. Enable services and open firewall
echo ">>> [5/5] Enabling services and configuring firewall..."
systemctl enable --now httpd firewalld
firewall-cmd --permanent --add-service=http
firewall-cmd --reload

echo "------------------------------------------------"
echo "✅ All configuration is complete!"
echo "1. Web access: http://$(hostname -I | awk '{print $1}')"
echo "2. oc version: $(oc version --client)"
echo "3. virtctl version: $(virtctl version --client | grep Client)"
echo "------------------------------------------------"
```

Verify installation:

```bash
# httpd service status
systemctl status httpd

# Verify web server response
curl http://localhost
```

---

## Step 4: Shut Down VM

Shut down the VM completely before extracting the image.

```bash
# Shutdown from inside the VM
sudo shutdown -h now
```

Or from outside:

```bash
virtctl stop rhel9-vm -n poc-vm-build

# Wait until fully stopped
oc wait vm/rhel9-vm -n poc-vm-build \
  --for=jsonpath='{.status.printableStatus}'=Stopped --timeout=120s
```

---

## Step 5: Export PVC as qcow2

Export the VM's root disk PVC to a local qcow2 file.

```bash
# Check PVC name
oc get pvc -n poc-vm-build

# Create VMExport
virtctl vmexport create rhel9-poc-export \
  --pvc=<rootdisk PVC name of rhel9-vm> \
  -n poc-vm-build

# Check Ready status
oc get vmexport rhel9-poc-export -n poc-vm-build

# Download qcow2
virtctl vmexport download rhel9-poc-export \
  --output=./vm-images/rhel9-poc-export.qcow2 \
  -n poc-vm-build

# Clean up VMExport
virtctl vmexport delete rhel9-poc-export -n poc-vm-build
```

> **Detailed guide**: Refer to [pvc-to-qcow2.md](pvc-to-qcow2.md) Part 1

---

## Step 6: Register as Golden Image

Upload the extracted qcow2 to the `openshift-virtualization-os-images` namespace and register a DataSource and Template.

```bash
# Load env.conf (to use variables like StorageClass)
source env.conf
```

### 6-1. DataVolume Upload

```bash
virtctl image-upload dv poc-golden \
  --image-path=vm-images/rhel9-poc-golden.qcow2 \
  --size=30Gi \
  --storage-class=${STORAGE_CLASS} \
  --access-mode=ReadWriteMany \
  --volume-mode=block \
  -n openshift-virtualization-os-images \
  --insecure \
  --force-bind
```

> If the StorageClass does not support `ReadWriteMany`, change to `--access-mode=ReadWriteOnce`

Verify upload completion:

```bash
oc get dv poc-golden -n openshift-virtualization-os-images
oc get pvc poc-golden -n openshift-virtualization-os-images
```

### 6-2. Register DataSource

```bash
cat <<'EOF' | oc apply -f -
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: poc
  namespace: openshift-virtualization-os-images
spec:
  source:
    pvc:
      name: poc-golden
      namespace: openshift-virtualization-os-images
EOF

# Verify registration
oc get datasource poc -n openshift-virtualization-os-images
```

### 6-3. Register VM Template

> **Important:** To use the Template from all namespaces, it must be created in the **`openshift` project**.
> If created in another namespace, it can only be used from that namespace.

```bash
cat <<'EOF' | oc apply -f -
apiVersion: template.openshift.io/v1
kind: Template
metadata:
  name: poc
  namespace: openshift
  labels:
    app.kubernetes.io/part-of: hyperconverged-cluster
    flavor.template.kubevirt.io/small: 'true'
    template.kubevirt.io/version: v0.31.1
    template.kubevirt.io/type: vm
    vm.kubevirt.io/template: rhel9-server-small
    app.kubernetes.io/component: templating
    app.kubernetes.io/managed-by: ssp-operator
    os.template.kubevirt.io/rhel9.0: 'true'
    os.template.kubevirt.io/rhel9.1: 'true'
    os.template.kubevirt.io/rhel9.2: 'true'
    os.template.kubevirt.io/rhel9.3: 'true'
    os.template.kubevirt.io/rhel9.4: 'true'
    os.template.kubevirt.io/rhel9.5: 'true'
    vm.kubevirt.io/template.namespace: openshift
    app.kubernetes.io/name: custom-templates
    workload.template.kubevirt.io/server: 'true'
  annotations:
    openshift.io/display-name: POC VM
    description: Template for Red Hat Enterprise Linux 9 VM or newer. A PVC with the RHEL disk image must be available.
    tags: 'hidden,kubevirt,virtualmachine,linux,rhel'
    iconClass: icon-rhel
    template.kubevirt.io/version: v1alpha1
    defaults.template.kubevirt.io/disk: rootdisk
    template.openshift.io/bindable: 'false'
    openshift.kubevirt.io/pronounceable-suffix-for-name-expression: 'true'
    name.os.template.kubevirt.io/rhel9.0: Red Hat Enterprise Linux 9.0 or higher
    name.os.template.kubevirt.io/rhel9.1: Red Hat Enterprise Linux 9.0 or higher
    name.os.template.kubevirt.io/rhel9.2: Red Hat Enterprise Linux 9.0 or higher
    name.os.template.kubevirt.io/rhel9.3: Red Hat Enterprise Linux 9.0 or higher
    name.os.template.kubevirt.io/rhel9.4: Red Hat Enterprise Linux 9.0 or higher
    name.os.template.kubevirt.io/rhel9.5: Red Hat Enterprise Linux 9.0 or higher
objects:
  - apiVersion: kubevirt.io/v1
    kind: VirtualMachine
    metadata:
      annotations:
        vm.kubevirt.io/validations: |
          [
            {
              "name": "minimal-required-memory",
              "path": "jsonpath::.spec.domain.memory.guest",
              "rule": "integer",
              "message": "This VM requires more memory.",
              "min": 1610612736
            }
          ]
      labels:
        app: '${NAME}'
        kubevirt.io/dynamic-credentials-support: 'true'
        vm.kubevirt.io/template: poc
        vm.kubevirt.io/template.revision: '1'
        vm.kubevirt.io/template.namespace: openshift
      name: '${NAME}'
    spec:
      dataVolumeTemplates:
        - apiVersion: cdi.kubevirt.io/v1beta1
          kind: DataVolume
          metadata:
            name: '${NAME}'
          spec:
            sourceRef:
              kind: DataSource
              name: '${DATA_SOURCE_NAME}'
              namespace: '${DATA_SOURCE_NAMESPACE}'
            storage:
              storageClassName: ${STORAGE_CLASS}
              resources:
                requests:
                  storage: 30Gi
      runStrategy: Halted
      template:
        metadata:
          annotations:
            vm.kubevirt.io/flavor: small
            vm.kubevirt.io/os: rhel9
            vm.kubevirt.io/workload: server
          labels:
            kubevirt.io/domain: '${NAME}'
            kubevirt.io/size: small
        spec:
          architecture: amd64
          domain:
            cpu:
              cores: 1
              sockets: 1
              threads: 1
            devices:
              disks:
                - disk:
                    bus: virtio
                  name: rootdisk
                - disk:
                    bus: virtio
                  name: cloudinitdisk
              interfaces:
                - masquerade: {}
                  model: virtio
                  name: default
              rng: {}
            features:
              smm:
                enabled: true
            firmware:
              bootloader:
                efi: {}
            memory:
              guest: 2Gi
          networks:
            - name: default
              pod: {}
          terminationGracePeriodSeconds: 180
          volumes:
            - dataVolume:
                name: '${NAME}'
              name: rootdisk
            - cloudInitNoCloud:
                userData: |-
                  #cloud-config
                  user: cloud-user
                  password: ${CLOUD_USER_PASSWORD}
                  chpasswd: { expire: False }
              name: cloudinitdisk
parameters:
  - name: NAME
    description: VM name
    generate: expression
    from: 'poc-[a-z0-9]{16}'
  - name: DATA_SOURCE_NAME
    description: Name of the DataSource to clone
    value: poc
  - name: DATA_SOURCE_NAMESPACE
    description: Namespace of the DataSource
    value: openshift-virtualization-os-images
  - name: CLOUD_USER_PASSWORD
    description: Randomized password for the cloud-init user cloud-user
    generate: expression
    from: '[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4}'
EOF

# Verify registration
oc get template poc -n openshift
```

### 6-4. Verify VM Creation from Template

```bash
# Check Template parameters
oc process --parameters -n openshift poc

# Test VM creation
oc process -n openshift poc | oc apply -n poc-test -f -
```

---

## Creating a New Template from an Existing VM Image in the Console

The easiest way to create a custom Template from an existing VM in the Console UI is to **clone an existing Template and modify it**.

1. Navigate to **Virtualization → Templates**
2. Click **Clone** from the right menu of the Template to base it on (e.g., `rhel9-server-small`)
3. Enter a clone name and set the namespace to **`openshift`** → Click **Clone**
4. Edit the cloned Template:
   - **Boot source** → Change DataSource to `poc` (`openshift-virtualization-os-images`)
   - Adjust CPU/Memory defaults
   - Edit Display name and description
5. **Save**

> Templates cloned in the Console immediately appear in **Virtualization → Catalog** for all projects.

---

## Reference

- `virtctl` installation: Download from OpenShift Console > `?` menu > **Command line tools**
- Full automation script: [`01-template.sh`](01-template.sh) — runs upload, DataSource, and Template in one step
- Check StorageClass: `oc get storageclass`
