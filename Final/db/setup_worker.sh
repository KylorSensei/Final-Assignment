#!/usr/bin/env bash
# Minimal bootstrap for MySQL Worker: install MySQL + Sakila + configure replication to manager + sysbench
# Usage (on worker): sudo bash setup_worker.sh MANAGER_PRIV_IP REPL_PASS ROOT_PASS
set -euo pipefail

MANAGER_IP="${1:?manager private IP required}"
REPL_PASS="${2:-replpass}"
ROOT_PASS="${3:-rootpass}"

export DEBIAN_FRONTEND=noninteractive

# Avoid apt locks/errors on fresh instances
retry_apt() {
  for i in {1..20}; do
    if apt-get update -y && apt-get install -y mysql-server sysbench wget tar; then
      return 0
    fi
    echo "apt busy/failed, retry $i/20 ..."
    rm -f /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock 2>/dev/null || true
    dpkg --configure -a || true
    sleep 6
  done
  echo "apt failed after multiple attempts"; exit 1
}

echo "[1/6] Install MySQL and sysbench"
retry_apt

echo "[2/6] Configure root password and auth plugin (mysql_native_password)"
mysql -uroot -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${ROOT_PASS}'; FLUSH PRIVILEGES;" || true

echo "[3/6] Configure replica settings (server-id unique) and restart"
CNF="/etc/mysql/mysql.conf.d/mysqld.cnf"
# remove previous if present
sed -i '/^server-id=/d' "$CNF" || true
sed -i '/^gtid_mode=/d' "$CNF" || true
sed -i '/^enforce_gtid_consistency=/d' "$CNF" || true
sed -i '/^binlog_format=/d' "$CNF" || true
sed -i '/^read_only=/d' "$CNF" || true
sed -i '/^super_read_only=/d' "$CNF" || true

# pick a pseudo-random server-id from instance-id hash if available; else use 2
SID="2"
if command -v curl >/dev/null 2>&1; then
  TOKEN="$(curl -sS -m 0.5 -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600' || true)"
  IID="$(curl -sS -m 0.5 -H "X-aws-ec2-metadata-token: ${TOKEN:-}" 'http://169.254.169.254/latest/meta-data/instance-id' || true)"
  if [[ -n "${IID:-}" ]]; then
    SID="$(( (16#$(echo -n "$IID" | tail -c 4 | xxd -p 2>/dev/null || echo -n "0002")) % 4294967295 ))"
    [[ "$SID" -lt 2 ]] && SID=2
  fi
fi

cat >> "$CNF" <<EOF

# --- worker replication config (added by setup_worker.sh) ---
server-id=${SID}
gtid_mode=ON
enforce_gtid_consistency=ON
binlog_format=ROW
read_only=ON
super_read_only=ON
EOF

systemctl restart mysql
sleep 2

echo "[3b] Temporarily disable read_only to import Sakila"
mysql -uroot -p"${ROOT_PASS}" -e "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;"

echo "[4/6] Install Sakila sample DB (schema + data)"
WORKDIR="/tmp/sakila"
mkdir -p "$WORKDIR"
cd "$WORKDIR"
if [[ ! -f sakila-db.tar.gz ]]; then
  wget -q https://downloads.mysql.com/docs/sakila-db.tar.gz
fi
tar xzf sakila-db.tar.gz
cd sakila-db
mysql -uroot -p"${ROOT_PASS}" -e "SOURCE sakila-schema.sql; SOURCE sakila-data.sql;"

echo "[5/6] Configure replication to manager (GTID auto position)"
mysql -uroot -p"${ROOT_PASS}" -e "STOP SLAVE;" || true
mysql -uroot -p"${ROOT_PASS}" -e "RESET SLAVE ALL;" || true
mysql -uroot -p"${ROOT_PASS}" -e "CHANGE MASTER TO MASTER_HOST='${MANAGER_IP}', MASTER_USER='repl', MASTER_PASSWORD='${REPL_PASS}', MASTER_AUTO_POSITION=1;"
mysql -uroot -p"${ROOT_PASS}" -e "START SLAVE;"
sleep 2
echo "[5b] Replication status summary"
mysql -uroot -p"${ROOT_PASS}" -e "SHOW SLAVE STATUS\\G" | grep -E 'Slave_IO_Running|Slave_SQL_Running|Seconds_Behind_Master' || true
echo "[5c] read_only flags (before re-enable)"
mysql -uroot -p"${ROOT_PASS}" -e "SHOW VARIABLES LIKE 'read_only'; SHOW VARIABLES LIKE 'super_read_only';"
# Re-enable read_only after initial load
mysql -uroot -p"${ROOT_PASS}" -e "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;"
echo "[5d] read_only flags (after re-enable)"
mysql -uroot -p"${ROOT_PASS}" -e "SHOW VARIABLES LIKE 'read_only'; SHOW VARIABLES LIKE 'super_read_only';"

echo "[6/6] Validate with sysbench (commands as provided in the TP)"
# Temporarily disable read_only for sysbench table creation, then re-enable after
mysql -uroot -p"${ROOT_PASS}" -e "SET GLOBAL super_read_only=OFF; SET GLOBAL read_only=OFF;"
# Prepare
sudo sysbench /usr/share/sysbench/oltp_read_only.lua --mysql-db=sakila --mysql-user="root" --mysql-password="${ROOT_PASS}" prepare
# Run
sudo sysbench /usr/share/sysbench/oltp_read_only.lua --mysql-db=sakila --mysql-user="root" --mysql-password="${ROOT_PASS}" run
# Re-enable read_only after sysbench
mysql -uroot -p"${ROOT_PASS}" -e "SET GLOBAL read_only=ON; SET GLOBAL super_read_only=ON;"

echo "Worker setup complete."