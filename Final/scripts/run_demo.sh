#!/usr/bin/env bash
set -euo pipefail

# Démo de bout en bout (minimal, conforme au TP):
# 1) Provisionne 5 instances (Gatekeeper t2.large, Proxy t2.large, 3× MySQL t2.micro)
# 2) Bootstrap MySQL (Sakila + sysbench + réplication)
# 3) Déploie Proxy et Gatekeeper
# 4) Lance le benchmark (1000 READ/WRITE par stratégie via Gatekeeper)

# Prérequis:
# - Variables d'env AWS: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN (si nécessaire), AWS_DEFAULT_REGION
# - Clé EC2 existante: KEY_NAME (ex: export KEY_NAME="assignment-final")
# - Clé SSH locale pour ubuntu: export KEY_PEM=/chemin/vers/key.pem (defaut: $HOME/assignment_final.pem)
# - Python 3 installé localement

log(){ printf '==== [%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }

: "${AWS_DEFAULT_REGION:?export AWS_DEFAULT_REGION=us-east-1 (par ex.)}"
: "${KEY_NAME:?export KEY_NAME=<nom de la keypair EC2>}"

PYBIN="python"
command -v "$PYBIN" >/dev/null 2>&1 || PYBIN="python3"

log "1) Provision (EC2 + SG) ..."
$PYBIN Final/scripts/boto_up_final.py

log "2) Bootstrap MySQL (Sakila + sysbench + réplication) ..."
bash Final/scripts/bootstrap_mysql.sh

log "3) Déployer Proxy ..."
bash Final/scripts/deploy_proxy.sh

log "4) Déployer Gatekeeper ..."
bash Final/scripts/deploy_gatekeeper.sh

# Récupère l'IP publique du Gatekeeper pour affichage
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

log "6) Benchmark (1000 READ + 1000 WRITE par stratégie) ..."
$PYBIN Final/benchmark/bench.py

echo
log "Terminé. Résultats CSV:"
echo "  Final/benchmark/results/results.csv"