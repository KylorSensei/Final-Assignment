#!/usr/bin/env bash
set -euo pipefail

# Minimal deploy script for Proxy (Trusted Host)
# Prereqs:
# - Run python Final/scripts/boto_up_final.py first
# - Ensure KEY_PEM points to a valid SSH key for ubuntu user

KEY_PEM="${KEY_PEM:-$HOME/assignment_final.pem}"
SSH_OPTS="-o StrictHostKeyChecking=no -o BatchMode=yes -i ${KEY_PEM}"

INFO_JSON="Final/infra/instances.json"
PROXY_DIR_LOCAL="Final/proxy"

if [[ ! -f "$INFO_JSON" ]]; then
  echo "Missing $INFO_JSON. Run: python Final/scripts/boto_up_final.py" >&2
  exit 1
fi
if [[ ! -f "$KEY_PEM" ]]; then
  echo "Missing KEY_PEM file: $KEY_PEM" >&2
  echo "Export KEY_PEM=/full/path/to/key.pem" >&2
  exit 1
fi

PROXY_IP="$(python - <<'PY'
import json,sys
with open("Final/infra/instances.json","r",encoding="utf-8") as f:
    data=json.load(f)
print(data["proxy"].get("public_ip") or data["proxy"].get("private_ip") or "")
PY
)"
if [[ -z "$PROXY_IP" ]]; then
  echo "Proxy IP not found in $INFO_JSON" >&2
  exit 1
fi

echo "Proxy IP: $PROXY_IP"

# Copy proxy code and config
scp $SSH_OPTS -r "$PROXY_DIR_LOCAL" "ubuntu@${PROXY_IP}:/home/ubuntu/"

# Install deps and run
ssh $SSH_OPTS "ubuntu@${PROXY_IP}" 'bash -lc "
  set -e
  sudo apt-get update -y
  sudo apt-get install -y python3 python3-pip
  python3 -m pip install --user --upgrade pip
  python3 -m pip install --user fastapi uvicorn mysql-connector-python

  # Env for DB creds (defaults: app/password on sakila)
  echo \"export DB_USER=\${DB_USER:-app}\"     >  ~/.proxy_env
  echo \"export DB_PASSWORD=\${DB_PASSWORD:-password}\" >> ~/.proxy_env
  echo \"export DB_NAME=\${DB_NAME:-sakila}\"   >> ~/.proxy_env

  cd ~/proxy
  # Kill previous exact process if any
  pkill -f -x '\''python3 /home/ubuntu/proxy/app.py'\'' || true

  # Start
  nohup bash -lc '\''source ~/.proxy_env && python3 /home/ubuntu/proxy/app.py'\'' > ~/proxy/uvicorn.log 2>&1 & disown

  sleep 3
  pgrep -fal -x '\''python3 /home/ubuntu/proxy/app.py'\'' || { echo PROXY_NOT_RUNNING; exit 1; }
  ss -ltnp | grep :8080 || true
"'

echo "Proxy deployed. Health check (run locally):"
echo "  curl -s http://$PROXY_IP:8080/health | jq . || curl -s http://$PROXY_IP:8080/health"