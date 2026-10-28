"""Credential sessions for the two agent variants.

`StaticCredentialSession` is the anti-pattern beat 1 exists to criticise: one
password, handed out once, used forever, proving nothing about who or what
is asking.

`VaultSession` is the real story: a SPIFFE JWT-SVID exchanged for a Vault
token, which mints a database credential scoped to a single Vault role with
a short TTL. The credential is cached and reused across tool calls within
its lifetime (so the panel can show one lease ticking down across a whole
chat turn) rather than minted-and-revoked per query -- that is what makes an
explicit, on-stage `vault lease revoke` meaningful instead of a no-op.

Both classes implement the same small interface so `actions.py` does not
need to know which one it was handed:
    get_db_credentials() -> dict
    identity_event() -> dict | None
    auth_event() -> dict | None
    revoke() -> dict | None
    status() -> dict
"""
from __future__ import annotations

import base64
import json
import time

import hvac
import requests

from config import Settings
from obo import DelegatedToken


def _decode_jwt_payload(token: str) -> dict:
    """Decode (not verify) a compact JWS payload -- display only. Vault is
    the one actually verifying the signature on login; this is purely so the
    panel can show `sub` / `aud` / `exp` without a JWT library dependency."""
    try:
        payload_b64 = token.split(".")[1]
        padded = payload_b64 + "=" * (-len(payload_b64) % 4)
        return json.loads(base64.urlsafe_b64decode(padded))
    except Exception:
        return {}


# The real, per-role grant shape for the storefront's Agentic Workflow
# panel -- must stay in sync with terraform/vault-config.tf's three
# vault_database_secret_backend_role creation_statements. Keyed by Vault
# DB role name (VAULT_DB_ROLE / s.vault_db_role), not by agent, since the
# same session class serves both refund-agent (refund-writer) and
# order-agent (order-reader).
_DB_ROLE_SCOPES: dict[str, list[dict]] = {
    "refund-writer": [
        {"resource": "orders", "action": "SELECT/UPDATE", "allowed": True},
        {"resource": "refunds", "action": "INSERT", "allowed": True},
        {"resource": "customers", "action": "SELECT", "allowed": False},
    ],
    "order-reader": [
        {"resource": "orders", "action": "SELECT", "allowed": True},
        {"resource": "products", "action": "SELECT", "allowed": True},
        {"resource": "refunds", "action": "INSERT", "allowed": False},
        {"resource": "customers", "action": "SELECT", "allowed": False},
    ],
    "customer-pii-reader": [
        {"resource": "customers", "action": "SELECT", "allowed": True},
    ],
}


class StaticCredentialSession:
    """agent-insecure: a long-lived password, no identity, no scoping."""

    def __init__(self, settings: Settings):
        self.settings = settings
        self._announced = False

    def begin_turn(self) -> None:
        """Identity is allowed to announce once per chat turn, not once
        per pod lifetime -- see VaultSession.begin_turn()'s longer note."""
        self._announced = False

    def identity_event(self) -> dict | None:
        if self._announced:
            return None
        self._announced = True
        return {
            "type": "identity",
            "spiffe_id": None,
            "message": (
                f"{self.settings.agent_name} authenticated with a static password "
                f"(created {self.settings.static_credential_created_at}, no workload identity)"
            ),
        }

    def auth_event(self) -> dict | None:
        # No auth/spiffe login happens for this anti-pattern -- the "Auth"
        # stage in the storefront's Agentic Workflow panel has nothing to
        # report, which is itself the point.
        return None

    def get_db_credentials(self, approval_metadata: dict | None = None, obo_token: DelegatedToken | None = None) -> dict:
        # The anti-pattern this class models has no concept of per-request
        # scoping, so an approval -- real OBO or the old free-text kind --
        # has nowhere to attach; both are silently dropped, which is
        # itself part of the point.
        s = self.settings
        return {
            "username": s.static_db_user,
            "password": s.static_db_password,
            "host": s.database_host,
            "port": s.database_port,
            "dbname": s.database_name,
            "lease_id": "static/db-static-creds",
            "lease_role": "nimbus_app_legacy",
            "expires_at": None,  # never expires -- that's the point
            "ttl_seconds": None,
            "scope": [
                {"resource": "orders", "action": "SELECT/UPDATE", "allowed": True},
                {"resource": "refunds", "action": "INSERT", "allowed": True},
                {"resource": "customers", "action": "SELECT", "allowed": True},
            ],
            # No identity, no approval binding -- beat 1 content, not an
            # omission: there is nothing for the UI's correlation tile to
            # show for this credential.
            "approval": None,
        }

    def revoke(self) -> dict | None:
        return {
            "type": "info",
            "message": "there is nothing to revoke -- this credential has no lease and no expiry",
        }

    def status(self) -> dict:
        return {"available": True, "mode": "insecure", "identity": None, "lease": None}

    def forget(self) -> None:
        pass  # nothing cached -- this credential never changes, which is the point

    def probe_ceiling(self, target_role: str = "refund-writer") -> dict:
        return {
            "type": "ceiling_probe",
            "target_role": target_role,
            "allowed": None,
            "message": "not applicable -- this agent never touches Vault at all",
        }


class VaultSession:
    """agent-secure: SPIFFE identity -> Vault auth -> short-lived DB creds."""

    def __init__(self, settings: Settings):
        self.settings = settings
        self._client: hvac.Client | None = None
        self._cached: dict | None = None
        self._identity_announced = False
        # Set True only on a FRESH login (not when _client_logged_in() serves
        # the cached, already-authenticated client) -- consumed once by
        # auth_event(), so the storefront's "Auth" stage reflects an actual
        # auth/spiffe round trip, not every credential request.
        self._last_login_fresh = False
        # Agent Registry info (ceiling policy name) -- read once and
        # cached, not re-read on every /status poll: it's provisioning-time
        # fact (terraform/agentic-iam.tf), not something that changes
        # mid-demo. None until the first successful read; False means "read
        # attempted and failed," so we don't retry every poll forever.
        self._registry_info: dict | None | bool = None

    def begin_turn(self) -> None:
        """Identity is allowed to announce once per chat turn, not once
        per pod lifetime. `_identity_announced` previously never reset at
        all, so after this pod's very first turn ever handled, no later
        browser session -- on a long-running, repeatedly-demoed pod --
        would see the Identity/Agent stage light up again. Call this once
        at the start of handle_message()/handle_resume(), before any
        action runs. `_last_login_fresh` needs no equivalent reset: it's
        already driven by whether a real fresh Vault login just happened
        (the cached client's token staleness), which recurs naturally."""
        self._identity_announced = False

    # -- identity -----------------------------------------------------

    def _read_svid(self) -> tuple[str, dict]:
        with open(self.settings.svid_path, "r", encoding="utf-8") as f:
            token = f.read().strip()
        claims = _decode_jwt_payload(token)
        return token, claims

    def identity_event(self) -> dict | None:
        if self._identity_announced:
            return None
        try:
            token, claims = self._read_svid()
        except OSError:
            return {
                "type": "error",
                "message": f"could not read SVID at {self.settings.svid_path} -- is the spiffe-helper sidecar running?",
            }
        self._identity_announced = True
        sub = claims.get("sub")
        exp = claims.get("exp")
        now = claims.get("iat", time.time())
        return {
            "type": "identity",
            "spiffe_id": sub,
            "svid_expires_at": exp,
            "ttl_seconds": (exp - now) if (exp and now) else None,
            "message": f"{self.settings.agent_name} presented SVID for {sub}",
        }

    # -- vault ----------------------------------------------------------

    def _client_logged_in(self) -> hvac.Client:
        if self._client is not None and self._client.is_authenticated():
            return self._client

        client = hvac.Client(url=self.settings.vault_addr)
        token, _claims = self._read_svid()
        s = self.settings

        # Native auth/spiffe. hvac 2.4.0 has no dedicated helper for it, so
        # this goes through the low-level adapter -- the SVID goes in the
        # Authorization header, not the JSON body.
        resp = client.adapter.post(
            f"/v1/auth/{s.vault_auth_mount}/login",
            json={"role": s.vault_role, "type": "jwt"},
            headers={"Authorization": f"Bearer {token}"},
        )
        client.token = resp["auth"]["client_token"]

        self._client = client
        self._last_login_fresh = True
        return client

    def auth_event(self) -> dict | None:
        if not self._last_login_fresh:
            return None
        self._last_login_fresh = False
        return {
            "type": "auth_completed",
            "auth_mount": self.settings.vault_auth_mount,
            "message": f"authenticated via auth/{self.settings.vault_auth_mount}",
        }

    def probe_ceiling(self, target_role: str = "refund-writer") -> dict:
        """Attempts database/creds/{target_role} using THIS agent's own,
        already-authenticated client -- no new Vault grant is added for
        this call. If an operator has (mistakenly, or as a deliberate
        demo) widened this agent's real ACL policy to also grant that
        role, Vault re-evaluates policy content by name on every request,
        so an already-issued token gains the new capability immediately,
        no re-login needed. Exists to make
        scripts/04-verify-agentic-iam.sh's ceiling-misconfiguration test
        visible live in the Agentic Workflow UI instead of only a presenter-
        terminal `vault read`. Self-cleaning: a credential this agent was
        never meant to hold is revoked immediately, not left alive."""
        client = self._client_logged_in()
        s = self.settings
        try:
            creds = client.secrets.database.generate_credentials(
                name=target_role, mount_point=s.vault_db_mount
            )
        except hvac.exceptions.Forbidden:
            return {
                "type": "ceiling_probe",
                "target_role": target_role,
                "allowed": False,
                "message": f"{s.agent_name}'s own real policy has no grant on database/creds/{target_role} -- refused, as expected",
            }
        client.sys.revoke_lease(creds["lease_id"])
        return {
            "type": "ceiling_probe",
            "target_role": target_role,
            "allowed": True,
            "message": (
                f"{s.agent_name}'s own token WAS allowed database/creds/{target_role} "
                "(now revoked) -- a real policy mistake, and the Agent Registry ceiling did NOT catch it"
            ),
        }

    def get_db_credentials(self, approval_metadata: dict | None = None, obo_token: DelegatedToken | None = None) -> dict:
        now = time.time()
        if approval_metadata is None and obo_token is None and self._cached and self._cached.get("expires_at", 0) > now + 5:
            return self._cached

        s = self.settings
        approval_record = None
        if obo_token is not None:
            # Real OBO: Vault's resource-server mode validates the Bearer
            # JWT itself and computes ceiling ∧ human-policy ∧ RAR -- see
            # docs/RUNBOOK.md's "OBO -- what was actually tested". This
            # bypasses hvac entirely: hvac always sends `X-Vault-Token`,
            # but resource-server mode needs the JWT as `Authorization:
            # Bearer`, a different auth path than every other call in
            # this class. The raw response has the identical shape hvac's
            # generate_credentials() returns (lease_id/lease_duration/
            # data.username/data.password) -- confirmed against a live
            # curl during Phase 0a -- so nothing below needs to change.
            resp = requests.get(
                f"{s.vault_addr}/v1/{s.vault_db_mount}/creds/{s.vault_db_role}",
                headers={"Authorization": f"Bearer {obo_token.token}"},
                timeout=10,
            )
            resp.raise_for_status()
            creds = resp.json()
            approval_record = {
                **(approval_metadata or {}),
                "human_sub": obo_token.human_sub,
                "agent_sub": obo_token.agent_sub,
                "rar": obo_token.authorization_details,
            }
        elif approval_metadata:
            # Fallback path (no OBO token supplied) -- the old free-text
            # approval, kept for the insecure-agent-equivalent story and
            # as a degrade-safe path if obo.exchange() ever raises
            # OboUnavailable. Human-approved actions get their own
            # freshly-minted child token carrying the approval as token
            # metadata, so Vault's own audit log -- not just this app's
            # `refunds` table -- ties the credential request to who
            # signed off on it. See approval.py and docs/RUNBOOK.md's
            # audit-correlation notes.
            parent = self._client_logged_in()
            # Merge in the workload's own SPIFFE id (not just the approval
            # fields) and carry the identity into the child token's
            # display_name too -- otherwise the audit entry for this request
            # shows only "token-token" and the approval, losing the "which
            # workload" half of the story. Confirmed against a real audit
            # log entry during local testing; see docs/RUNBOOK.md.
            _token, claims = self._read_svid()
            spiffe_id = claims.get("sub", "")
            meta = {**approval_metadata, "spiffe_id": spiffe_id}
            approval_record = meta
            token_resp = parent.auth.token.create(
                policies=[s.vault_role_policy],
                meta=meta,
                ttl="5m",
                display_name=f"approved-{spiffe_id}" if spiffe_id else "approved",
            )
            client = hvac.Client(url=s.vault_addr)
            client.token = token_resp["auth"]["client_token"]
            creds = client.secrets.database.generate_credentials(
                name=s.vault_db_role, mount_point=s.vault_db_mount
            )
        else:
            client = self._client_logged_in()
            creds = client.secrets.database.generate_credentials(
                name=s.vault_db_role, mount_point=s.vault_db_mount
            )
        ttl = creds["lease_duration"]
        self._cached = {
            "username": creds["data"]["username"],
            "password": creds["data"]["password"],
            "host": s.database_host,
            "port": s.database_port,
            "dbname": s.database_name,
            "lease_id": creds["lease_id"],
            "lease_role": s.vault_db_role,
            "expires_at": now + ttl,
            "ttl_seconds": ttl,
            # Role-dependent, not a fixed shape -- this was previously
            # hardcoded to refund-writer's grants regardless of
            # s.vault_db_role, which falsely showed order-agent's
            # credential (order-reader) as able to INSERT into refunds in
            # the Agentic Workflow panel. order-reader has no such grant
            # (see terraform/vault-config.tf's order_reader role) --
            # confirmed empirically: a real order-reader credential gets
            # "permission denied for table refunds" on INSERT. Keep this
            # in sync with vault-config.tf's three
            # vault_database_secret_backend_role creation_statements.
            "scope": _DB_ROLE_SCOPES.get(s.vault_db_role, []),
            # Surfaced so the storefront panel can show approver + workload +
            # credential together -- this is how the talk now demonstrates
            # "audit-ready": Vault's own audit log carries the same three
            # fields (see terraform/vault-config.tf's vault_audit) but is
            # presenter-only, not shown on stage.
            "approval": approval_record,
        }
        return self._cached

    def revoke(self) -> dict | None:
        if not self._cached:
            return None
        lease_id = self._cached["lease_id"]
        client = self._client_logged_in()
        # hvac's revoke_lease returns HTTP 204 with an empty body -- do not
        # treat the return value as a dict.
        client.sys.revoke_lease(lease_id)
        self._cached = None
        return {
            "type": "credential_revoked",
            "lease_id": lease_id,
            "message": f"revoked {lease_id} -- credential and its database role no longer exist",
        }

    def _registry_info_now(self) -> dict | None:
        """Agent Registry read -- own entry only (terraform/vault-config.tf
        widened this agent's real policy with exactly one read-only path
        for this). Deliberately never triggers a fresh Vault login just to
        serve a /status poll: only reads opportunistically off an already-
        authenticated client from a real credential-fetching action, so a
        pod that hasn't handled a turn yet reports None here rather than
        logging in purely to populate a status field."""
        if self._registry_info is not None:
            return self._registry_info or None
        name = self.settings.vault_registry_name
        if not name or self._client is None or not self._client.is_authenticated():
            return None
        try:
            resp = self._client.read(f"agent-registry/registration/display-name/{name}")
            data = (resp or {}).get("data") or {}
            self._registry_info = {
                "display_name": data.get("display_name"),
                "ceiling_policies": data.get("ceiling_policies"),
                "description": data.get("description"),
            }
        except Exception:  # noqa: BLE001 -- informational only, never block /status
            self._registry_info = False
        return self._registry_info or None

    def status(self) -> dict:
        identity = None
        try:
            _, claims = self._read_svid()
            identity = {"spiffe_id": claims.get("sub"), "svid_expires_at": claims.get("exp")}
        except OSError:
            pass
        return {
            "available": True,
            "mode": "secure",
            "identity": identity,
            "lease": self._cached,
            "registry": self._registry_info_now(),
        }

    def forget(self) -> None:
        """Drops the cached credential AND the logged-in client, without
        calling Vault. For when something revoked our lease out of band
        (e.g. `scripts/reset.sh`'s `vault lease revoke -prefix`) -- without
        this, the cache keeps serving a lease Vault has already killed
        until its own expires_at catches up, and every query fails with a
        confusing Postgres auth error instead of a clean re-mint. Confirmed
        the hard way during local testing; see docs/RUNBOOK.md."""
        self._cached = None
        self._client = None


def build_session(settings: Settings):
    if settings.agent_mode == "insecure":
        return StaticCredentialSession(settings)
    return VaultSession(settings)
