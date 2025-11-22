#!/usr/bin/env bash
# Bootstrap minimal MySQL setup per TP:
# - On manager: install MySQL + Sakila + users + enable replication + sysbench (using provided commands)
# - On workers: install MySQL + Sakila + configure replication to manager + sysbench
# Requirements:
#   - Run: python Final/scripts/boto_up_final.py (to generate Final/infra/instances.json)
#   - SSH key: export KEY_PEM=/full/path/to/key.pem (defaults to $HOME/assignment_final.pem)

set -euo pipefail

KEY_PEM="${KEY_PEM:-$HOME/assignment_final.pem}"
SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -i ${KEY_PEM}"
chmod 600 "$KEY_PEM" 2>/dev/null || true

# Wait for SSH (port 22) to be ready on a host
wait_ssh() {
  local host="$1"
  for i in {1..40}; do
    if ssh $SSH_OPTS -o ConnectTimeout=3 "ubuntu@${host}" "echo ssh-ok" >/dev/null 2>&1; then
      return 0
    fi
    echo "SSH not ready on ${host} (try $i), retrying in 5s..."
    sleep 5
  done
  return 1
}

INFO_JSON="Final/infra/instances.json"
if [[ ! -f "$INFO_JSON" ]]; then
  echo "Missing $INFO_JSON. Run: python Final/scripts/boto_up_final.py" >&2
  exit 1
fi
if [[ ! -f "$KEY_PEM" ]]; then
  echo "Missing KEY_PEM file: $KEY_PEM" >&2
  echo "Export KEY_PEM=/full/path/to/key.pem" >&2
  exit 1
fi

# Extract IPs
read MGR_PUB MGR_PRIV WORKER1_PUB WORKER2_PUB < <(python - <<'PY'
import json
with open("Final/infra/instances.json","r",encoding="utf-8") as f:
    d=json.load(f)
mgr_pub  = d["mysql"]["manager"].get("public_ip") or ""
mgr_priv = d["mysql"]["manager"].get("private_ip") or ""
workers  = d["mysql"]["workers"]
wpub = [ (w.get("public_ip") or "") for w in workers ]
wpub += ["",""]  # pad
print(mgr_pub, mgr_priv, wpub[0], wpub[1])
PY
)

# Sanitize potential CRLF endings (Windows) on IP variables
MGR_PUB="${MGR_PUB//$'\r'/}"; MGR_PRIV="${MGR_PRIV//$'\r'/}"
WORKER1_PUB="${WORKER1_PUB//$'\r'/}"; WORKER2_PUB="${WORKER2_PUB//$'\r'/}"

if [[ -z "$MGR_PUB" || -z "$MGR_PRIV" ]]; then
  echo "Manager IPs not found in $INFO_JSON" >&2
  exit 1
fi
if [[ -z "$WORKER1_PUB" && -z "$WORKER2_PUB" ]]; then
  echo "No worker public IPs found in $INFO_JSON" >&2
  exit 1
fi

echo "Manager public IP:  $MGR_PUB"
echo "Manager private IP: $MGR_PRIV"
echo "Worker1 public IP:  ${WORKER1_PUB:-N/A}"
echo "Worker2 public IP:  ${WORKER2_PUB:-N/A}"

echo "Waiting for SSH to be ready..."
if ! wait_ssh "$MGR_PUB"; then
  echo "ERROR: SSH not ready on manager ($MGR_PUB)"; exit 1
fi
if [[ -n "${WORKER1_PUB:-}" ]]; then
  wait_ssh "$WORKER1_PUB" || echo "Warning: SSH not ready yet on $WORKER1_PUB, will continue"
fi
if [[ -n "${WORKER2_PUB:-}" ]]; then
  wait_ssh "$WORKER2_PUB" || echo "Warning: SSH not ready yet on $WORKER2_PUB, will continue"
fi

# Parameters (keep minimal, consistent with proxy defaults)
APP_PASS="${APP_PASS:-password}"
REPL_PASS="${REPL_PASS:-replpass}"
ROOT_PASS="${ROOT_PASS:-rootpass}"

MANAGER_SCRIPT_LOCAL="Final/db/setup_manager.sh"
WORKER_SCRIPT_LOCAL="Final/db/setup_worker.sh"
[[ -f "$MANAGER_SCRIPT_LOCAL" && -f "$WORKER_SCRIPT_LOCAL" ]] || { echo "Missing setup scripts in Final/db/"; exit 1; }

# Copy scripts to nodes
echo "Copying scripts to manager..."
scp $SSH_OPTS "$MANAGER_SCRIPT_LOCAL" "ubuntu@${MGR_PUB}:/home/ubuntu/"
chmod 600 "$KEY_PEM" 2>/dev/null || true

if [[ -n "${WORKER1_PUB:-}" ]]; then
  echo "Copying scripts to worker1..."
  scp $SSH_OPTS "$WORKER_SCRIPT_LOCAL" "ubuntu@${WORKER1_PUB}:/home/ubuntu/"
fi
if [[ -n "${WORKER2_PUB:-}" ]]; then
  echo "Copying scripts to worker2..."
  scp $SSH_OPTS "$WORKER_SCRIPT_LOCAL" "ubuntu@${WORKER2_PUB}:/home/ubuntu/"
fi

# Run manager setup
echo "Running manager setup..."
ssh $SSH_OPTS "ubuntu@${MGR_PUB}" "sudo bash /home/ubuntu/setup_manager.sh '${APP_PASS}' '${REPL_PASS}' '${ROOT_PASS}'"

# Run workers setup
if [[ -n "${WORKER1_PUB:-}" ]]; then
  echo "Running worker1 setup..."
  ssh $SSH_OPTS "ubuntu@${WORKER1_PUB}" "sudo bash /home/ubuntu/setup_worker.sh '${MGR_PRIV}' '${REPL_PASS}' '${ROOT_PASS}'"
fi
if [[ -n "${WORKER2_PUB:-}" ]]; then
  echo "Running worker2 setup..."
  ssh $SSH_OPTS "ubuntu@${WORKER2_PUB}" "sudo bash /home/ubuntu/setup_worker.sh '${MGR_PRIV}' '${REPL_PASS}' '${ROOT_PASS}'"
fi

echo
echo "Bootstrap finished."
echo "You can now deploy the Proxy and Gatekeeper:"
echo "  bash Final/scripts/deploy_proxy.sh"
echo "  bash Final/scripts/deploy_gatekeeper.sh"