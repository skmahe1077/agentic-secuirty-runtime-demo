"""Real Vault OBO (on-behalf-of) delegation -- the replacement for the
old free-text "type a name" approval, which minted a Vault child token
with the SAME policies as the parent (no real delegation, nothing Vault
checked against a human identity). See docs/RUNBOOK.md's "OBO -- what
was actually tested" for the empirical result this is built on:
terraform/obo.tf's "obo-probe" OAuth resource-server profile enforces the
three-way intersection (ceiling policy ∧ the human's own policy ∧ RAR
authorization_details) on a correctly-shaped token -- `act.sub` + `jti`
present, `aud: vault`.

No real IdP is involved. Production would have a real IdP's token
endpoint do an RFC 8693 token exchange and hand back a signed JWT; IBM
Verify was checked (docs.verify.ibm.com) and its documented token-exchange
grant never mentions RFC 9396 `authorization_details` at all -- not an
untested assumption, an absence in the vendor's own docs. So this module
signs the token itself, with the same throwaway key
terraform/obo.tf registered on Vault's "obo-probe" profile
(k8s_manifests/agent-secure/secret-obo.yaml). What Vault enforces on
receipt is identical either way; only the signer changes. Say so on
stage -- this is the "what's not real here" line for this beat.
"""
from __future__ import annotations

import time
import uuid
from dataclasses import dataclass

import jwt

from config import Settings


class OboUnavailable(Exception):
    """Raised when this agent has no OBO signing key configured (e.g.
    order-agent, which never issues refunds and so was never given one --
    see k8s_manifests/order-agent/deployment.yaml's lack of OBO_* env vars)."""


def authorization_details(path: str, capabilities: list[str]) -> list[dict]:
    """The RAR claim shape terraform/obo.tf's probe and
    scripts/mint_rar_jwt.py both use -- keep these in sync."""
    return [{"type": "vault:path_access", "path": path, "capabilities": capabilities}]


@dataclass(frozen=True)
class DelegatedToken:
    token: str
    human_sub: str
    agent_sub: str
    authorization_details: list[dict]


def exchange(settings: Settings, path: str, capabilities: list[str], ttl_seconds: int = 60) -> DelegatedToken:
    """Mints ONE delegated OBO token, fresh, for ONE Vault call -- never
    cached, never reused (replay protection is the `jti` claim; Vault's
    `unique_id_claim` config expects a fresh one every time). The human
    half of this isn't independently verified here -- there's no real IdP
    to check a subject token against -- it's asserted by whoever ran
    scripts/presenter-login.sh. That's the honest boundary of this demo
    shortcut: say so on stage, don't claim this proves the human
    authenticated."""
    s = settings
    if not (s.obo_private_key_path and s.obo_issuer and s.obo_human_sub and s.obo_agent_sub):
        raise OboUnavailable(f"{s.agent_name} has no OBO signing key configured")

    with open(s.obo_private_key_path) as f:
        private_key = f.read()

    now = int(time.time())
    rar = authorization_details(path, capabilities)
    claims = {
        "iss": s.obo_issuer,
        "sub": s.obo_human_sub,
        "act": {"sub": s.obo_agent_sub},
        "aud": "vault",
        "iat": now,
        "exp": now + ttl_seconds,
        "jti": str(uuid.uuid4()),
        "authorization_details": rar,
    }
    token = jwt.encode(claims, private_key, algorithm="RS256", headers={"kid": s.obo_kid})
    return DelegatedToken(token=token, human_sub=s.obo_human_sub, agent_sub=s.obo_agent_sub, authorization_details=rar)
