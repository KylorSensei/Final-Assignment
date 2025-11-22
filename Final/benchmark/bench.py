#!/usr/bin/env python3
"""
Benchmark minimal via Gatekeeper:
- Envoie 1000 READ et 1000 WRITE pour chaque stratégie (direct, random, custom)
- Utilise /query du Gatekeeper (POST JSON {"sql": "..."}), header X-API-Key: changeme
- Lit l'IP publique du Gatekeeper depuis Final/infra/instances.json
"""

import asyncio
import aiohttp
import time
import csv
import os
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INFRA = ROOT / "infra" / "instances.json"

API_KEY = os.getenv("API_KEY", "changeme")
CONCURRENCY = int(os.getenv("CONCURRENCY", "100"))
NUM_REQUESTS = int(os.getenv("NUM_REQUESTS", "1000"))

READ_SQL = "SELECT COUNT(*) AS cnt FROM film;"
CREATE_TABLE_SQL = "CREATE TABLE IF NOT EXISTS test_bench (id INT AUTO_INCREMENT PRIMARY KEY, txt VARCHAR(255));"
WRITE_SQL = "INSERT INTO test_bench(txt) VALUES ('x');"

STRATEGIES = ["direct", "random", "custom"]


def gatekeeper_base_url() -> str:
    with open(INFRA, "r", encoding="utf-8") as f:
        data = json.load(f)
    gk_ip = data["gatekeeper"].get("public_ip") or data["gatekeeper"].get("private_ip")
    if not gk_ip:
        raise SystemExit("Gatekeeper IP not found in Final/infra/instances.json")
    return f"http://{gk_ip}"


async def post_sql(session: aiohttp.ClientSession, base: str, sql: str, strategy: str):
    url = f"{base}/query?strategy={strategy}"
    headers = {
        "X-API-Key": API_KEY,
        "Content-Type": "application/json",
    }
    try:
        async with session.post(url, json={"sql": sql}, headers=headers) as resp:
            status = resp.status
            # try json, else text
            try:
                body = await resp.json()
            except Exception:
                body = await resp.text()
            return status, body
    except Exception as e:
        return None, str(e)


async def run_many(session: aiohttp.ClientSession, base: str, sql: str, strategy: str, n: int):
    sem = asyncio.Semaphore(CONCURRENCY)

    async def one(i: int):
        async with sem:
            return await post_sql(session, base, sql, strategy)

    tasks = [asyncio.create_task(one(i)) for i in range(n)]
    results = await asyncio.gather(*tasks)
    return results


async def run_block(label: str, base: str, sql: str, strategy: str, n: int, writer):
    start = time.time()
    async with aiohttp.ClientSession() as session:
        results = await run_many(session, base, sql, strategy, n)
    duration = time.time() - start
    success = sum(1 for r in results if r[0] == 200)
    avg = duration / n if n else 0.0

    print(f"[{label}] success={success}/{n} total={duration:.2f}s avg={avg:.4f}s")
    writer.writerow([label, strategy, n, success, f"{duration:.4f}", f"{avg:.6f}"])


async def main():
    base = gatekeeper_base_url()
    print(f"Gatekeeper: {base}")

    out_dir = ROOT / "benchmark" / "results"
    out_dir.mkdir(parents=True, exist_ok=True)
    csv_path = out_dir / "results.csv"

    with open(csv_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["Label", "Strategy", "Requests", "Success", "Total (s)", "Avg (s)"])

        # Prépare la table pour WRITE
        async with aiohttp.ClientSession() as session:
            st, body = await post_sql(session, base, CREATE_TABLE_SQL, "direct")
            print(f"[prepare CREATE TABLE] status={st} body={body}")

        # Pour chaque stratégie: 1000 READ + 1000 WRITE
        for strat in STRATEGIES:
            await run_block(f"READ {strat}", base, READ_SQL, strat, NUM_REQUESTS, writer)
            await run_block(f"WRITE {strat}", base, WRITE_SQL, strat, NUM_REQUESTS, writer)

    print(f"✅ Résultats écrits: {csv_path}")


if __name__ == "__main__":
    asyncio.run(main())