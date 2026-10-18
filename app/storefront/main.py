"""Mahi Stores storefront.

Serves the shop UI and proxies the support chat widget to one of three real
agent backends (`agent-insecure` / `order-agent` / `refund-agent`). The
customer only ever picks "Legacy" vs "Zero-trust" (`insecure` vs `secure`)
in the UI -- which of the two real zero-trust identities actually handles a
"secure" request is decided here, automatically, by `_resolve()`. The
agent's identity/credential telemetry comes back on every chat response and
the UI renders it in the "Agentic Workflow" panel -- deliberately a plain
polled JSON state rather than an SSE stream, so there is nothing to
silently disconnect on stage.
"""
from __future__ import annotations

import os
import re
import time

import httpx
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import db

AGENT_URLS = {
    "insecure": os.environ.get("AGENT_INSECURE_URL", "http://localhost:8001"),
    "order": os.environ.get("AGENT_ORDER_URL", "http://localhost:8003"),
    "refund": os.environ.get("AGENT_REFUND_URL", "http://localhost:8002"),
}

# thread_id -> which real backend ("order" | "refund") is handling this
# "secure"-mode conversation, so a resume (no message to classify) or a
# revoke lands on the same identity that started the turn.
_secure_routing: dict[str, str] = {}

_REFUND_INTENT_RE = re.compile(r"refund", re.IGNORECASE)


def _resolve(agent: str, thread_id: str, message: str | None = None) -> str:
    """Picks the real backend for a public `agent` value. "insecure" maps
    straight through. "secure" is a dispatch, not a backend: order-agent
    (read-only) by default -- least privilege, don't hand out refund
    capability unless the task needs it -- escalating to refund-agent only
    when the message actually asks for a refund. This classifier is a UX
    convenience, not the security boundary: a mis-route to order-agent
    fails cleanly (a `denied` event, see actions.py's issue_refund) rather
    than granting anything, because Vault/PostgreSQL enforce the real
    boundary regardless of what this guesses."""
    if agent != "secure":
        return agent
    if message and _REFUND_INTENT_RE.search(message):
        backend = "refund"
    else:
        backend = _secure_routing.get(thread_id, "order")
    _secure_routing[thread_id] = backend
    return backend


app = FastAPI(title="Mahi Stores")

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
    if req.agent not in ("insecure", "secure"):
        raise HTTPException(400, f"unknown agent '{req.agent}'")
    backend = _resolve(req.agent, req.thread_id, req.message)
    try:
        r = httpx.post(
            f"{AGENT_URLS[backend]}/chat",
            json={
                "customer_id": req.customer_id,
                "message": req.message,
                "thread_id": req.thread_id,
            },
            timeout=30.0,
        )
        r.raise_for_status()
    except httpx.HTTPError as exc:
        raise HTTPException(502, f"agent '{backend}' unreachable: {exc}") from exc
    payload = r.json()
    _record(payload.get("events", []))
    return payload


# ---- human-token cache: real OBO delegation --------------------------
# scripts/presenter-login.sh declares "a human is present, call them X"
# once before a demo window -- NOT a real IdP login (see docs/RUNBOOK.md's
# Phase 0b finding: IBM Verify's documented token-exchange grant never
# mentions RAR at all, so this repo signs the delegated token itself; see
# app/agent/src/agent/obo.py). `sub` is fixed to "human-approver" because
# that's the literal external_id terraform/obo.tf's entity-alias is bound
# to -- the display name is cosmetic, the sub is what Vault actually
# resolves to an entity and its policy.
_HUMAN_TOKEN_TTL_SECONDS = 1800  # 30 minutes -- long enough for a rehearsal, short enough to force a fresh presenter-login before the real talk
_human_token: dict | None = None  # {display_name, sub, cached_at}


def _valid_human_token() -> dict | None:
    if _human_token is None:
        return None
    if time.time() - _human_token["cached_at"] > _HUMAN_TOKEN_TTL_SECONDS:
        return None
    return _human_token


class HumanTokenRequest(BaseModel):
    display_name: str


@app.post("/api/admin/human-token")
def api_set_human_token(req: HumanTokenRequest):
    global _human_token
    _human_token = {"display_name": req.display_name, "sub": "human-approver", "cached_at": time.time()}
    return {"ok": True}


@app.get("/api/admin/human-token")
def api_get_human_token():
    """Status only -- never the token itself. Polled by the Agentic
    Workflow's approval card to render the identity chip / disabled state."""
    token = _valid_human_token()
    if token is None:
        return {"present": False}
    remaining = _HUMAN_TOKEN_TTL_SECONDS - (time.time() - token["cached_at"])
    return {"present": True, "display_name": token["display_name"], "expires_in": int(remaining)}


class ResumeRequest(BaseModel):
    agent: str
    thread_id: str = "demo"
    approved_by: str | None = None  # insecure-mode fallback only; secure mode derives it from the cached human token


@app.post("/api/support/resume")
def api_resume(req: ResumeRequest):
    if req.agent not in ("insecure", "secure"):
        raise HTTPException(400, f"unknown agent '{req.agent}'")
    # No message to classify on resume -- reuses whichever backend this
    # thread already routed to in api_chat.
    backend = _resolve(req.agent, req.thread_id)

    body = {"thread_id": req.thread_id}
    if req.agent == "secure":
        token = _valid_human_token()
        if token is None:
            raise HTTPException(409, "no human credential cached -- run scripts/presenter-login.sh")
        body["approved_by"] = token["display_name"]
        body["subject_token"] = token["sub"]
    else:
        body["approved_by"] = req.approved_by or "anonymous"

    try:
        r = httpx.post(f"{AGENT_URLS[backend]}/resume", json=body, timeout=30.0)
        r.raise_for_status()
    except httpx.HTTPError as exc:
        raise HTTPException(502, f"agent '{backend}' unreachable: {exc}") from exc
    payload = r.json()
    _record(payload.get("events", []))
    return payload


class RevokeRequest(BaseModel):
    agent: str = "secure"
    thread_id: str = "demo"


@app.post("/api/admin/revoke")
def api_revoke(req: RevokeRequest):
    """Beat 2's money shot: force the currently live Vault lease to die on
    command instead of waiting out its TTL."""
    backend = _resolve(req.agent, req.thread_id)
    try:
        r = httpx.post(f"{AGENT_URLS[backend]}/vault/revoke", timeout=10.0)
        r.raise_for_status()
    except httpx.HTTPError as exc:
        raise HTTPException(502, f"agent '{backend}' unreachable: {exc}") from exc
    payload = r.json()
    _record(payload.get("events", []))
    return payload


# order-agent's plausible mistake is more MONEY privilege (there's no DB
# role above refund-writer to test refund-agent against); refund-agent's
# is PII exposure (terraform/vault-config.tf's customer-pii-reader role,
# never in its real policy outside the deliberate widen window). One
# escalation target per agent, not user-choosable -- picking an arbitrary
# role here would be testing nothing real.
_CEILING_TARGET_ROLE = {"order": "refund-writer", "refund": "customer-pii-reader"}


class CeilingTestRequest(BaseModel):
    agent: str = "order"


@app.post("/api/admin/ceiling-test")
def api_ceiling_test(req: CeilingTestRequest):
    """Makes scripts/04-verify-agentic-iam.sh's ceiling-misconfiguration
    probe clickable on stage: asks the named agent's own real Vault token
    to attempt its escalation-target role. Adds no new grant anywhere --
    just asks the agent to try with what it already has. Denied normally;
    only succeeds during a deliberate live policy-widen in the presenter's
    terminal, and self-revokes immediately if it does."""
    backend = req.agent if req.agent in _CEILING_TARGET_ROLE else "order"
    target_role = _CEILING_TARGET_ROLE[backend]
    try:
        r = httpx.post(
            f"{AGENT_URLS[backend]}/debug/ceiling-probe",
            json={"target_role": target_role},
            timeout=10.0,
        )
        r.raise_for_status()
    except httpx.HTTPError as exc:
        raise HTTPException(502, f"agent '{backend}' unreachable: {exc}") from exc
    event = r.json()
    _record([event])
    return {"events": [event]}


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
    _secure_routing.clear()
    return {"ok": True}
