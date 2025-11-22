#!/usr/bin/env bash
# Minimal bootstrap for MySQL Manager: install MySQL + Sakila + create users + enable replication (GTID) + sysbench
# Usage (on manager): sudo bash setup_manager.sh APP_PASS REPL_PASS ROOT_PASS
set -euo pipefail

APP_PASS="${1:-password}"
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
# On Ubuntu, root may be auth_socket; switch to password
mysql -uroot -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${ROOT_PASS}'; FLUSH PRIVILEGES;" || true

echo "[3/6] Enable replication (GTID) on manager and restart MySQL"
CNF="/etc/mysql/mysql.conf.d/mysqld.cnf"

# Ensure MySQL listens on all interfaces for Proxy/Workers
sed -i 's/^\s*bind-address\s*=.*/bind-address = 0.0.0.0/' "$CNF" || true
grep -q '^\s*bind-address' "$CNF" || echo "bind-address = 0.0.0.0" >> "$CNF"

# Ensure idempotency: remove prior lines we may have added
sed -i '/^server-id=/d' "$CNF" || true
sed -i '/^log_bin=/d' "$CNF" || true
sed -i '/^gtid_mode=/d' "$CNF" || true
sed -i '/^enforce_gtid_consistency=/d' "$CNF" || true
sed -i '/^binlog_format=/d' "$CNF" || true

cat >> "$CNF" <<EOF

# --- manager replication config (added by setup_manager.sh) ---
server-id=1
log_bin=/var/log/mysql/mysql-bin.log
gtid_mode=ON
enforce_gtid_consistency=ON
binlog_format=ROW
EOF

systemctl restart mysql
sleep 2

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

echo "[5/6] Create app and replication users"
mysql -uroot -p"${ROOT_PASS}" -e "CREATE USER IF NOT EXISTS 'app'@'%' IDENTIFIED BY '${APP_PASS}';"
mysql -uroot -p"${ROOT_PASS}" -e "GRANT ALL PRIVILEGES ON sakila.* TO 'app'@'%'; FLUSH PRIVILEGES;"
mysql -uroot -p"${ROOT_PASS}" -e "CREATE USER IF NOT EXISTS 'repl'@'%' IDENTIFIED BY '${REPL_PASS}';"
mysql -uroot -p"${ROOT_PASS}" -e "GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%'; FLUSH PRIVILEGES;"

echo "[6/6] Validate with sysbench (commands as provided in the TP)"
# Prepare
sudo sysbench /usr/share/sysbench/oltp_read_only.lua --mysql-db=sakila --mysql-user="app" --mysql-password="${APP_PASS}" prepare
# Run
sudo sysbench /usr/share/sysbench/oltp_read_only.lua --mysql-db=sakila --mysql-user="app" --mysql-password="${APP_PASS}" run

echo "Manager setup complete."