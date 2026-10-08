# AI-RUNBOOK — CAPOA SNO e2e on podman-kind (Fedora host)

Machine-oriented companion to `SETUP-tsunami-fedora44.md`. Written for an AI
agent driving this via SSH. Prose explanation lives in the SETUP doc; this file
is **state → action**. Prefer the exact commands here; do not improvise firewall
changes beyond what the decision tree prescribes.

---

## 0. Operating constraints (read first)

- **All host actions run over SSH**: prefix every command with `ssh tsunami '…'`.
  This runbook omits the prefix in command blocks for readability — add it.
- **Never print secrets.** `PULLSECRET` lives in `~/e2e-sno.env` (mode 600).
  Source it; do not echo it.
- **Firewall / systemctl changes may be blocked by a safety classifier.** If a
  firewall command is refused, emit the exact command for the human to run and
  wait — do not try to work around the classifier.
- **Rules are non-persistent.** After any firewalld restart, reboot, or
  `virsh net-destroy/start bmh`, re-run §4 (FIX-ALL). Assume rules are gone if
  you did not just apply them in this session.
- **Idempotent by design.** Every fix uses `iptables -C … || -I …` guards and
  re-applying is safe.

---

## 1. Constants (single source of truth)

```bash
HOST=tsunami
REPO=~/devel/cluster-api-provider-openshift-assisted
BRANCH=e2e-sno-podman
KIND_CLUSTER=capi-baremetal-provider
KIND_NODE_CTR=capi-baremetal-provider-control-plane   # podman container name
UPLINK=wlo1
KIND_NET=10.89.0.0/24      ; KIND_NODE_IP=10.89.0.2
POD_NET=10.244.0.0/16
PODMAN_NET=10.88.0.0/16
BMH_NET=192.168.222.0/24   ; BMH_GW=192.168.222.1 ; VM_IP=192.168.222.31
AS_VIP=10.89.0.240         # assisted-service via MetalLB/nginx-ingress
VM=bmh-vm-01
NS=test-capi               # e2e namespace (BMH/ACI/Agent/Machine)
IRONIC_NS=baremetal-operator-system
```

Get the kubeconfig (rootful + podman provider — both required):

```bash
sudo KIND_EXPERIMENTAL_PROVIDER=podman kind get kubeconfig --name capi-baremetal-provider > /tmp/kc
export KUBECONFIG=/tmp/kc
```

---

## 2. Launch (from scratch)

```bash
# precondition: ~/e2e-sno.env contains `export PULLSECRET=<base64>` (mode 600)
~/e2e-sno-tsunami/bootstrap.sh        # idempotent; sources env, runs the ansible e2e
# defaults baked in: KIND_EXPERIMENTAL_PROVIDER=podman CLUSTER_TOPOLOGY=sno NUMBER_OF_NODES=1
# ansible caches under /tmp/*; repo at $REPO on branch $BRANCH
```

Then apply §4 (FIX-ALL) **before** BMH provisioning begins (or any time the
deploy stalls). The repo fix `b753b211` is already on `$BRANCH`; the firewall
rules are host runtime state and must be (re)applied.

---

## 3. Decision tree (symptom → cause → fix)

Run §5 (PROBES) to get the symptom, then match the first row that applies.

| Observed symptom | Cause | Action |
|------------------|-------|--------|
| BMO logs `dial tcp 192.168.222.1:6385: i/o timeout`, pods can't reach ironic | ironic cert lacks SAN for `10.89.0.2`; clients use broken host hairpin | Apply FIX-1 (cert SAN + endpoint) then restart ironic+BMO |
| `ImagePullBackOff`, `node→quay.io:443` fails | podman outbound FORWARD/MASQUERADE missing (ip filter policy DROP) | FIX-ALL §4 (covers podman subnets) |
| ironic log `deploy failed` from `wait call-back`, **no** agent heartbeat/lookup lines | agent can't reach ironic (bmh→kind forward dropped) | FIX-ALL §4 (FORWARD bmh↔kind) |
| `host→VM:9999 OK` but `node→VM:9999 closed`; SYN on `podman1` tcpdump but **not** on `bmh` | libvirt bmh NAT rejects NEW inbound | FIX-ALL §4 (the `nft insert … ip libvirt_network` rules) |
| BMH `provisioning` no error, ironic on `write_image`, `virsh domblkstat … wr_bytes 0`, no `src=192.168.222.31 dport=443` conntrack | bmh subnet can't reach RHCOS mirror | FIX-ALL §4 (bmh→uplink FORWARD+MASQUERADE) |
| BMH flips `provisioning`↔`deprovisioning`, new node UUID each cycle, VM self-powers-off ~80s | downstream of any of the above; ironic can't finish `get_deploy_steps` → power-cycles | FIX-ALL §4, then let the next cycle proceed |
| ACI `insufficient` right after agent registers | normal transient (validations running) | wait; proceeds to `preparing-for-installation` |

Do **not** pursue the `:9999` inbound path as the primary fix until you have
confirmed the agent is actually up (`host→VM:9999 OK`). A down agent and a
blocked forward look similar; the probe disambiguates.

---

## 4. FIX-ALL (host networking) — apply as one block

```bash
UPLINK=wlo1; KIND_NET=10.89.0.0/24; BMH_NET=192.168.222.0/24
POD_NETS="10.89.0.0/24 10.244.0.0/16 10.88.0.0/16"

# podman outbound + heartbeat (ip filter FORWARD policy is DROP)
for n in $POD_NETS; do
  sudo iptables -C FORWARD -s $n -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -s $n -j ACCEPT
  sudo iptables -C FORWARD -d $n -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -d $n -j ACCEPT
  sudo iptables -t nat -C POSTROUTING -s $n ! -d $n -o $UPLINK -j MASQUERADE 2>/dev/null \
    || sudo iptables -t nat -A POSTROUTING -s $n ! -d $n -o $UPLINK -j MASQUERADE
done

# VM <-> node (ip filter)
sudo iptables -C FORWARD -s $KIND_NET -d $BMH_NET -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -s $KIND_NET -d $BMH_NET -j ACCEPT
sudo iptables -C FORWARD -s $BMH_NET -d $KIND_NET -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -s $BMH_NET -d $KIND_NET -j ACCEPT

# libvirt NAT inbound to VMs (bmh accepts only established,related otherwise)
sudo nft list chain ip libvirt_network forward 2>/dev/null | grep -q "saddr $KIND_NET ip daddr $BMH_NET" \
  || sudo nft insert rule ip libvirt_network forward ip saddr $KIND_NET ip daddr $BMH_NET counter accept
sudo nft list chain ip libvirt_network forward 2>/dev/null | grep -q "saddr $BMH_NET ip daddr $KIND_NET" \
  || sudo nft insert rule ip libvirt_network forward ip saddr $BMH_NET ip daddr $KIND_NET counter accept

# bmh VM subnet -> internet (RHCOS download)
sudo iptables -C FORWARD -s $BMH_NET -o $UPLINK -j ACCEPT 2>/dev/null || sudo iptables -I FORWARD -s $BMH_NET -o $UPLINK -j ACCEPT
sudo iptables -C FORWARD -d $BMH_NET -i $UPLINK -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
  || sudo iptables -I FORWARD -d $BMH_NET -i $UPLINK -m state --state RELATED,ESTABLISHED -j ACCEPT
sudo iptables -t nat -C POSTROUTING -s $BMH_NET ! -d $BMH_NET -o $UPLINK -j MASQUERADE 2>/dev/null \
  || sudo iptables -t nat -A POSTROUTING -s $BMH_NET ! -d $BMH_NET -o $UPLINK -j MASQUERADE
```

### FIX-1 (cert SAN + endpoint) — only if the repo fix didn't take, or for a live cluster

Repo (durable, already committed `b753b211`): ensure
`test/e2e/manifests/ironic/kustomization.yaml` lists `10.89.0.2` as a cert SAN.

Live cluster patch (re-issues cert, repoints endpoint, restarts consumers):

```bash
export KUBECONFIG=/tmp/kc
kubectl -n baremetal-operator-system patch certificate ironic-cert --type=json \
  -p '[{"op":"add","path":"/spec/ipAddresses/-","value":"10.89.0.2"}]'
kubectl -n baremetal-operator-system patch cm ironic --type=merge \
  -p '{"data":{"IRONIC_ENDPOINT":"https://10.89.0.2:6385/v1/"}}'
kubectl -n baremetal-operator-system rollout restart deploy/ironic deploy/baremetal-operator-controller-manager
# NOTE: new pods must pull images → ensure §4 podman-outbound is applied first.
```

---

## 5. PROBES (read-only; use to classify before fixing)

```bash
export KUBECONFIG=/tmp/kc
# high-level state
kubectl -n test-capi get bmh,aci,agents,machines -o wide

# ironic reachable from node (cert must cover 10.89.0.2)
sudo podman exec capi-baremetal-provider-control-plane sh -c \
  'timeout 3 bash -c "</dev/tcp/10.89.0.2/6385" && echo ironic-OK || echo ironic-FAIL'

# agent API: host vs node (disambiguates "agent down" from "forward blocked")
timeout 3 bash -c '</dev/tcp/192.168.222.31/9999' && echo HOST-9999-OK || echo HOST-9999-x
sudo podman exec capi-baremetal-provider-control-plane sh -c \
  'timeout 3 bash -c "</dev/tcp/192.168.222.31/9999" && echo NODE-9999-OK || echo NODE-9999-x'

# RHCOS write progress (climbs into GBs when flow D works)
sudo virsh domblkstat bmh-vm-01 sda | grep wr_bytes

# podman outbound
sudo podman exec capi-baremetal-provider-control-plane sh -c \
  'timeout 5 bash -c "</dev/tcp/quay.io/443" && echo OUT-OK || echo OUT-FAIL'

# bridge-level trace for the :9999 inbound bug (SYN on podman1 but not bmh = libvirt reject)
( sudo timeout 6 tcpdump -ni podman1 'host 192.168.222.31 and port 9999' & )
( sudo timeout 6 tcpdump -ni bmh     'host 10.89.0.2 and port 9999' & )
sleep 1; sudo podman exec capi-baremetal-provider-control-plane sh -c \
  'timeout 4 bash -c "</dev/tcp/192.168.222.31/9999"; echo rc=$?'

# ironic deploy/agent errors
IR=$(kubectl -n baremetal-operator-system get pods -l name=ironic -o name | head -1)
kubectl -n baremetal-operator-system logs ${IR#pod/} -c ironic --since=120s \
  | grep -iE 'deploy failed|get_deploy_steps|Connection refused|write_image|moved to provision state'
```

---

## 6. SUCCESS GATES (ordered; each implies the previous)

Poll these in order. Each gate's command and the value that means "passed":

| Gate | Command (KUBECONFIG=/tmp/kc) | Pass value |
|------|------------------------------|------------|
| G1 ironic up | probe `10.89.0.2:6385` | `ironic-OK` |
| G2 agent heartbeat | ironic log has `lookup`/`heartbeat` for the node | present, no `deploy failed` |
| G3 deploy steps | ironic log `Executing {'step': 'write_image'}` | present |
| G4 RHCOS writing | `virsh domblkstat bmh-vm-01 sda` wr_bytes | climbing (GBs) |
| G5 provisioned | `kubectl -n test-capi get bmh bmh-vm-01 -o jsonpath={.status.provisioning.state}` | `provisioned` |
| G6 agent registered | `kubectl -n test-capi get agents` | one agent, `APPROVED=true ROLE=master` |
| G7 installing | `kubectl -n test-capi get aci test-sno -o jsonpath={.status.debugInfo.state}` | `installing` |
| G8 done | ACI `Completed` condition | `status=True` |

Watch loop for G5–G8:

```bash
export KUBECONFIG=/tmp/kc
while :; do
  aci=$(kubectl -n test-capi get aci test-sno -o jsonpath='{.status.debugInfo.state}')
  st=$(kubectl -n test-capi get agents -o jsonpath='{.items[0].status.progress.currentStage}')
  done=$(kubectl -n test-capi get aci test-sno -o jsonpath='{range .status.conditions[?(@.type=="Completed")]}{.status}{end}')
  fail=$(kubectl -n test-capi get aci test-sno -o jsonpath='{range .status.conditions[?(@.type=="Failed")]}{.status}{end}')
  echo "$(date +%T) aci=$aci stage=[$st] completed=$done failed=$fail"
  [ "$done" = True ] && { echo DONE; break; }
  [ "$fail" = True ] && { echo FAILED; break; }
  sleep 40
done
```

Expected stage order: `Installing → Waiting for bootkube → Writing image to disk
→ Rebooting → Waiting for control plane → Joined → Done`. A transient agent
disconnect during `Rebooting` is normal.

---

## 7. INVARIANTS (hard rules for the agent)

1. Repo changes must be **backward-compatible** and stay on branch `$BRANCH`
   (never break the docker provider). The cert fix adds a SAN, never replaces.
2. Do not change `IRONIC_ENDPOINT` without first ensuring the cert has a SAN for
   the new address (else TLS fails).
3. Apply §4 podman-outbound **before** any pod rollout, or new pods hit
   `ImagePullBackOff`.
4. When a deploy stalls, classify with §5 before acting; the five failure modes
   look alike at the `bmh get` level but differ at the probe level.
5. If `firewalld`/`libvirt net` was restarted, re-apply §4 — rules are not
   persistent.
6. **Upgrade only via OACP.** The spoke OCP version is owned by
   `OpenshiftAssistedControlPlane.spec.distributionVersion`. To upgrade, patch it
   (`kubectl -n test-capi patch openshiftassistedcontrolplane test-sno
   --type=merge -p '{"spec":{"distributionVersion":"<ver>"}}'`). NEVER
   `oc adm upgrade` on the spoke — CAPOA reverts it to `distributionVersion`,
   which looks like a spontaneous downgrade. Watch OACP
   `status.conditions[type=UpgradeCompleted]` → `True`.
7. **Host must not reboot/suspend mid-run.** On Fedora, set dnf-automatic
   `reboot = never` and disable GNOME idle-suspend before a long run (see
   SETUP doc "Host hardening"). An interrupted run leaves a half-built cluster
   (often on the docker provider if the env var was lost) — tear down with
   cleanup.yaml and restart.
```
