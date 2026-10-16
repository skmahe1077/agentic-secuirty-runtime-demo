"""Human-intent plumbing: a correlation id minted when an action pauses for
approval, and the Vault token metadata that ties the eventual credential
request back to it.

Token `-metadata` surfaces in the audit entry's `auth.metadata` and needs no
`sys/config/auditing` access, which HCP Vault Dedicated may not grant -- see
docs/RUNBOOK.md. Vault also natively recognises `X-Correlation-Id`/
`Correlation-Id` request headers, used as a second, independent signal.
"""
from __future__ import annotations

import uuid


def new_correlation_id() -> str:
    return str(uuid.uuid4())


def approval_token_metadata(correlation_id: str, approved_by: str) -> dict:
    return {"approval_id": correlation_id, "approved_by": approved_by}
