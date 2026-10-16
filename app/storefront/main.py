"""Nimbus Store storefront.

Serves the shop UI and proxies the support chat widget to one of two agent
services (`agent-insecure` / `agent-secure`), so the audience can flip
between them mid-demo. The agent's identity/credential telemetry comes back
on every chat response and the UI renders it in the "Identity & Access"
panel -- deliberately a plain polled JSON state rather than an SSE stream,
so there is nothing to silently disconnect on stage.
"""
from __future__ import annotations

import os
import time

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import db

AGENT_URLS = {
    "insecure": os.environ.get("AGENT_INSECURE_URL", "http://localhost:8001"),
    "secure": os.environ.get("AGENT_SECURE_URL", "http://localhost:8002"),
}

app = FastAPI(title="Nimbus Store")

STATIC_DIR = os.path.join(os.path.dirname(__file__), "static")
app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

# Most recent panel-relevant events, newest last. Capped so a long rehearsal
# session doesn't grow this unboundedly; the UI only ever renders the tail.
_panel_log: list[dict] = []
_MAX_LOG = 200


def _record(events: list[dict]) -> None:
    for e in events:
        e.setdefault("ts", time.time())
        _panel_log.append(e)
    del _panel_log[:-_MAX_LOG]


@app.get("/")
def index():
    return FileResponse(os.path.join(STATIC_DIR, "index.html"))


@app.get("/api/products")
def api_products():
    return db.list_products()


@app.get("/api/customers")
def api_customers():
    return db.list_customers()


@app.get("/api/orders")
def api_orders(customer_id: int | None = None):
    return db.list_orders(customer_id)


@app.get("/api/orders/{order_id}")
def api_order(order_id: int):
    order = db.get_order(order_id)
    if order is None:
        raise HTTPException(404, "no such order")
    return order


@app.get("/api/state")
def api_state():
    """Polled by the panel. Returns the tail of the event log plus whichever
    agent's session state is currently live, so a page refresh mid-demo
    doesn't lose the picture."""
    statuses = {}
    for mode, base in AGENT_URLS.items():
        try:
            r = httpx.get(f"{base}/status", timeout=2.0)
            r.raise_for_status()
            statuses[mode] = r.json()
        except httpx.HTTPError:
            statuses[mode] = {"available": False}
    return {"log": _panel_log[-40:], "agents": statuses}


class ChatRequest(BaseModel):
    customer_id: int
    agent: str  # "insecure" | "secure"
    message: str
    thread_id: str = "demo"


@app.post("/api/support/chat")
def api_chat(req: ChatRequest):
    if req.agent not in AGENT_URLS:
        raise HTTPException(400, f"unknown agent '{req.agent}'")
    try:
        r = httpx.post(
            f"{AGENT_URLS[req.agent]}/chat",
            json={
                "customer_id": req.customer_id,
                "message": req.message,
                "thread_id": req.thread_id,
            },
            timeout=30.0,
        )
        r.raise_for_status()
    except httpx.HTTPError as exc:
        raise HTTPException(502, f"agent '{req.agent}' unreachable: {exc}") from exc
    payload = r.json()
    _record(payload.get("events", []))
    return payload


class ResumeRequest(BaseModel):
    agent: str
    thread_id: str = "demo"
    approved_by: str


@app.post("/api/support/resume")
def api_resume(req: ResumeRequest):
    if req.agent not in AGENT_URLS:
        raise HTTPException(400, f"unknown agent '{req.agent}'")
    try:
        r = httpx.post(
            f"{AGENT_URLS[req.agent]}/resume",
            json={"thread_id": req.thread_id, "approved_by": req.approved_by},
            timeout=30.0,
        )
        r.raise_for_status()
    except httpx.HTTPError as exc:
        raise HTTPException(502, f"agent '{req.agent}' unreachable: {exc}") from exc
    payload = r.json()
    _record(payload.get("events", []))
    return payload


class RevokeRequest(BaseModel):
    agent: str = "secure"


@app.post("/api/admin/revoke")
def api_revoke(req: RevokeRequest):
    """Beat 2's money shot: force the currently live Vault lease to die on
    command instead of waiting out its TTL."""
    try:
        r = httpx.post(f"{AGENT_URLS[req.agent]}/vault/revoke", timeout=10.0)
        r.raise_for_status()
    except httpx.HTTPError as exc:
        raise HTTPException(502, f"agent '{req.agent}' unreachable: {exc}") from exc
    payload = r.json()
    _record(payload.get("events", []))
    return payload


@app.post("/api/admin/forget")
def api_forget():
    """Tells every agent to drop its cached Vault credential without
    calling Vault itself -- pairs with an out-of-band
    `vault lease revoke -prefix` (scripts/reset.sh) so a stale cache
    doesn't keep serving an already-dead lease."""
    results = {}
    for mode, base in AGENT_URLS.items():
        try:
            r = httpx.post(f"{base}/vault/forget", timeout=5.0)
            results[mode] = r.status_code == 200
        except httpx.HTTPError:
            results[mode] = False
    return results


@app.post("/api/admin/reset")
def api_reset():
    """Between-rehearsals reset: orders back to pre-refund state, event log
    cleared. Does not touch Vault leases -- run `scripts/reset.sh` for that."""
    db.reset_demo_state()
    _panel_log.clear()
    return {"ok": True}
