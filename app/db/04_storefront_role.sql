-- The storefront's own least-privilege account.
--
-- Deliberately NOT the RDS master: scripts/02-configure-vault.sh rotates
-- the master's password via `vault write -f database/rotate-root/...`,
-- after which only Vault knows it -- the storefront can't use it even
-- once, let alone keep using it. (It is also just embarrassing for the
-- public website to hold DB admin credentials.)
--
-- Grants are exactly what app/storefront/db.py needs and no more:
--   list_products / list_customers / list_orders / get_order -> SELECT
--   reset_demo_state                                         -> UPDATE orders, DELETE refunds
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'nimbus_storefront') THEN
        CREATE ROLE nimbus_storefront LOGIN PASSWORD 'ChangeMeViaStorefrontDbPassword';
    END IF;
END
$$;

GRANT CONNECT ON DATABASE nimbus TO nimbus_storefront;
GRANT USAGE  ON SCHEMA public    TO nimbus_storefront;
GRANT SELECT ON products, customers, orders, refunds TO nimbus_storefront;
GRANT UPDATE ON orders  TO nimbus_storefront; -- reset_demo_state
GRANT DELETE ON refunds TO nimbus_storefront; -- reset_demo_state
