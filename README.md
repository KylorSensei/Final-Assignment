# Final Assignment — Cloud Design Patterns: Implementing a DB Cluster (AWS EC2 + MySQL + Proxy + Gatekeeper)

End-to-end automation for:
- Provision a MySQL cluster (1 manager + 2 workers) on EC2
- Install Sakila on each instance and configure replication (GTID, manager→workers)
- Deploy a Proxy (Trusted Host) and a Gatekeeper (internet-facing)
- Apply 3 routing strategies (direct, random, custom/min-latency)
- Run a benchmark (1000 READ + 1000 WRITE) per strategy via the Gatekeeper
- Produce CSV results and a LaTeX report

Internal references:
- IaC/Provision: [Final/scripts/boto_up_final.py](Final/scripts/boto_up_final.py:1)
- MySQL bootstrap: [Final/scripts/bootstrap_mysql.sh](Final/scripts/bootstrap_mysql.sh:1), [Final/db/setup_manager.sh](Final/db/setup_manager.sh:1), [Final/db/setup_worker.sh](Final/db/setup_worker.sh:1)
- Proxy (Trusted Host): [Final/proxy/app.py](Final/proxy/app.py:1), [Final/scripts/deploy_proxy.sh](Final/scripts/deploy_proxy.sh:1)
- Gatekeeper: [Final/gatekeeper/app.py](Final/gatekeeper/app.py:1), [Final/scripts/deploy_gatekeeper.sh](Final/scripts/deploy_gatekeeper.sh:1)
- Benchmark: [Final/benchmark/bench.py](Final/benchmark/bench.py:1)
- Orchestration: [Final/scripts/run_demo.sh](Final/scripts/run_demo.sh:1), [Final/scripts/boto_down_final.py](Final/scripts/boto_down_final.py:1)

## 0) What you get

- Instances:
  - 1× t2.large Gatekeeper (HTTP :80, public)
  - 1× t2.large Proxy (HTTP :8080, private; Trusted Host)
  - 3× t2.micro MySQL (1 manager, 2 workers; 3306)
- Security:
  - Internet → Gatekeeper:80 only
  - Gatekeeper → Proxy:8080 (intra-VPC)
  - Proxy ↔ MySQL:3306 (intra-VPC); intra-MySQL allowed (replication)
- Outputs:
  - Final/infra/instances.json (inventory of IPs)
  - Final/proxy/config.json (DB routing targets for the Proxy)
  - Final/benchmark/results/results.csv (benchmark results)

## 1) Layout (Final/)

```
Final/
├─ scripts/
│  ├─ run_demo.sh              # End-to-end orchestration (provision → bootstrap → deploy → bench)
│  ├─ boto_up_final.py         # Provision EC2 + SG; writes infra/instances.json & proxy/config.json
│  ├─ boto_down_final.py       # Clean teardown (instances + SGs)
│  ├─ bootstrap_mysql.sh       # SSH orchestration for manager & workers (Sakila + replication + sysbench)
│  ├─ deploy_proxy.sh          # Deploy Proxy (Trusted Host) :8080
│  └─ deploy_gatekeeper.sh     # Deploy Gatekeeper :80 (sudo/PY)
├─ db/
│  ├─ setup_manager.sh         # Install MySQL/Sakila/sysbench, GTID, users app/repl, sysbench
│  └─ setup_worker.sh          # Install + read_only/super_read_only + replication + sysbench
├─ proxy/
│  ├─ app.py                   # FastAPI: READ/WRITE classification + direct/random/custom strategies
│  └─ config.json              # Generated (manager/workers)
├─ gatekeeper/
│  └─ app.py                   # FastAPI: X-API-Key, SQL validation, forward to Proxy
├─ benchmark/
│  ├─ bench.py                 # 1000 READ + 1000 WRITE/strategy via Gatekeeper
│  └─ results/results.csv      # Results (generated)
└─ infra/
   └─ instances.json           # Provisioned IPs (generated)
```

## 2) Prerequisites

- AWS account with EC2 permissions
- Local tools (for IaC/bench):
  - Python 3.10+
  - bash
  - Python packages:
    ```
    pip install -U pip
    pip install -r Final/requirements.txt
    ```
- Environment variables:
  ```
  export AWS_ACCESS_KEY_ID="..."
  export AWS_SECRET_ACCESS_KEY="..."
  export AWS_SESSION_TOKEN="..."        # if temporary tokens
  export AWS_DEFAULT_REGION="us-east-1"
  export KEY_NAME="assignment_final"    # existing EC2 key pair in the region
  export KEY_PEM="/path/to/assignment_final.pem"  # local .pem file
  ```

## 3) Quick start (one command)

From the repo root:
```
bash Final/scripts/run_demo.sh
```

This script:
1) Provisions 5 instances (2× t2.large + 3× t2.micro) + SGs
2) Installs MySQL/Sakila/sysbench; configures GTID/replication; runs sysbench (validation)
3) Deploys the Proxy (:8080) and the Gatekeeper (:80)
4) Runs the benchmark via Gatekeeper (1000 READ + 1000 WRITE per strategy)
5) Prints paths to output files

## 4) Component details

### 4.1 MySQL (Manager + Workers)
- Manager:
  - MySQL 8.0, GTID ON, binlog ROW, bind-address 0.0.0.0
  - Users:
    - app/password (ALL PRIVILEGES on sakila)
    - repl/replpass (REPLICATION SLAVE)
- Workers:
  - MySQL 8.0, read_only + super_read_only
  - GTID replication AUTO_POSITION=1 from manager
  - Sakila import done during a short read_only disable, then re-enabled

Validation: sysbench (oltp_read_only.lua) executed on each node.

### 4.2 Proxy (Trusted Host)
- FastAPI service on :8080
- DB credentials via env (default: app/password, DB sakila)
- Classification:
  - READ: SELECT/SHOW/DESC/DESCRIBE/EXPLAIN (not FOR UPDATE)
  - WRITE: INSERT/UPDATE/DELETE/REPLACE/DDL …
- Strategies:
  - direct: everything → manager
  - random: READ → random worker; WRITE → manager
  - custom: READ → min-latency worker (SELECT 1), fallback random; WRITE → manager

### 4.3 Gatekeeper
- Only internet-facing instance (HTTP :80)
- Simple auth: X-API-Key header (default: changeme)
- Input validation: block dangerous commands (DROP/TRUNCATE/ALTER…)
- Forwards internally to Proxy (private VPC)

## 5) Architecture (overview)

```mermaid
graph TD
  U[User] -->|HTTP/80| GK[Gatekeeper]
  GK -->|Validated request| PX[Proxy (Trusted Host)]
  PX -->|WRITE| M[(MySQL Manager)]
  PX -->|READ| W1[(Worker 1)]
  PX -->|READ| W2[(Worker 2)]
  M == Replication ==> W1
  M == Replication ==> W2
```

## 6) Endpoints (for tests)

- Gatekeeper:
  - GET /health
  - POST /query?strategy=(direct|random|custom)  Body: {"sql":"..."}  Headers: X-API-Key: changeme
- Proxy:
  - GET /health
  - POST /query?strategy=... (same semantics; not publicly exposed)

Examples:
```
GK=http://<GK_PUBLIC_IP>
curl -s $GK/health
curl -s -H "X-API-Key: changeme" -H "Content-Type: application/json" \
  -X POST "$GK/query?strategy=random" -d '{"sql":"SELECT COUNT(*) AS cnt FROM film;"}'
```

## 7) Benchmark

- Script: [Final/benchmark/bench.py](Final/benchmark/bench.py:1)
- Load: 1000 READ + 1000 WRITE per strategy (direct/random/custom)
- Concurrency: 100 (default; override with env CONCURRENCY)
- Example results:
  - READ direct: ~3.63s total
  - READ random: ~2.91s
  - READ custom: ~2.89s
  - WRITE direct: ~3.83s
  - WRITE random/custom: ~3.95s/~3.87s
- CSV: [Final/benchmark/results/results.csv](Final/benchmark/results/results.csv:1)

Observations:
- Distributed reads (random/custom) on workers outperform the direct strategy (manager).
- Writes go to the manager; differences between strategies are due to small selection overhead.

## 8) Security and compliance (Gatekeeper/Proxy)

- No direct database access from the internet.
- Gatekeeper: only public surface; authenticates and validates requests; forwards only to Proxy.
- Proxy (Trusted Host): private; decides READ/WRITE, applies the strategy, contacts manager/workers.
- SGs: minimal open ports (80 public; 8080/3306 intra-VPC).

## 9) Teardown

Recommended after each demo:
```
python Final/scripts/boto_down_final.py
```
Terminates instances and deletes SGs (with retries for AWS dependency propagation).

## 10) Troubleshooting (quick)

- APT locks/Cloud-init: handled by retries in scripts (“apt busy/failed” messages).
- Gatekeeper port 80: started with sudo; Python deps installed for root; controlled usage.
- CRLF on IPs: sanitation in place (avoids “%0d” in internal URLs).
- Remote MySQL root refused: not required; app user is used for app and bench.

## 11) Assignment compliance

- MySQL Standalone + Sakila + sysbench on 3× t2.micro: YES (install/validation on each instance)
- Replication manager → workers (GTID, read_only workers): YES
- Proxy pattern with 3 strategies (direct/random/custom): YES
- Gatekeeper (internet-facing, auth/validation, internal forwarding to Proxy): YES
- Benchmark 1000 READ + 1000 WRITE per strategy via Gatekeeper: YES (CSV produced)
- End-to-end IaC (AWS SDK/boto3): YES
- Documentation (README + LaTeX report): YES

## 12) Report

The LaTeX report is under Final/Report (see [Final/Report/main.tex](Final/Report/main.tex:1)).
To compile:
```
cd Final/Report
latexmk -pdf main.tex   # or run pdflatex twice
```

## 13) Costs

t2.large/t2.micro instances are not free-tier. Clean up after use with boto_down_final.py.
