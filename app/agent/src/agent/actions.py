"""The two things this support agent can actually do, independent of which
engine (LangChain or the deterministic test harness) decided to call them.

Every action returns `(reply_text, events)` where `events` follows the
contract documented in `app/storefront/static/app.js`. Business logic lives
here exactly once; `langchain_tools.py` and `deterministic_engine.py` are
both thin adapters over this module.
"""
from __future__ import annotations

import time

import psycopg2
import psycopg2.errors
import psycopg2.extras

from approval import approval_token_metadata


def _connect(creds: dict):
    return psycopg2.connect(
        host=creds["host"],
        port=creds["port"],
        dbname=creds["dbname"],
        user=creds["username"],
        password=creds["password"],
    )


def _credential_events(session, action_label: str) -> list[dict]:
    """Identity + credential-issued events, emitted once per session on
    first use so the panel populates without spamming the log on every
    tool call within the same chat turn."""
    events = []
    ident = session.identity_event()
    if ident:
        events.append(ident)
    return events


def peek_order_total_pence(order_id: int, session) -> int | None:
    """Silent lookup used only to decide whether a refund needs human
    approval, before any tool-call events are emitted for the turn."""
    creds = session.get_db_credentials()
    with _connect(creds) as conn, conn.cursor() as cur:
        cur.execute("SELECT total_pence FROM orders WHERE order_id = %s", (order_id,))
        row = cur.fetchone()
    return row[0] if row else None


def lookup_order(order_id: int, requester_customer_id: int, session, enforce_ownership: bool) -> tuple[str, list[dict]]:
    events = _credential_events(session, "lookup_order")
    try:
        creds = session.get_db_credentials()
    except Exception as exc:  # noqa: BLE001 -- surfaced to the chat, not swallowed
        events.append({"type": "error", "message": f"could not obtain a database credential: {exc}"})
        return "I couldn't reach the order database right now.", events

    auth = session.auth_event()
    if auth:
        events.append(auth)
    events.append({
        "type": "credential_issued",
        "lease_id": creds["lease_id"],
        "lease_role": creds["lease_role"],
        "expires_at": creds.get("expires_at"),
        "ttl_seconds": creds.get("ttl_seconds"),
        "scope": creds["scope"],
        "approval": creds.get("approval"),
        "message": f"issued credential {creds['lease_role']} (lease {creds['lease_id']})",
    })

    with _connect(creds) as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            """
            SELECT o.order_id, o.customer_id, p.name AS product_name, o.total_pence, o.status
            FROM orders o JOIN products p ON p.product_id = o.product_id
            WHERE o.order_id = %s
            """,
            (order_id,),
        )
        row = cur.fetchone()

    if row is None:
        return f"I can't find order #{order_id}.", events

    if enforce_ownership and row["customer_id"] != requester_customer_id:
        events.append({
            "type": "denied",
            "resource": "orders",
            "message": f"refused: order #{order_id} belongs to a different customer than the one chatting",
        })
        return "I can only look up your own orders.", events

    return (
        f"Order #{row['order_id']}: {row['product_name']}, "
        f"£{row['total_pence']/100:.2f}, status: {row['status']}."
    ), events


def issue_refund(
    order_id: int,
    reason: str,
    requester_customer_id: int,
    session,
    enforce_ownership: bool,
    issued_by: str,
    approved_by: str | None = None,
    correlation_id: str | None = None,
    approval_metadata: dict | None = None,
) -> tuple[str, list[dict]]:
    events = _credential_events(session, "issue_refund")
    approval_metadata = approval_metadata or (
        approval_token_metadata(correlation_id, approved_by) if approved_by and correlation_id else None
    )
    try:
        creds = session.get_db_credentials(approval_metadata=approval_metadata)
    except Exception as exc:  # noqa: BLE001
        events.append({"type": "error", "message": f"could not obtain a database credential: {exc}"})
        return "I couldn't reach the order database right now.", events

    auth = session.auth_event()
    if auth:
        events.append(auth)
    events.append({
        "type": "credential_issued",
        "lease_id": creds["lease_id"],
        "lease_role": creds["lease_role"],
        "expires_at": creds.get("expires_at"),
        "ttl_seconds": creds.get("ttl_seconds"),
        "scope": creds["scope"],
        "approval": creds.get("approval"),
        "message": (
            f"issued credential {creds['lease_role']} (lease {creds['lease_id']})"
            + (f", child token carries approval {correlation_id}" if approval_metadata else "")
        ),
    })

    with _connect(creds) as conn:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                "SELECT customer_id, total_pence, status FROM orders WHERE order_id = %s",
                (order_id,),
            )
            row = cur.fetchone()

        if row is None:
            return f"I can't find order #{order_id}.", events

        if enforce_ownership and row["customer_id"] != requester_customer_id:
            events.append({
                "type": "denied",
                "resource": "orders",
                "message": f"refused: order #{order_id} belongs to a different customer than the one chatting",
            })
            return "I can only refund your own orders.", events

        if row["status"] == "refunded":
            return f"Order #{order_id} was already refunded.", events

        # Catches a read-only role (order-agent's `order-reader`, which has
        # no INSERT/UPDATE grant anywhere) trying to refund. Same pattern as
        # lookup_customer_pii's InsufficientPrivilege catch below -- the
        # database refuses it, not an if-statement, so a mis-routed refund
        # request fails cleanly instead of 500ing. See docs/RUNBOOK.md.
        try:
            with conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO refunds (order_id, amount_pence, reason, issued_by, approved_by, correlation_id)
                    VALUES (%s, %s, %s, %s, %s, %s)
                    """,
                    (order_id, row["total_pence"], reason, issued_by, approved_by, correlation_id),
                )
                cur.execute("UPDATE orders SET status = 'refunded' WHERE order_id = %s", (order_id,))
            conn.commit()
        except psycopg2.errors.InsufficientPrivilege:
            conn.rollback()
            events.append({
                "type": "denied",
                "resource": "refunds",
                "message": f"{issued_by}'s database role has no grant to write refunds -- PostgreSQL refused the query",
            })
            return "I'm not able to process refunds -- that's outside what I'm allowed to do. I can look up the order status for you instead.", events

    events.append({
        "type": "refund_issued",
        "order_id": order_id,
        "amount_pence": row["total_pence"],
        "message": (
            f"refunded order #{order_id} (£{row['total_pence']/100:.2f})"
            + (f", approved by {approved_by}" if approved_by else "")
        ),
    })
    return f"Done -- refunded £{row['total_pence']/100:.2f} for order #{order_id}.", events


def lookup_customer_pii(customer_id: int, session, issued_by: str) -> tuple[str, list[dict]]:
    """Deliberately offered to BOTH agents, so the contrast is a real one:
    the insecure agent's static role can read this table; the secure
    agent's Vault-issued role never has `customers` in its grants, so the
    identical query fails in PostgreSQL itself, not in application logic.
    """
    events = _credential_events(session, "lookup_customer_pii")
    try:
        creds = session.get_db_credentials()
    except Exception as exc:  # noqa: BLE001
        events.append({"type": "error", "message": f"could not obtain a database credential: {exc}"})
        return "I couldn't reach the database right now.", events

    auth = session.auth_event()
    if auth:
        events.append(auth)
    events.append({
        "type": "credential_issued",
        "lease_id": creds["lease_id"],
        "lease_role": creds["lease_role"],
        "expires_at": creds.get("expires_at"),
        "ttl_seconds": creds.get("ttl_seconds"),
        "scope": creds["scope"],
        "approval": creds.get("approval"),
        "message": f"issued credential {creds['lease_role']} (lease {creds['lease_id']})",
    })

    try:
        with _connect(creds) as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute("SELECT name, email, phone FROM customers WHERE customer_id = %s", (customer_id,))
            row = cur.fetchone()
    except psycopg2.errors.InsufficientPrivilege:
        events.append({
            "type": "denied",
            "resource": "customers",
            "message": f"{issued_by}'s database role has no grant on customers -- PostgreSQL refused the query",
        })
        return "I'm not able to access customer contact details.", events

    if row is None:
        return f"I can't find customer #{customer_id}.", events

    events.append({
        "type": "scope_violation",
        "resource": "customers",
        "message": (
            f"⚠ {issued_by} read customers.email/phone for {row['name']} -- "
            f"static credential has no scoping, no identity, no record of who asked"
        ),
    })
    return f"{row['name']} / {row['email']} / {row['phone']}", events
