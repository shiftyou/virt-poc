# 04-multitenancy: Multi-Tenant VM Environment

## Overview

Configure two namespaces as isolated tenants and deploy one VM per tenant.
Control per-user access permissions with RBAC to demonstrate a multi-tenant environment.

## User / Permission Configuration

```
┌────────────────────────────────────────────────────────────────────┐
│  poc-multitenancy-1                  poc-multitenancy-2            │
│  ┌──────────────────┐                ┌──────────────────┐          │
│  │  poc-mt-vm-1     │                │  poc-mt-vm-2     │          │
│  └──────────────────┘                └──────────────────┘          │
│                                                                    │
│  user1  ── admin  (can create VMs)   user3  ── admin              │
│  user2  ── view   (read-only)        user4  ── view               │
└────────────────────────────────────────────────────────────────────┘
```

| User  | Namespace           | Role  | Create VM  | Access other NS | Allowed operations |
|-------|---------------------|-------|------------|-----------------|-------------------|
| user1 | poc-multitenancy-1  | admin | **Yes**    | **No**          | Create/edit/delete VM, console access |
| user2 | poc-multitenancy-1  | view  | **No**     | **No**          | View VMs/resources only |
| user3 | poc-multitenancy-2  | admin | **Yes**    | **No**          | Create/edit/delete VM, console access |
| user4 | poc-multitenancy-2  | view  | **No**     | **No**          | View VMs/resources only |

- Default password: `Redhat1!`
- Identity Provider: HTPasswd (`poc-htpasswd`)
- VM template: `poc` (registered in 01-template step)

> Each user can only access the namespace assigned to them; other namespaces are completely inaccessible.

## Prerequisites

```bash
# Install htpasswd command (if not present)
dnf install -y httpd-tools

# Login with cluster-admin privileges
oc login -u system:admin

# Verify poc template is registered (01-template step must be complete)
oc get template poc -n openshift
```

## Execution

```bash
# Run configuration
./04-multitenancy.sh

# Cleanup
./04-multitenancy.sh --cleanup
```

## Step-by-Step Configuration

### 1. User Creation (HTPasswd)

Create 4 users with the `htpasswd` command and store them
in a Secret (`htpasswd-secret`) in the `openshift-config` namespace.

The HTPasswd Identity Provider is registered in the OAuth CR;
if an existing IDP is present, it is registered via append.

```bash
# Manual verification
oc get secret htpasswd-secret -n openshift-config
oc get oauth cluster -o jsonpath='{.spec.identityProviders[*].name}'
```

### 2. Namespace Creation

```bash
oc get namespace poc-multitenancy-1 poc-multitenancy-2
```

### 3. RBAC (RoleBinding)

Bind OpenShift built-in ClusterRoles using **RoleBinding** (namespace-scoped).
Since this is not a ClusterRoleBinding, there are no permissions on resources outside the namespace.

| ClusterRole | Permissions |
|-------------|-------------|
| `admin`     | Create/edit/delete all resources in namespace (cannot delete the namespace itself) |
| `view`      | View all resources in namespace only |

```
user1  RoleBinding(admin) → poc-multitenancy-1 only
user2  RoleBinding(view)  → poc-multitenancy-1 only
user3  RoleBinding(admin) → poc-multitenancy-2 only
user4  RoleBinding(view)  → poc-multitenancy-2 only
```

DataSource reference permissions (required for VM creation):
- user1, user3 → Add `view` permission to `openshift-virtualization-os-images` namespace

```bash
oc get rolebindings -n poc-multitenancy-1
oc get rolebindings -n poc-multitenancy-2
```

### 4. VM Creation

Create one `poc` template-based VM per namespace.

| VM Name       | Namespace           | CPU | Memory | Disk  | Template |
|---------------|---------------------|-----|--------|-------|----------|
| poc-mt-vm-1   | poc-multitenancy-1  | 1   | 2Gi    | 30Gi  | poc      |
| poc-mt-vm-2   | poc-multitenancy-2  | 1   | 2Gi    | 30Gi  | poc      |

cloud-init default account: `cloud-user / changeme`

## Verification

### CLI Permission Test

```bash
API=$(oc whoami --show-server)

# user1: poc-multitenancy-1 admin — can create VMs
oc login -u user1 -p 'Redhat1!' "$API"
oc get vm -n poc-multitenancy-1    # success
oc get vm -n poc-multitenancy-2    # denied (no permission)

# user2: poc-multitenancy-1 view — view only, cannot create VMs
oc login -u user2 -p 'Redhat1!' "$API"
oc get vm -n poc-multitenancy-1           # success (view)
oc get vm -n poc-multitenancy-2           # denied (no permission)
oc create -f vm.yaml -n poc-multitenancy-1  # denied (view only)

# user3: poc-multitenancy-2 admin — can create VMs
oc login -u user3 -p 'Redhat1!' "$API"
oc get vm -n poc-multitenancy-2    # success
oc get vm -n poc-multitenancy-1    # denied (no permission)

# user4: poc-multitenancy-2 view — view only, cannot create VMs
oc login -u user4 -p 'Redhat1!' "$API"
oc get vm -n poc-multitenancy-2           # success (view)
oc get vm -n poc-multitenancy-1           # denied (no permission)
oc create -f vm.yaml -n poc-multitenancy-2  # denied (view only)
```

### Console Access Test

1. Navigate to `https://<console-url>`
2. Select Identity Provider: `poc-htpasswd`
3. Login as each user
4. Check **Virtualization → VirtualMachines** menu
   - user1 / user3: Create button active, only their namespace shown
   - user2 / user4: View only, no create/delete buttons

### VM Console Access

```bash
# Admin users can access virtctl console
oc login -u user1 -p 'Redhat1!' "$API"
virtctl console poc-mt-vm-1 -n poc-multitenancy-1
# Login: cloud-user / changeme

oc login -u user3 -p 'Redhat1!' "$API"
virtctl console poc-mt-vm-2 -n poc-multitenancy-2
# Login: cloud-user / changeme
```

## Troubleshooting

### Cannot login

After registering the HTPasswd IDP, it takes 1-2 minutes for the authentication operator to restart.

```bash
# Check authentication operator status
oc get clusteroperator authentication

# Check oauth-openshift Pod restart
oc get pods -n openshift-authentication
```

### view user cannot see VMs

OpenShift Virtualization's view permissions are aggregated into the default `view` ClusterRole.
If the Virtualization operator is properly installed, VM viewing with the `view` role is possible.

```bash
# Check if kubevirt rules are included in view ClusterRole
oc get clusterrole view -o jsonpath='{.rules[*].resources}' | tr ' ' '\n' | grep -i virt
```

### DataSource not found error

Run the 01-template step first or specify the DataSource in env.conf.

```bash
# List available DataSources
oc get datasource -n openshift-virtualization-os-images

# Add to env.conf
DATASOURCE_NAME=rhel9
DATASOURCE_NS=openshift-virtualization-os-images
```

## Cleanup

```bash
./04-multitenancy.sh --cleanup
```

Cleanup items:
- VMs (poc-mt-vm-1, poc-mt-vm-2)
- Namespaces (poc-multitenancy-1, poc-multitenancy-2) and all internal resources
- User objects (user1~user4)
- Identity objects

> htpasswd secret and OAuth IDP settings may affect other users, so remove manually:
> ```bash
> oc delete secret htpasswd-secret -n openshift-config
> # Remove OAuth IDP: oc edit oauth cluster
> ```
