-- The standing-access anti-pattern that beat 1 exists to criticise.
--
-- `nimbus_app_legacy` is a long-lived, broadly-granted role with a static
-- password. It is what `agent-insecure` connects as. It can read `customers`
-- (PII) and touch every order, because historically "the app" needed all of
-- that at various points and nobody ever scoped it back down. This is
-- deliberately the bad example -- do not pattern-match the real agent role
-- off this file; see Vault's `database/roles/refund-writer` instead.
--
-- DEMO ONLY. This password is intentionally weak and intentionally static.
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'nimbus_app_legacy') THEN
        CREATE ROLE nimbus_app_legacy LOGIN PASSWORD 'LegacyStaticPassword123!';
    END IF;
END
$$;

GRANT CONNECT ON DATABASE nimbus TO nimbus_app_legacy;
GRANT SELECT, UPDATE ON orders TO nimbus_app_legacy;
GRANT INSERT ON refunds TO nimbus_app_legacy;
GRANT USAGE, SELECT ON refunds_refund_id_seq TO nimbus_app_legacy;
GRANT SELECT ON customers TO nimbus_app_legacy;   -- the part that should never have been granted
GRANT SELECT ON products TO nimbus_app_legacy;
