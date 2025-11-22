#!/usr/bin/env bash
set -euo pipefail

# Minimal deploy script for Gatekeeper (public)
# Prereqs:
# - Run: python Final/scripts/boto_up_final.py
# - KEY_PEM points to a valid SSH key for ubuntu user

KEY_PEM="${KEY_PEM:-$HOME/assignment_final.pem}"
SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -i ${KEY_PEM}"

INFO_JSON="Final/infra/instances.json"
GK_DIR_LOCAL="Final/gatekeeper"

if [[ ! -f "$INFO_JSON" ]]; then
  echo "Missing $INFO_JSON. Run: python Final/scripts/boto_up_final.py" >&2
  exit 1
fi
if [[ ! -f "$KEY_PEM" ]]; then
  echo "Missing KEY_PEM file: $KEY_PEM" >&2
  echo "Export KEY_PEM=/full/path/to/key.pem" >&2
  exit 1
fi

read GK_IP PROXY_PRIV_IP < <(python - <<'PY'
import json
with open("Final/infra/instances.json","r",encoding="utf-8") as f:
    data=json.load(f)
gk = data.get("gatekeeper",{})
px = data.get("proxy",{})
print((gk.get("public_ip") or gk.get("private_ip") or "") , (px.get("private_ip") or px.get("public_ip") or ""))
PY
)
# Sanitize CRLF (Windows newlines)
GK_IP="${GK_IP//$'\r'/}"
PROXY_PRIV_IP="${PROXY_PRIV_IP//$'\r'/}"

if [[ -z "$GK_IP" || -z "$PROXY_PRIV_IP" ]]; then
  echo "Missing IPs (gatekeeper/proxy) in $INFO_JSON" >&2
  exit 1
fi

echo "Gatekeeper IP: $GK_IP"
echo "Proxy private IP: $PROXY_PRIV_IP"

# Copy gatekeeper code
scp $SSH_OPTS -r "$GK_DIR_LOCAL" "ubuntu@${GK_IP}:/home/ubuntu/"

# Install deps and run Gatekeeper bound to :80
ssh $SSH_OPTS "ubuntu@${GK_IP}" 'bash -lc "
  set -e
  sudo apt-get update -y
  sudo apt-get install -y python3 python3-pip
  python3 -m pip install --user --upgrade pip || true
  # Install dependencies for the root user (executed with sudo below)
  sudo -H pip3 install --no-input --upgrade fastapi uvicorn requests

  # Env (minimal)
  echo \"export API_KEY=\${API_KEY:-changeme}\" >  ~/.gk_env
  echo \"export PROXY_HOST='"$PROXY_PRIV_IP"'\" >> ~/.gk_env
  echo \"export PROXY_PORT=8080\"            >> ~/.gk_env
  echo \"export PORT=80\"                    >> ~/.gk_env

  cd ~/gatekeeper
  # Kill previous exact process if any
  sudo pkill -f -x '\''python3 /home/ubuntu/gatekeeper/app.py'\'' || true

  # Start as root on port 80, preserving env from ubuntu user
  nohup sudo bash -lc '\''source /home/ubuntu/.gk_env && python3 /home/ubuntu/gatekeeper/app.py'\'' > ~/gatekeeper/uvicorn.log 2>&1 & disown

  sleep 5
  sudo pgrep -fal -x '\''python3 /home/ubuntu/gatekeeper/app.py'\'' || { echo GATEKEEPER_NOT_RUNNING; tail -n 100 /home/ubuntu/gatekeeper/uvicorn.log || true; exit 1; }
  curl -sS --max-time 5 http://127.0.0.1/health || true
  sudo ss -ltnp | grep :80 || true
"'

echo "Gatekeeper deployed. Health check (run locally):"
echo "  curl -s http://$GK_IP/health | jq . || curl -s http://$GK_IP/health"
echo "  Example query (READ):"
echo "    curl -s -H 'X-API-Key: changeme' -X POST 'http://$GK_IP/query?strategy=random' -d '{\"sql\":\"SELECT COUNT(*) FROM film;\"}' -H 'Content-Type: application/json'"