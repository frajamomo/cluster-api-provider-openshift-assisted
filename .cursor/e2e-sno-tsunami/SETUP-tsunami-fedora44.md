# CAPOA SNO e2e on Fedora 44 (tsunami) — Setup & Networking

Reference for running the `cluster-api-provider-openshift-assisted` (CAPOA) SNO
end-to-end test on a Fedora 44 bare-metal host using the **podman** kind
provider. Written against host `tsunami`.

> The e2e was designed around the **docker** kind provider. Running it under
> podman works, but requires the adjustments documented here — one repo change
> and four host firewall additions. See [Why podman differs](#why-podman-differs-from-docker).

---

## 1. Host facts

| Item | Value |
|------|-------|
| OS | Fedora release 44, kernel `7.2.8-200.fc44` |
| Uplink NIC | `wlo1` — `192.168.2.14/24`, default gw `192.168.2.1` |
| Container engine | podman (rootful), `KIND_EXPERIMENTAL_PROVIDER=podman` |
| kind cluster | `capi-baremetal-provider` (single node, control-plane) |
| Firewall | firewalld active (nftables backend) **and** docker/iptables-nft rules coexist |
| Virtualization | libvirt/qemu + OVMF (UEFI) |

### Repo

```
~/devel/cluster-api-provider-openshift-assisted   branch: e2e-sno-podman
```

Branch `e2e-sno-podman` carries the podman-portability commits on top of
`master` (Fedora deps, local inventory, podman provider knob, ansible.posix,
and the ironic cert SAN fix `b753b211`).

### e2e knobs (bootstrap.sh)

```
KIND_EXPERIMENTAL_PROVIDER=podman
CLUSTER_TOPOLOGY=sno
NUMBER_OF_NODES=1
PULLSECRET=<base64>   # sourced from ~/e2e-sno.env (perms 600), never printed
```

### Host hardening for unattended runs

A full SNO run (install + optional upgrade) takes well over an hour. Two Fedora
defaults will interrupt it and must be disabled on the host:

- **Automatic reboot after updates.** `dnf-automatic` ships with
  `apply_updates = yes` and `reboot = when-needed`, which reboots the host
  mid-run. Set `reboot = never` in `/etc/dnf/automatic.conf` (and the dnf5
  `/etc/dnf/dnf5-plugins/automatic.conf` if present).
- **Idle suspend.** GNOME suspends on AC idle (`sleep-inactive-ac-type =
  suspend`, 15 min). Set it to `nothing`
  (`gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type nothing`,
  plus the `-battery-` variant). systemd `suspend.target`/`sleep.target` are also
  masked on tsunami as a hard backstop.

For remote laptop access to the deployed cluster (see REDEPLOY.md), the host
sshd also needs `AllowTcpForwarding yes` for the API SSH tunnel.

### Emulated BMH VM

`bmh-vm-01` — 8 vCPU, 16 GiB RAM, 120 GiB disk, UEFI (OVMF), NIC MAC
`00:60:2f:31:81:01` on libvirt network `bmh`. Powered via Redfish
(sushy-tools). Boots the ironic IPA ramdisk via virtual media, then boots the
installed RHCOS from disk.

---

## 2. Networking

### 2.1 Networks / subnets

| Network | Subnet | Gateway (host IF) | Purpose |
|---------|--------|-------------------|---------|
| Uplink | `192.168.2.0/24` | `192.168.2.1` (wlo1) | Host internet / LAN |
| kind (podman) | `10.89.0.0/24` | `10.89.0.1` (podman1) | kind node net; **ironic lives here** |
| podman default | `10.88.0.0/16` | `10.88.0.1` (podman0) | other podman containers |
| pod network | `10.244.0.0/16` | (in-cluster) | k8s pods (BMO, assisted-service) |
| **bmh** (libvirt NAT) | `192.168.222.0/24` | `192.168.222.1` (bmh) | **emulated bare-metal VM net** |
| docker (idle) | `172.17/16`, `172.18/16` | docker0, br-… (DOWN) | unused under podman |
| libvirt default | `192.168.122.0/24` | virbr0 (DOWN) | unused |

Key addresses:

| Address | What |
|---------|------|
| `10.89.0.2` | kind node IP → **ironic API `:6385`, deploy HTTP `:6180`** (ironic pod is `hostNetwork: true`) |
| `10.89.0.240` | MetalLB VIP → nginx-ingress → **assisted-service** (`assisted-service.assisted-installer.com`) |
| `192.168.222.1` | host IP on bmh bridge; libvirt dnsmasq (DNS+DHCP) for VMs; sushy Redfish `:8000` |
| `192.168.222.31` | the BMH VM (`bmh-vm-01`); IPA agent command API `:9999`; also the SNO api/ingress VIP |

### 2.2 DNS (libvirt dnsmasq on bmh)

The `bmh` network's dnsmasq serves the VM and injects split-horizon records:

```
api.test-sno.lab.home        → 192.168.222.31   (SNO VIP = the node itself)
api-int.test-sno.lab.home    → 192.168.222.31
*.apps.test-sno.lab.home     → 192.168.222.31
assisted-service.assisted-installer.com → 10.89.0.240   (MetalLB VIP)
assisted-image.assisted-installer.com   → 10.89.0.240
upstream servers: 192.168.2.7, 9.9.9.9, 192.168.2.1
```

So the VM reaches assisted-service via `10.89.0.240` (crosses bmh→kind), and
reaches the public RHCOS mirror via the upstream resolvers + the uplink.

### 2.3 Topology diagram

```
                         INTERNET (quay.io, mirror.openshift.com)
                                      ▲
                                      │  MASQUERADE out wlo1
                          ┌───────────┴───────────┐
                          │   HOST tsunami (F44)   │
                          │   wlo1 192.168.2.14    │
                          │   ip_forward = 1       │
                          │                        │
   ┌──────────────────────┤  FORWARD (policy DROP) ├───────────────────────┐
   │                       │  + libvirt bmh NAT     │                       │
   │                       └───────────┬────────────┘                      │
   │                                   │                                    │
   │  bridge: podman1 (10.89.0.1)      │      bridge: bmh (192.168.222.1)   │
   │  ┌─────────────────────────────┐  │  ┌──────────────────────────────┐  │
   │  │ kind node (podman container)│  │  │  libvirt VM  bmh-vm-01        │  │
   │  │ 10.89.0.2                   │  │  │  192.168.222.31              │  │
   │  │  ├ ironic   :6385 :6180 ────┼──┼──┼─► IPA agent  :9999 (callback) │  │
   │  │  │  (hostNetwork)          ◄┼──┼──┼── agent heartbeat :6385       │  │
   │  │  ├ BMO (pod 10.244)         │  │  │  RHCOS install → reboot→disk  │  │
   │  │  ├ assisted-service (pod) ◄─┼──┼──┼── assisted agent → 10.89.0.240│  │
   │  │  └ MetalLB VIP 10.89.0.240  │  │  └──────────────────────────────┘  │
   │  └─────────────────────────────┘  │             ▲                      │
   │                                    │  sushy Redfish :8000 (power/vmedia)│
   │       Redfish power/boot ──────────┼─────────────┘  on 192.168.222.1   │
   └────────────────────────────────────────────────────────────────────────┘
```

### 2.4 The four traffic flows that must cross bridges

| # | Flow | Path | Needs |
|---|------|------|-------|
| A | BMO / ironic clients → ironic | pod/node → `10.89.0.2:6385` | cert SAN for `10.89.0.2` (fix #1) |
| B | IPA agent heartbeat → ironic | VM `192.168.222.31` → `10.89.0.2:6385` | FORWARD bmh↔kind (fix #3) |
| C | ironic → IPA agent command API | node `10.89.0.2` → `192.168.222.31:9999` | FORWARD (fix #3) **+** libvirt NAT inbound accept (fix #4) |
| D | IPA agent → RHCOS mirror | VM `192.168.222.31` → internet `:443` | FORWARD bmh→uplink + MASQUERADE (fix #5) |

All four fail by default under podman; see next section.

---

## 3. Why podman differs from docker

1. **kind node IP.** docker-kind node = `172.18.0.2`; podman-kind node =
   `10.89.0.2`. The e2e's ironic TLS cert
   (`test/e2e/manifests/ironic/kustomization.yaml`) hardcodes `172.18.0.2` as a
   SAN. Under podman the node IP isn't in the cert, so every ironic client
   falls back to the host-published `192.168.222.1:6385` — a hairpin that
   podman's **netavark** does not DNAT for internally-originated traffic →
   `i/o timeout`.

2. **Two firewall layers that both filter FORWARD.**
   - `ip filter` FORWARD has **policy DROP** (set by docker, which is installed
     but idle). It does *not* auto-accept the bmh or kind subnets to each other
     or to the internet.
   - `ip libvirt_network` FORWARD only accepts `oif bmh` for
     `ct state established,related` and **rejects new inbound** connections to
     the VMs.

   A packet must be accepted by **both** tables. docker-based setups don't hit
   the libvirt-reject path the same way; podman does, so new inbound to the VM
   (ironic→:9999) is dropped until explicitly allowed.

---

## 4. Required changes

### 4.1 Repo (committed, backward-compatible) — `b753b211`

Add the podman kind node IP as an **additional** ironic cert SAN (keeping the
docker IP), in `test/e2e/manifests/ironic/kustomization.yaml`:

```yaml
- op: add
  path: /spec/ipAddresses/-
  value: 172.18.0.2     # docker kind node (default provider)
- op: add
  path: /spec/ipAddresses/-
  value: 10.89.0.2      # podman kind node (KIND_EXPERIMENTAL_PROVIDER=podman)
```

Works under either provider; no behavior change for docker.

### 4.2 Host firewall additions (runtime)

> **Not persistent.** firewalld restart flushes the firewalld nft table and
> drops hand-added rules; `iptables`/`nft` additions below are lost on reboot
> and on firewalld/libvirt-network restart. Re-apply after any such event.

```bash
UPLINK=wlo1
KIND_NET=10.89.0.0/24
BMH_NET=192.168.222.0/24
POD_NETS="10.89.0.0/24 10.244.0.0/16 10.88.0.0/16"

# (A/B) podman outbound (image pulls) + heartbeat: FORWARD + MASQUERADE for podman subnets
for n in $POD_NETS; do
  sudo iptables -C FORWARD -s $n -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -s $n -j ACCEPT
  sudo iptables -C FORWARD -d $n -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -d $n -j ACCEPT
  sudo iptables -t nat -C POSTROUTING -s $n ! -d $n -o $UPLINK -j MASQUERADE 2>/dev/null \
    || sudo iptables -t nat -A POSTROUTING -s $n ! -d $n -o $UPLINK -j MASQUERADE
done

# (C) VM <-> node forward both directions (ip filter)
sudo iptables -C FORWARD -s $KIND_NET -d $BMH_NET -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -s $KIND_NET -d $BMH_NET -j ACCEPT
sudo iptables -C FORWARD -s $BMH_NET -d $KIND_NET -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -s $BMH_NET -d $KIND_NET -j ACCEPT

# (C) libvirt NAT: allow NEW inbound to the VMs (bypass the bmh established,related-only accept)
sudo nft insert rule ip libvirt_network forward ip saddr $KIND_NET ip daddr $BMH_NET counter accept
sudo nft insert rule ip libvirt_network forward ip saddr $BMH_NET ip daddr $KIND_NET counter accept

# (D) bmh VM subnet -> internet (RHCOS download)
sudo iptables -C FORWARD -s $BMH_NET -o $UPLINK -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -s $BMH_NET -o $UPLINK -j ACCEPT
sudo iptables -C FORWARD -d $BMH_NET -i $UPLINK -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
  || sudo iptables -I FORWARD -d $BMH_NET -i $UPLINK -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -t nat -C POSTROUTING -s $BMH_NET ! -d $BMH_NET -o $UPLINK -j MASQUERADE 2>/dev/null \
  || sudo iptables -t nat -A POSTROUTING -s $BMH_NET ! -d $BMH_NET -o $UPLINK -j MASQUERADE
```

---

## 5. Verification probes

```bash
# A — ironic reachable at node IP (cert valid for it)
sudo podman exec capi-baremetal-provider-control-plane sh -c \
  'timeout 3 bash -c "</dev/tcp/10.89.0.2/6385" && echo ironic-OK'

# B/C — node <-> VM agent API (VM must be up with IPA listening)
sudo podman exec capi-baremetal-provider-control-plane sh -c \
  'timeout 3 bash -c "</dev/tcp/192.168.222.31/9999" && echo NODE->9999-OK'

# D — RHCOS write progressing (should climb into the GBs)
sudo virsh domblkstat bmh-vm-01 sda | grep wr_bytes

# podman outbound
sudo podman exec capi-baremetal-provider-control-plane sh -c \
  'timeout 5 bash -c "</dev/tcp/quay.io/443" && echo OUT-OK'
```

**Diagnosis signature for the libvirt-reject bug (flow C):** `host→VM:9999 OK`
but `node→VM:9999 closed`; the SYN appears on `podman1` in `tcpdump` but **not**
on `bmh` → libvirt forward reject. Fix = the `nft insert … ip libvirt_network`
rules above.

---

## 6. Install flow (happy path, for reference)

```
BMH available → ironic powers VM on (Redfish/sushy)
  → VM boots IPA ramdisk (virtual media)
  → IPA heartbeats ironic (10.89.0.2:6385)           [flow B]
  → ironic reads deploy steps from agent (:9999)      [flow C]
  → agent writes RHCOS from mirror to disk            [flow D]
  → BMH provisioned → VM reboots into RHCOS
  → assisted agent registers w/ assisted-service (10.89.0.240)
  → Agent approved (role master) → ACI installing
  → SNO control plane installs → ACI Completed
```
