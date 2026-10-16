"""Storefront's own DB access -- catalog browsing and order display only.

The storefront reads with a single pooled connection using DATABASE_URL (a
normal app credential, not part of the identity story). It never issues
refunds directly -- that always goes through an agent, so every refund in
the `refunds` table carries an `issued_by` and (when required) an
`approved_by`, which is the whole point of the demo.
"""
from __future__ import annotations

import os
from contextlib import contextmanager

import psycopg2
import psycopg2.extras

DATABASE_URL = os.environ.get(
    "DATABASE_URL", "postgresql://vaultadmin:localdevonly@localhost:5432/nimbus"
)


@contextmanager
def get_conn():
    conn = psycopg2.connect(DATABASE_URL)
    try:
        yield conn
    finally:
        conn.close()


def list_products() -> list[dict]:
    with get_conn() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            "SELECT product_id, name, description, price_pence, stock FROM products ORDER BY product_id"
        )
        return [dict(r) for r in cur.fetchall()]


def list_orders(customer_id: int | None = None) -> list[dict]:
    with get_conn() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        if customer_id is not None:
            cur.execute(
                """
                SELECT o.order_id, o.customer_id, c.name AS customer_name, p.name AS product_name,
                       o.quantity, o.total_pence, o.status, o.placed_at
                FROM orders o
                JOIN customers c ON c.customer_id = o.customer_id
                JOIN products p ON p.product_id = o.product_id
                WHERE o.customer_id = %s
                ORDER BY o.order_id DESC
                """,
                (customer_id,),
            )
        else:
            cur.execute(
                """
                SELECT o.order_id, o.customer_id, c.name AS customer_name, p.name AS product_name,
                       o.quantity, o.total_pence, o.status, o.placed_at
                FROM orders o
                JOIN customers c ON c.customer_id = o.customer_id
                JOIN products p ON p.product_id = o.product_id
                ORDER BY o.order_id DESC
                """
            )
        return [dict(r) for r in cur.fetchall()]


def get_order(order_id: int) -> dict | None:
    with get_conn() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(
            """
            SELECT o.order_id, o.customer_id, c.name AS customer_name, p.name AS product_name,
                   o.quantity, o.total_pence, o.status, o.placed_at
            FROM orders o
            JOIN customers c ON c.customer_id = o.customer_id
            JOIN products p ON p.product_id = o.product_id
            WHERE o.order_id = %s
            """,
            (order_id,),
        )
        row = cur.fetchone()
        return dict(row) if row else None


def list_customers() -> list[dict]:
    """Used only to populate the "shop as" picker -- never called by an agent."""
    with get_conn() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("SELECT customer_id, name FROM customers ORDER BY customer_id")
        return [dict(r) for r in cur.fetchall()]


def reset_demo_state() -> None:
    """Puts every order back to 'delivered'/'shipped' and clears refunds, so
    the three beats can be re-run from a clean state between rehearsals."""
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute("DELETE FROM refunds")
        cur.execute("UPDATE orders SET status = 'delivered' WHERE order_id != 1045")
        cur.execute("UPDATE orders SET status = 'shipped' WHERE order_id = 1045")
        conn.commit()
