#!/usr/bin/env python3
import os
import json
import time
import random
from pathlib import Path
from typing import List, Tuple, Any, cast

from fastapi import FastAPI, HTTPException, Query
from pydantic import BaseModel
import uvicorn

import mysql.connector
from mysql.connector import Error as MySQLError


APP_DIR = Path(__file__).resolve().parent
CONFIG_PATH = APP_DIR / "config.json"

# Load config (written by boto_up_final.py)
with open(CONFIG_PATH, "r", encoding="utf-8") as f:
    CONFIG = json.load(f)

MANAGER = CONFIG["manager"]                      # {"host": "...", "port": 3306}
WORKERS: List[dict] = CONFIG.get("workers", [])  # [{"host":"...", "port":3306}, ...]

LISTEN_PORT = int(CONFIG.get("listen_port", 8080))

# Credentials from environment (keep it minimal and configurable)
DB_USER = os.getenv("DB_USER", "app")
DB_PASSWORD = os.getenv("DB_PASSWORD", "password")
DB_NAME = os.getenv("DB_NAME", "sakila")

app = FastAPI(title="Simple DB Proxy (Trusted Host)")


class QueryBody(BaseModel):
    sql: str


def classify_sql(sql: str) -> str:
    s = sql.lstrip().lower()
    # Minimal classifier: READ if SELECT (and not FOR UPDATE), otherwise WRITE
    if s.startswith("select") and "for update" not in s:
        return "read"
    return "write"


def connect(host: str, port: int):
    return mysql.connector.connect(
        host=host,
        port=port,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME,
        connection_timeout=5,
    )


def exec_read(sql: str, host: str, port: int) -> Tuple[List[str], List[Tuple[Any, ...]]]:
    conn = None
    try:
        conn = connect(host, port)
        cur = conn.cursor()
        cur.execute(sql)
        rows_raw = cur.fetchall()
        rows: List[Tuple[Any, ...]] = cast(List[Tuple[Any, ...]], rows_raw if rows_raw is not None else [])
        colnames = [desc[0] for desc in cur.description] if cur.description else []
        return colnames, rows
    finally:
        try:
            if conn:
                conn.close()
        except Exception:
            pass


def exec_write(sql: str, host: str, port: int) -> int:
    conn = None
    try:
        conn = connect(host, port)
        cur = conn.cursor()
        cur.execute(sql)
        affected = cur.rowcount
        conn.commit()
        return affected
    finally:
        try:
            if conn:
                conn.close()
        except Exception:
            pass


def latency_ms(host: str, port: int) -> float:
    # Minimal latency measurement: connect + simple SELECT 1
    start = time.perf_counter()
    conn = None
    try:
        conn = connect(host, port)
        cur = conn.cursor()
        cur.execute("SELECT 1")
        _ = cur.fetchone()
    except Exception:
        return float("inf")
    finally:
        try:
            if conn:
                conn.close()
        except Exception:
            pass
    return (time.perf_counter() - start) * 1000.0


@app.get("/health")
def health():
    return {
        "manager": MANAGER,
        "workers": WORKERS,
        "db_user": DB_USER,
        "db_name": DB_NAME,
    }


@app.post("/query")
def query(body: QueryBody, strategy: str = Query("direct", regex="^(direct|random|custom)$")):
    """
    Minimal proxy:
    - Classify SQL as READ/WRITE.
    - Strategies:
        direct: toujours manager
        random: READ -> worker aléatoire ; WRITE -> manager
        custom: READ -> worker avec plus faible latence ; WRITE -> manager
    """
    sql = body.sql
    op = classify_sql(sql)

    target = MANAGER  # default for direct and for all WRITEs
    chosen = "manager"

    if strategy == "random" and op == "read":
        if not WORKERS:
            raise HTTPException(status_code=503, detail="No workers available for READ")
        target = random.choice(WORKERS)
        chosen = f"worker(random) {target['host']}"

    elif strategy == "custom" and op == "read":
        if not WORKERS:
            raise HTTPException(status_code=503, detail="No workers available for READ")
        # Pick worker with minimal simple latency (fallback to random if none measurable)
        best = None
        best_ms = float("inf")
        for w in WORKERS:
            ms = latency_ms(w["host"], int(w["port"]))
            if ms < best_ms:
                best_ms = ms
                best = w
        if best is None:
            target = random.choice(WORKERS)
            chosen = f"worker(custom,fallback) {target['host']}"
        else:
            target = best
            chosen = f"worker(custom,min-lat) {target['host']} ({best_ms:.1f}ms)"

    host = target["host"]
    port = int(target["port"])

    try:
        if op == "read":
            cols, rows = exec_read(sql, host, port)
            return {
                "target": chosen,
                "operation": op,
                "columns": cols,
                "rows": rows,
                "count": len(rows),
            }
        else:
            affected = exec_write(sql, host, port)
            return {
                "target": chosen,
                "operation": op,
                "affected": affected,
            }
    except MySQLError as e:
        raise HTTPException(status_code=502, detail=f"MySQL error: {e}")
    except Exception as e:
        raise HTTPException(status_code=502, detail=str(e))


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=LISTEN_PORT)