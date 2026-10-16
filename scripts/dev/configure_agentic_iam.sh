#!/usr/bin/env bash
# LOCAL DEV ONLY, Vault ENTERPRISE required. Sets up Agentic IAM (Agent
# Registry, ceiling policy, OAuth resource server + RAR) against the
# `vault-enterprise` docker-compose service, and then runs the actual
# empirical test this repo couldn't run while it was built: does Vault's
# OAuth-resource-server-mode request validation enforce a per-request
# `authorization_details` (RAR) constraint on a bare Bearer token outside
# any real OAuth/OBO exchange? Nothing in HashiCorp's docs confirms this
# either way for a non-OBO request -- this script finds out.
#
# Prerequisites:
#   1. A Vault Enterprise trial license (sales/support-gated -- see
#      docs/RUNBOOK.md's "Agentic IAM" section; https://vaultproject.io/trial
#      redirects to "contact your support contact," it is not instant
#      self-serve).
#   2. export VAULT_LICENSE="<your license string>"
#   3. docker compose --profile enterprise up -d vault-enterprise
#
# This does NOT attempt on-behalf-of (OBO) / token exchange -- see the
# comment block at the top of terraform/agentic-iam.tf for why (needs
# Vault 2.2+, not GA, plus a sales-gated external IdP).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source "../lib/common.sh"

export VAULT_ADDR=http://localhost:8210
export VAULT_TOKEN=root

log "0. confirming the Enterprise license actually loaded"
vault status 2>&1 | grep -qi "HashiCorp Vault Enterprise" \
  || die "this doesn't look like Vault Enterprise at $VAULT_ADDR -- is vault-enterprise running with VAULT_LICENSE set? ('docker compose --profile enterprise up -d vault-enterprise' then check 'docker compose logs vault-enterprise')"
vault status
echo

log "1. identity + ceiling policy + auth backend for the test agent"
python3 mint_fake_svid.py --ttl 600

vault secrets enable -path=kv kv-v2 2>/dev/null || echo "   (kv already enabled)"
vault kv put kv/test-secret value=hello-from-vault-enterprise

vault auth enable jwt 2>/dev/null || echo "   (jwt already enabled)"
vault write auth/jwt/config jwt_validation_pubkeys=@keys/fake_spire_key.pub.pem

vault write auth/jwt/role/ai-support-agent \
  role_type="jwt" user_claim="sub" bound_audiences="vault" \
  bound_subject="spiffe://nimbus.demo/ns/agents/sa/ai-support-agent-secure" \
  token_policies="agent-support-test" token_ttl="5m" \
  claim_mappings=sub=spiffe_id

vault policy write agent-support-test - <<'EOF'
path "kv/data/test-secret" {
  capabilities = ["read"]
}
EOF

vault policy write agent-ceiling - <<'EOF'
path "kv/data/test-secret" {
  capabilities = ["read"]
}
EOF

vault write identity/entity name="agent-ai-support-agent-secure" >/tmp/entity_write.json
ENTITY_ID="$(vault read -field=id identity/entity/name/agent-ai-support-agent-secure)"
JWT_ACCESSOR="$(vault auth list -format=json | python3 -c 'import sys,json;print(json.load(sys.stdin)["jwt/"]["accessor"])')"

vault write identity/entity-alias \
  name="spiffe://nimbus.demo/ns/agents/sa/ai-support-agent-secure" \
  canonical_id="$ENTITY_ID" \
  mount_accessor="$JWT_ACCESSOR"

log "2. Agent Registry"
vault write agent-registry/register \
  display_name="ai-support-agent-secure" \
  entity_id="$ENTITY_ID" \
  ceiling_policies='["agent-ceiling"]'
echo "   reading it back:"
vault read agent-registry/registration/display-name/ai-support-agent-secure

log "3. OAuth resource server profile ('spire' as the issuer)"
python3 -c "
import json
pem = open('keys/fake_spire_key.pub.pem').read()
print(json.dumps({
    'issuer_id': 'spiffe://nimbus.demo',
    'use_jwks': False,
    'user_claim': 'sub',
    'audiences': ['vault'],
    'public_keys': [{'key_id': 'spire-key-0', 'pem': pem}],
    'optional_authorization_details': False,
}))
" > /tmp/oauth_profile.json
vault write sys/config/oauth-resource-server/spire @/tmp/oauth_profile.json
vault read sys/config/oauth-resource-server/spire

echo
log "4. THE ACTUAL TEST -- does a bare Bearer JWT with authorization_details get honored?"
log "   4a. mint a JWT granting read on kv/data/test-secret, present it directly"
python3 mint_rar_jwt.py --path kv/data/test-secret --capabilities read
RAR_JWT="$(cat svids/rar_jwt.token)"
echo "   curl -H \"Authorization: Bearer <jwt>\" $VAULT_ADDR/v1/kv/data/test-secret"
curl -s -w '\n   HTTP %{http_code}\n' -H "Authorization: Bearer $RAR_JWT" "$VAULT_ADDR/v1/kv/data/test-secret"
echo

log "   4b. mint a JWT granting read on a DIFFERENT path -- same request, should now fail if RAR is enforced"
python3 mint_rar_jwt.py --path kv/data/some-other-secret --capabilities read
RAR_JWT_WRONG="$(cat svids/rar_jwt.token)"
curl -s -w '\n   HTTP %{http_code}\n' -H "Authorization: Bearer $RAR_JWT_WRONG" "$VAULT_ADDR/v1/kv/data/test-secret"
echo

log "   4c. mint a JWT granting 'create' (not 'read') on the right path -- capability mismatch"
python3 mint_rar_jwt.py --path kv/data/test-secret --capabilities create
RAR_JWT_WRONGCAP="$(cat svids/rar_jwt.token)"
curl -s -w '\n   HTTP %{http_code}\n' -H "Authorization: Bearer $RAR_JWT_WRONGCAP" "$VAULT_ADDR/v1/kv/data/test-secret"
echo

warn "record what actually happened in 4a/4b/4c in docs/RUNBOOK.md -- this is genuinely unknown until this runs."
warn "if 4a returns 200 and 4b/4c do NOT, RAR enforcement on a bare Bearer token is real and this demo can show it live."
warn "if all three behave identically (e.g. all 403, because resource-server mode needs a real OAuth flow, or all 200,"
warn "because RAR only applies inside OBO), that's the answer too -- update terraform/agentic-iam.tf's comments accordingly."
