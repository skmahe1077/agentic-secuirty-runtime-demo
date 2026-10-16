#!/usr/bin/env bash
# LOCAL DEV ONLY. Configures the dev-mode Vault container started by
# docker-compose so the full agent/vault.py code path (JWT login -> dynamic
# PostgreSQL credential -> use -> revoke) can be exercised against a real
# Vault + real Postgres before touching HCP/EKS/SPIRE.
#
# Mirrors (and deliberately stays close to) the HCP-targeted config this
# repo's Terraform will apply for the real demo -- see
# terraform/vault-config.tf and docs/RUNBOOK.md.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

export VAULT_ADDR="${VAULT_ADDR:-http://localhost:8200}"
export VAULT_TOKEN="${VAULT_TOKEN:-root}"

echo "== generating a throwaway signing key + fake SPIFFE JWT-SVID =="
python3 mint_fake_svid.py --ttl 300

echo "== database secrets engine =="
vault secrets enable database 2>/dev/null || echo "   (already enabled)"

vault write database/config/local-postgres \
    plugin_name="postgresql-database-plugin" \
    allowed_roles="refund-writer" \
    connection_url="postgresql://{{username}}:{{password}}@postgres:5432/nimbus?sslmode=disable" \
    username="vaultadmin" \
    password="localdevonly"

vault write database/roles/refund-writer \
    db_name="local-postgres" \
    creation_statements='CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '"'"'{{password}}'"'"' VALID UNTIL '"'"'{{expiration}}'"'"';
GRANT CONNECT ON DATABASE nimbus TO "{{name}}";
GRANT USAGE ON SCHEMA public TO "{{name}}";
GRANT SELECT, UPDATE ON orders TO "{{name}}";
GRANT INSERT ON refunds TO "{{name}}";
GRANT USAGE, SELECT ON SEQUENCE refunds_refund_id_seq TO "{{name}}";' \
    revocation_statements='REVOKE ALL PRIVILEGES ON refunds FROM "{{name}}";
REVOKE ALL PRIVILEGES ON orders FROM "{{name}}";
REVOKE USAGE, SELECT ON SEQUENCE refunds_refund_id_seq FROM "{{name}}";
REVOKE USAGE ON SCHEMA public FROM "{{name}}";
REVOKE CONNECT ON DATABASE nimbus FROM "{{name}}";
DROP ROLE IF EXISTS "{{name}}";' \
    default_ttl="3m" \
    max_ttl="10m"

echo "== jwt auth method (the auth/jwt fallback path -- see vault.py) =="
vault auth enable jwt 2>/dev/null || echo "   (already enabled)"

vault write auth/jwt/config \
    jwt_validation_pubkeys=@keys/fake_spire_key.pub.pem

vault write auth/jwt/role/ai-support-agent \
    role_type="jwt" \
    user_claim="sub" \
    bound_audiences="vault" \
    bound_subject="spiffe://nimbus.demo/ns/agents/sa/ai-support-agent-secure" \
    token_policies="agent-support" \
    token_ttl="5m" \
    claim_mappings=sub=spiffe_id

echo "== policy =="
# sys/leases/revoke is NOT implied by read access to database/creds/* -- it
# is its own capability grant. Confirmed the hard way: the first version of
# this script omitted it and beat 2's "revoke on command" step came back
# `hvac.exceptions.Forbidden: permission denied`. This is exactly the kind
# of thing docs/RUNBOOK.md's go/no-go probe (scripts/03-verify.sh) re-checks
# against HCP Vault Dedicated, where it may be restricted differently.
vault policy write agent-support - <<'EOF'
path "database/creds/refund-writer" {
  capabilities = ["read"]
}
path "sys/leases/revoke" {
  capabilities = ["update"]
}
path "auth/token/create" {
  capabilities = ["create", "update"]
}
EOF

echo "== done. verifying login with the fake SVID =="
TOKEN="$(cat svids/jwt_svid.token)"
vault write -field=token auth/jwt/login role=ai-support-agent jwt="$TOKEN" > /tmp/vault_test_token
echo "login OK, got a client token ($(wc -c < /tmp/vault_test_token | tr -d ' ') bytes)"
rm -f /tmp/vault_test_token
