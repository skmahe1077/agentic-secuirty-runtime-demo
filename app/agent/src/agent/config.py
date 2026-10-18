"""Environment-driven settings for one agent instance.

The same image runs as both `agent-insecure` and `agent-secure` -- which one
it is is entirely a function of AGENT_MODE plus which credentials it was
handed. That is itself part of the demo's point: the code doesn't "know" it
is insecure, the environment around it is just missing a security boundary.
"""
from __future__ import annotations

import os
from dataclasses import dataclass


def _bool(name: str, default: bool) -> bool:
    val = os.environ.get(name)
    if val is None:
        return default
    return val.strip().lower() in ("1", "true", "yes", "on")


@dataclass(frozen=True)
class Settings:
    agent_mode: str  # "insecure" | "secure"
    agent_name: str

    database_host: str
    database_port: int
    database_name: str

    # insecure path: a static, long-lived credential (the anti-pattern)
    static_db_user: str | None
    static_db_password: str | None
    static_credential_created_at: str  # ISO date, for the "age 47 days" beat

    # secure path: SPIFFE + Vault
    vault_addr: str
    vault_auth_mount: str
    vault_role: str
    vault_role_policy: str
    vault_db_mount: str
    vault_db_role: str
    svid_path: str
    # The Agent Registry's display_name for this agent (terraform/
    # agentic-iam.tf's vault_agent_registration) -- NOT the same string as
    # agent_name/vault_role, which are naming decisions made independently
    # over the life of this repo (refund-agent's VAULT_ROLE is
    # "ai-support-agent-secure", its AGENT_NAME is "support-agent-secure",
    # but its registry display_name is "refund-agent"). None for the
    # insecure agent, which isn't registered at all.
    vault_registry_name: str | None

    refund_approval_threshold_pence: int

    # Real OBO delegation (app/agent/src/agent/obo.py) -- None for any
    # agent that doesn't do refunds (order-agent, insecure). See
    # k8s_manifests/agent-secure/secret-obo.yaml and docs/RUNBOOK.md's
    # "OBO -- what was actually tested" for why this agent signs its own
    # delegated token rather than calling a real IdP's token endpoint.
    obo_private_key_path: str | None
    obo_issuer: str | None
    obo_kid: str | None
    obo_human_sub: str | None
    obo_agent_sub: str | None

    agent_engine: str  # "langchain" | "deterministic"
    anthropic_api_key: str | None
    anthropic_model: str


def load_settings() -> Settings:
    mode = os.environ.get("AGENT_MODE", "secure")
    return Settings(
        agent_mode=mode,
        agent_name=os.environ.get("AGENT_NAME", f"support-agent-{mode}"),
        database_host=os.environ.get("DATABASE_HOST", "localhost"),
        database_port=int(os.environ.get("DATABASE_PORT", "5432")),
        database_name=os.environ.get("DATABASE_NAME", "nimbus"),
        static_db_user=os.environ.get("STATIC_DB_USER", "nimbus_app_legacy"),
        static_db_password=os.environ.get("STATIC_DB_PASSWORD", "LegacyStaticPassword123!"),
        static_credential_created_at=os.environ.get("STATIC_CREDENTIAL_CREATED_AT", "2026-08-28"),
        vault_addr=os.environ.get("VAULT_ADDR", "http://vault.vault.svc.cluster.local:8200"),
        vault_auth_mount=os.environ.get("VAULT_AUTH_MOUNT", "spiffe"),
        vault_role=os.environ.get("VAULT_ROLE", "ai-support-agent"),
        vault_role_policy=os.environ.get("VAULT_ROLE_POLICY", "agent-support"),
        vault_db_mount=os.environ.get("VAULT_DB_MOUNT", "database"),
        vault_db_role=os.environ.get("VAULT_DB_ROLE", "refund-writer"),
        svid_path=os.environ.get("SVID_PATH", "/svids/jwt_svid.token"),
        vault_registry_name=os.environ.get("VAULT_REGISTRY_NAME"),
        refund_approval_threshold_pence=int(os.environ.get("REFUND_APPROVAL_THRESHOLD_PENCE", "10000")),
        obo_private_key_path=os.environ.get("OBO_PRIVATE_KEY_PATH"),
        obo_issuer=os.environ.get("OBO_ISSUER"),
        obo_kid=os.environ.get("OBO_KID"),
        obo_human_sub=os.environ.get("OBO_HUMAN_SUB"),
        obo_agent_sub=os.environ.get("OBO_AGENT_SUB"),
        agent_engine=os.environ.get("AGENT_ENGINE", "deterministic"),
        anthropic_api_key=os.environ.get("ANTHROPIC_API_KEY"),
        anthropic_model=os.environ.get("ANTHROPIC_MODEL", "claude-sonnet-5"),
    )
