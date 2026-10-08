#!/usr/bin/env bash
# Autonomous SNO e2e bootstrap for tsunami.
# Idempotent: safe to re-run. Sources user-provided PULLSECRET from ~/e2e-sno.env.
# Launched detached by the /loop: nohup bash ~/e2e-sno-bootstrap.sh > ~/e2e-sno.log 2>&1 &
set -euo pipefail

REPO="${REPO:-$HOME/devel/cluster-api-provider-openshift-assisted}"
ENV_FILE="${ENV_FILE:-$HOME/e2e-sno.env}"

# --- user-provided secrets / overrides ---
# ~/e2e-sno.env must export PULLSECRET=<base64>. Created by the user, never by the loop.
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

if [[ -z "${PULLSECRET:-}" ]]; then
  echo "FATAL: PULLSECRET is not set. Add it to $ENV_FILE:" >&2
  echo "  echo \"export PULLSECRET=<base64-pull-secret>\" >> $ENV_FILE" >&2
  exit 3   # distinct code → loop maps to STOP-NEED-SECRET
fi

# --- SNO parameters (the goal) ---
export CLUSTER_TOPOLOGY="${CLUSTER_TOPOLOGY:-sno}"
export NUMBER_OF_NODES="${NUMBER_OF_NODES:-1}"

# --- build / artifacts ---
export DIST_DIR="${DIST_DIR:-/tmp/dist}"
export CONTAINER_TAG="${CONTAINER_TAG:-local}"
# SKIP_BUILD can be exported via e2e.env on reruns once images exist.

# --- Fedora immutable-FS-safe Ansible caches ---
export ANSIBLE_HOME="${ANSIBLE_HOME:-/tmp/.ansible}"
export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-/tmp/.ansible.tmp}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/.cache}"
export ANSIBLE_CACHE_PLUGIN_CONNECTION="${ANSIBLE_CACHE_PLUGIN_CONNECTION:-/tmp/.ansible-cache}"
mkdir -p "$ANSIBLE_HOME" "$ANSIBLE_LOCAL_TEMP" "$XDG_CACHE_HOME" "$ANSIBLE_CACHE_PLUGIN_CONNECTION" "$DIST_DIR"

# --- optional venv (set USE_VENV=1 in e2e.env if system python 3.14 breaks deps) ---
if [[ "${USE_VENV:-0}" == "1" ]]; then
  VENV="${VENV:-$HOME/e2e-sno-venv}"
  [[ -d "$VENV" ]] || python3 -m venv "$VENV"
  # shellcheck disable=SC1091
  source "$VENV/bin/activate"
  pip install --quiet --upgrade ansible kubernetes jinja2-cli || true
fi

cd "$REPO"

echo "=== $(date -Is) bootstrap start: topology=$CLUSTER_TOPOLOGY nodes=$NUMBER_OF_NODES skip_build=${SKIP_BUILD:-false} ==="

# --- galaxy collections (same as `make e2e-test-dependencies`) ---
ansible-galaxy collection install -r test/ansible-requirements.yaml

# --- sanity: local connection works ---
ansible -i test/playbooks/inventories/local_host.yaml test_runner -m ping

# --- run the SNO e2e against localhost (local connection, no SSH) ---
# The playbook has no `become:` and expects to run as root (remote inventory uses
# ansible_user=root). On the local connection we are a normal user, so pass
# --become (passwordless sudo available). This is an invocation-only flag — no repo
# change, fully backward compatible. Override BECOME="" via e2e.env if ever running as root.
BECOME="${BECOME:---become}"
echo "=== $(date -Is) launching ansible-playbook (SNO) become='${BECOME}' ==="
exec ansible-playbook ${BECOME} \
  -i test/playbooks/inventories/local_host.yaml \
  test/playbooks/run_test.yaml
