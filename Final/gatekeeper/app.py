#!/usr/bin/env python3
import os
import json
from typing import Dict

from fastapi import FastAPI, HTTPException, Request, Query
from pydantic import BaseModel
import uvicorn
import requests

app = FastAPI(title="Simple Gatekeeper")

API_KEY = os.getenv("API_KEY", "changeme")
# Either provide PROXY_URL directly (e.g., http://10.0.0.12:8080/query)
# or PROXY_HOST/PROXY_PORT to build it.
PROXY_URL = os.getenv("PROXY_URL")
if not PROXY_URL:
    proxy_host = os.getenv("PROXY_HOST", "127.0.0.1")
    proxy_port = int(os.getenv("PROXY_PORT", "8080"))
    PROXY_URL = f"http://{proxy_host}:{proxy_port}/query"


class QueryBody(BaseModel):
    sql: str


def is_safe_sql(sql: str) -> bool:
    """
    Validation minimale demandée: bloquer requêtes dangereuses évidentes.
    Sans sur-optimisation: simple détection par sous-chaînes.
    """
    s = sql.lower()
    blocked = ["drop ", "truncate ", "alter "]
    return not any(b in s for b in blocked)


@app.get("/health")
def health():
    return {"status": "ok", "proxy_url": PROXY_URL}


@app.post("/query")
def forward_query(
    request: Request,
    body: QueryBody,
    strategy: str = Query("direct")
):
    # AuthN simple via header X-API-Key
    api_key = request.headers.get("x-api-key")
    if api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Unauthorized")

    # Validation minimale
    if not is_safe_sql(body.sql):
        raise HTTPException(status_code=400, detail="Unsafe SQL detected")

    # Forward tel quel au Proxy (Trusted Host)
    try:
        resp = requests.post(f"{PROXY_URL}?strategy={strategy}", json={"sql": body.sql}, timeout=10)
        return resp.json(), resp.status_code
    except requests.RequestException as e:
        raise HTTPException(status_code=502, detail=f"Proxy unreachable: {e}")


if __name__ == "__main__":
    port = int(os.getenv("PORT", "80"))
    uvicorn.run(app, host="0.0.0.0", port=port)