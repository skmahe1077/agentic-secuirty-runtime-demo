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

from config import Settings


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


class StaticCredentialSession:
    """agent-insecure: a long-lived password, no identity, no scoping."""

    def __init__(self, settings: Settings):
        self.settings = settings
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
        # stage in the storefront's Security Flow panel has nothing to
        # report, which is itself the point.
        return None

    def get_db_credentials(self, approval_metadata: dict | None = None) -> dict:
        # The anti-pattern this class models has no concept of per-request
        # scoping, so an approval has nowhere to attach -- it is silently
        # dropped, which is itself part of the point.
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

    def get_db_credentials(self, approval_metadata: dict | None = None) -> dict:
        now = time.time()
        if approval_metadata is None and self._cached and self._cached.get("expires_at", 0) > now + 5:
            return self._cached

        s = self.settings
        approval_record = None
        if approval_metadata:
            # Human-approved actions get their own freshly-minted child
            # token carrying the approval as token metadata, so Vault's own
            # audit log -- not just this app's `refunds` table -- ties the
            # credential request to who signed off on it. See approval.py
            # and docs/RUNBOOK.md's audit-correlation notes.
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
            "scope": [
                {"resource": "orders", "action": "SELECT", "allowed": True},
                {"resource": "refunds", "action": "INSERT", "allowed": True},
                {"resource": "customers", "action": "SELECT", "allowed": False},
            ],
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

    def status(self) -> dict:
        identity = None
        try:
            _, claims = self._read_svid()
            identity = {"spiffe_id": claims.get("sub"), "svid_expires_at": claims.get("exp")}
        except OSError:
            pass
        return {"available": True, "mode": "secure", "identity": identity, "lease": self._cached}

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
