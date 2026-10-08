# REDEPLOY — recreate the SNO cluster that ran on tsunami (2026-10-07)

This records the exact configuration of the single-node OpenShift cluster that
was provisioned via CAPOA on `tsunami`, so it can be reproduced after the host
is torn down to its original state. Pair with `SETUP-tsunami-fedora44.md`
(networking) and `AI-RUNBOOK.md` (operations).

## What was deployed

| Item | Value |
|------|-------|
| Topology | SNO (1 control-plane node, acts as master+worker) |
| OpenShift | 4.20.0 (kube v1.33.5) |
| RHCOS | 9.6.20250925-0 (Plow); image = `rhcos-4.20.0-x86_64-nutanix.x86_64.qcow2` |
| Cluster name | `test-sno` (namespace `test-capi`) |
| Node | `bmh-vm-01`, provider id `metal3://test-capi/bmh-vm-01/test-sno-gkcnv` |
| Node IP / VIPs | `192.168.222.31` (api, api-int, *.apps all point here) |
| Base domain | `lab.home` → api.test-sno.lab.home |
| BMC | sushy Redfish `http://192.168.222.1:8000/redfish/v1/Systems/<uuid>` |
| Manifest | `examples/sno-example.yaml.j2` (rendered by the e2e) |

> The spoke admin kubeconfig/password live in the management cluster as secrets
> `test-sno-admin-kubeconfig` / `test-sno-admin-password` (namespace
> `test-capi`). They are **regenerated on every install** — do not archive them;
> after redeploy, read them fresh from the new management cluster.

## Prerequisites on the (clean) host

1. Fedora host, podman (rootful), libvirt/qemu, kind, ansible — installed by the
   prepare playbook.
2. `~/e2e-sno.env` with `export PULLSECRET=<base64>` (mode 600).
3. The repo on branch `e2e-sno-podman` (carries the podman-provider fixes).

## Redeploy steps

```bash
cd ~/devel/cluster-api-provider-openshift-assisted
git checkout e2e-sno-podman

export KIND_EXPERIMENTAL_PROVIDER=podman
export CLUSTER_TOPOLOGY=sno
export NUMBER_OF_NODES=1
# optional, these are the defaults that produced the above cluster:
# export OPENSHIFT_VERSION=4.20.0
# export RHCOS_IMAGE_URL=https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/4.20/4.20.0/rhcos-4.20.0-x86_64-nutanix.x86_64.qcow2
source ~/e2e-sno.env            # PULLSECRET

# 1. prepare host (deps + podman host-networking). Idempotent.
ansible-playbook --become -i test/playbooks/inventories/local_host.yaml \
  test/playbooks/prepare.yaml

# 2. run the e2e (or use ~/e2e-sno-tsunami/bootstrap.sh which wraps this)
ansible-playbook --become -i test/playbooks/inventories/local_host.yaml \
  test/playbooks/run_test.yaml
```

`run_test.yaml` now applies the `host_networking` role itself (after kind_setup
and again after bmh_setup), so a clean run opens the firewall paths
automatically — no manual FIX-ALL needed. If you hit a stalled deploy, consult
the decision tree in `AI-RUNBOOK.md`.

## Verify success

```bash
sudo KIND_EXPERIMENTAL_PROVIDER=podman kind get kubeconfig --name capi-baremetal-provider > /tmp/kc
export KUBECONFIG=/tmp/kc
kubectl -n test-capi get cluster,machine,aci,bmh        # machine Running, aci adding-hosts, bmh provisioned

# reach the new SNO cluster:
kubectl -n test-capi get secret test-sno-admin-kubeconfig -o jsonpath='{.data.kubeconfig}' | base64 -d > /tmp/spoke.kc
KUBECONFIG=/tmp/spoke.kc kubectl get nodes,clusteroperators
```

Expected end state: ACI `Completed=True` / stateInfo `adding-hosts: Cluster is
installed`, spoke node Ready (control-plane,master,worker), all cluster
operators Available.

## Connect from a remote laptop

The spoke API is `https://api.test-sno.lab.home:6443` → `192.168.222.31`, only
routable from the host. Reach it from a laptop via an SSH tunnel:

```bash
# one-time: map the api hostname to localhost
echo "127.0.0.1 api.test-sno.lab.home" | sudo tee -a /etc/hosts

# tunnel (unprivileged local port, keep running). Needs AllowTcpForwarding yes
# in the host sshd (set in /etc/ssh/sshd_config.d/*.conf).
ssh -N -L 16443:192.168.222.31:6443 <host>

# fetch kubeconfig once, point it at the local port
ssh <host> 'sudo KIND_EXPERIMENTAL_PROVIDER=podman kind get kubeconfig --name capi-baremetal-provider > /tmp/kc 2>/dev/null; KUBECONFIG=/tmp/kc kubectl -n test-capi get secret test-sno-admin-kubeconfig -o jsonpath="{.data.kubeconfig}" | base64 -d' > ~/sno-kubeconfig
sed -i 's|:6443|:16443|' ~/sno-kubeconfig
export KUBECONFIG=~/sno-kubeconfig
kubectl get nodes
```

TLS verifies because the cert is for `api.test-sno.lab.home` (port isn't in the
cert). If the tunnel resets with "connection refused" on the local port, the
host sshd has `AllowTcpForwarding no` — enable it and `systemctl reload sshd`.

## Upgrading the cluster

**The OCP version is owned by CAPOA**, via
`OpenshiftAssistedControlPlane.spec.distributionVersion`. Upgrade by patching
that — NOT with `oc adm upgrade` on the spoke (CAPOA reconciles a manual
`oc adm upgrade` straight back to `distributionVersion`, which looks like a
spontaneous downgrade).

```bash
sudo KIND_EXPERIMENTAL_PROVIDER=podman kind get kubeconfig --name capi-baremetal-provider > /tmp/kc
export KUBECONFIG=/tmp/kc
kubectl -n test-capi patch openshiftassistedcontrolplane test-sno --type=merge \
  -p '{"spec":{"distributionVersion":"4.20.40"}}'
```

Watch: OACP `status.conditions[type=UpgradeCompleted]` (goes
`UpgradeInProgress` → `True`) and, on the spoke, `oc get clusterversion`
(`Working towards 4.20.40` → `Progressing=False`). Expect one node reboot
(brief API blackout). This is exactly what the e2e `assert_upgrade` role does
when `upgrade_to_version` is set.

## Teardown (back to original host state)

```bash
cd ~/devel/cluster-api-provider-openshift-assisted
KIND_EXPERIMENTAL_PROVIDER=podman ansible-playbook --become \
  -i test/playbooks/inventories/local_host.yaml test/playbooks/cleanup.yaml
```

Removes: sushy container, kind cluster, all `bmh-vm-*` VMs + storage, the `bmh`
libvirt network, the host_networking firewall rules, and the `/tmp` e2e caches.
