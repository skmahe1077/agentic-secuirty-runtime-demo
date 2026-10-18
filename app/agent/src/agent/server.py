"""HTTP wrapper around one agent engine.

One image, two running shapes: `AGENT_MODE=insecure` with a static
database.Session, or `AGENT_MODE=secure` with a SPIFFE-backed VaultSession.
Which `Engine` implementation answers `/chat` is a separate axis
(`AGENT_ENGINE`), so the identity/credential story and the LLM-vs-test-mode
story can vary independently.
"""
from __future__ import annotations

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from config import load_settings
from deterministic_engine import DeterministicEngine
from vault import build_session

settings = load_settings()
session = build_session(settings)

if settings.agent_engine == "langchain":
    from langchain_engine import LangChainEngine  # heavy import, only when needed

    engine = LangChainEngine(settings, session)
else:
    engine = DeterministicEngine(settings, session)

app = FastAPI(title=f"agent ({settings.agent_mode})")


class ChatRequest(BaseModel):
    customer_id: int
    message: str
    thread_id: str = "demo"


@app.post("/chat")
def chat(req: ChatRequest):
    result = engine.handle_message(req.customer_id, req.message, req.thread_id)
    return {
        "reply": result.reply,
        "events": result.events,
        "requires_approval": result.requires_approval,
        "approval_id": result.approval_id,
        "approval_text": result.approval_text,
    }


class ResumeRequest(BaseModel):
    thread_id: str = "demo"
    approved_by: str
    # Real OBO delegation -- see app/storefront/main.py's cached
    # human-token and deterministic_engine.py's handle_resume. None means
    # fall back to the old free-text-metadata approval.
    subject_token: str | None = None


@app.post("/resume")
def resume(req: ResumeRequest):
    result = engine.handle_resume(req.thread_id, req.approved_by, req.subject_token)
    return {
        "reply": result.reply,
        "events": result.events,
        "requires_approval": result.requires_approval,
        "approval_id": result.approval_id,
        "approval_text": result.approval_text,
    }


@app.post("/vault/revoke")
def vault_revoke():
    event = session.revoke()
    if event is None:
        raise HTTPException(409, "no active credential to revoke")
    # revoke() can itself trigger a fresh Vault login (to get a client
    # authenticated enough to call sys/leases/revoke) if the cached client's
    # token had already expired -- drain that here so a stray auth_completed
    # event doesn't surface misattributed to some later, unrelated turn.
    session.auth_event()
    return {"events": [event]}


@app.post("/vault/forget")
def vault_forget():
    """Drops this process's cached credential/client without calling Vault
    -- use after revoking leases out of band (scripts/reset.sh) so the next
    request re-mints instead of retrying a lease Vault already killed."""
    session.forget()
    return {"ok": True}


@app.get("/status")
def status():
    return session.status()


class CeilingProbeRequest(BaseModel):
    # order-agent's test escalates into "refund-writer" (more money
    # privilege); refund-agent's test escalates into "customer-pii-reader"
    # (there's no role above refund-writer to escalate into, so the
    # plausible mistake for an agent that already moves money is PII
    # exposure instead). The storefront picks the right default per agent
    # -- this field lets it say so explicitly rather than this endpoint
    # guessing from its own identity.
    target_role: str = "refund-writer"


@app.post("/debug/ceiling-probe")
def ceiling_probe(req: CeilingProbeRequest = CeilingProbeRequest()):
    """Safe to call at any time -- see VaultSession.probe_ceiling(). Lets
    the Agentic Workflow UI show scripts/04-verify-agentic-iam.sh's ceiling-
    misconfiguration test live, driven by this agent's own real token."""
    return session.probe_ceiling(req.target_role)


@app.get("/healthz")
def healthz():
    return {"ok": True, "mode": settings.agent_mode, "engine": settings.agent_engine}
