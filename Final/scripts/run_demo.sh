#!/usr/bin/env bash
set -euo pipefail

# End-to-end demo (minimal, compliant with the assignment):
# 1) Provision 5 instances (Gatekeeper t2.large, Proxy t2.large, 3× MySQL t2.micro)
# 2) Bootstrap MySQL (Sakila + sysbench + replication)
# 3) Deploy Proxy and Gatekeeper
# 4) Run the benchmark (1000 READ/WRITE per strategy via Gatekeeper)

# Prerequisites:
# - AWS env vars: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN (if needed), AWS_DEFAULT_REGION
# - Existing EC2 key pair: KEY_NAME (e.g., export KEY_NAME="assignment-final")
# - Local SSH key for ubuntu: export KEY_PEM=/path/to/key.pem (default: $HOME/assignment_final.pem)
# - Python 3 installed locally

log(){ printf '==== [%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

: "${AWS_DEFAULT_REGION:?export AWS_DEFAULT_REGION=us-east-1 (e.g.)}"
: "${KEY_NAME:?export KEY_NAME=<EC2 key pair name>}"

PYBIN="python"
command -v "$PYBIN" >/dev/null 2>&1 || PYBIN="python3"

log "1) Provision (EC2 + SG) ..."
$PYBIN Final/scripts/boto_up_final.py

log "2) Bootstrap MySQL (Sakila + sysbench + replication) ..."
bash Final/scripts/bootstrap_mysql.sh

log "3) Deploy Proxy ..."
bash Final/scripts/deploy_proxy.sh

log "4) Deploy Gatekeeper ..."
bash Final/scripts/deploy_gatekeeper.sh

# Retrieve Gatekeeper public IP for display
GK_IP="$($PYBIN - <<'PY'
import json
with open("Final/infra/instances.json","r",encoding="utf-8") as f:
    d=json.load(f)
print(d["gatekeeper"].get("public_ip") or d["gatekeeper"].get("private_ip") or "")
PY
)"

echo
log "5) Smoke tests (Gatekeeper):"
echo "  curl -s http://${GK_IP}/health"
echo "  curl -s -H 'X-API-Key: changeme' -H 'Content-Type: application/json' \\"
echo "       -X POST 'http://${GK_IP}/query?strategy=random' -d '{\"sql\":\"SELECT COUNT(*) FROM film;\"}'"

log "6) Benchmark (1000 READ + 1000 WRITE per strategy) ..."
$PYBIN Final/benchmark/bench.py

echo
log "Done. CSV results:"
echo "  Final/benchmark/results/results.csv"