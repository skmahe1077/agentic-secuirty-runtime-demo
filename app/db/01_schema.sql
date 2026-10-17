-- Mahi Stores schema.
--
-- Deliberate split for the demo's identity story:
--   products / orders / refunds  -- in scope for the support agent's Vault role
--   customers                    -- PII, never granted to any agent role
--
-- The insecure agent connects as a broadly-granted role and can read
-- `customers` and refund any order. The secure agent's Vault-issued role can
-- never see `customers` at all -- enforced by PostgreSQL GRANTs, not by the
-- agent's good behaviour.

CREATE TABLE IF NOT EXISTS customers (
    customer_id   SERIAL PRIMARY KEY,
    name           TEXT NOT NULL,
    email          TEXT NOT NULL UNIQUE,
    phone          TEXT,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS products (
    product_id     SERIAL PRIMARY KEY,
    name           TEXT NOT NULL,
    description    TEXT NOT NULL DEFAULT '',
    price_pence    INTEGER NOT NULL CHECK (price_pence >= 0),
    stock          INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS orders (
    order_id       SERIAL PRIMARY KEY,
    customer_id    INTEGER NOT NULL REFERENCES customers(customer_id),
    product_id     INTEGER NOT NULL REFERENCES products(product_id),
    quantity       INTEGER NOT NULL DEFAULT 1,
    total_pence    INTEGER NOT NULL CHECK (total_pence >= 0),
    status         TEXT NOT NULL DEFAULT 'placed'
                   CHECK (status IN ('placed', 'shipped', 'delivered', 'refunded')),
    placed_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS refunds (
    refund_id      SERIAL PRIMARY KEY,
    order_id       INTEGER NOT NULL REFERENCES orders(order_id),
    amount_pence   INTEGER NOT NULL CHECK (amount_pence >= 0),
    reason         TEXT NOT NULL DEFAULT '',
    issued_by      TEXT NOT NULL,          -- 'agent-insecure' | 'agent-secure'
    approved_by    TEXT,                   -- human approver, set only when required
    correlation_id TEXT,
    issued_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_orders_customer ON orders(customer_id);
CREATE INDEX IF NOT EXISTS idx_refunds_order ON refunds(order_id);
