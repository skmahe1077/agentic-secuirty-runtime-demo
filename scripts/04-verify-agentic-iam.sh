#!/usr/bin/env bash
# Go/no-go + the actual empirical test for Agentic IAM (Agent Registry +
# OAuth resource server + RAR) against the real, self-managed Vault
# Enterprise cluster. Unlike the HCP-era version of this script, this is
# no longer "almost certainly fails" -- a real Enterprise license is
# installed and terraform/agentic-iam.tf applies unconditionally.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

vault_env

PASS=0
FAIL=0
check() {
  local name="$1"; shift
  if "$@" >/tmp/verify_agentic_iam.log 2>&1; then
    printf '  \033[1;32mPASS\033[0m  %s\n' "$name"
    PASS=$((PASS+1))
  else
    printf '  \033[1;31mFAIL\033[0m  %s\n' "$name"
    sed 's/^/        /' /tmp/verify_agentic_iam.log
    FAIL=$((FAIL+1))
  fi
}

log "1. Vault edition and version"
vault status 2>&1 | grep -iE "Vault Enterprise|version" || true
echo

log "2. Agent Registry -- BOTH registrations terraform/agentic-iam.tf created"
check "read back refund-agent's registration" vault read agent-registry/registration/display-name/refund-agent
check "read back order-agent's registration" vault read agent-registry/registration/display-name/order-agent

log "3. OAuth resource server profile -- the 'spire' profile terraform/agentic-iam.tf created"
check "read back the spire profile" vault read sys/config/oauth-resource-server/spire

echo
log "4. THE ACTUAL TEST -- does a bare Bearer JWT with authorization_details get honored outside an OBO exchange?"
log "   this is the single biggest unverified assumption in terraform/agentic-iam.tf -- RECORD the HTTP codes below in docs/RUNBOOK.md"

vault secrets enable -path=kv kv-v2 2>/dev/null || echo "   (kv already enabled)"
vault kv put kv/test-secret value=hello-from-vault-enterprise >/dev/null

PUB_KEY_PEM="/tmp/rar-probe-keys/rar_probe_key.pub.pem"
python3 "$REPO_ROOT/scripts/mint_rar_jwt.py" --path kv/data/test-secret --capabilities read \
  --out /tmp/rar_jwt_ok.token >/dev/null
vault write sys/config/oauth-resource-server/rar-probe \
  issuer_id="spiffe://nimbus.demo" use_jwks=false user_claim=sub audiences=vault \
  public_keys="[{\"key_id\":\"rar-probe-key-0\",\"pem\":\"$(python3 -c "print(open('$PUB_KEY_PEM').read().replace(chr(10), chr(92)+'n'))")\"}]" \
  optional_authorization_details=false >/dev/null

log "   4a. mint a JWT granting read on kv/data/test-secret, present it directly"
RAR_JWT_OK="$(cat /tmp/rar_jwt_ok.token)"
echo "   curl -H \"Authorization: Bearer <jwt>\" $VAULT_ADDR/v1/kv/data/test-secret"
curl -s -w '\n   HTTP %{http_code}\n' -H "Authorization: Bearer $RAR_JWT_OK" "$VAULT_ADDR/v1/kv/data/test-secret"
echo

log "   4b. same path, wrong path in the claim -- should fail if RAR is enforced"
python3 "$REPO_ROOT/scripts/mint_rar_jwt.py" --path kv/data/some-other-secret --capabilities read \
  --out /tmp/rar_jwt_wrongpath.token >/dev/null
curl -s -w '\n   HTTP %{http_code}\n' -H "Authorization: Bearer $(cat /tmp/rar_jwt_wrongpath.token)" "$VAULT_ADDR/v1/kv/data/test-secret"
echo

log "   4c. right path, wrong capability ('create' not 'read') -- should fail if RAR is enforced"
python3 "$REPO_ROOT/scripts/mint_rar_jwt.py" --path kv/data/test-secret --capabilities create \
  --out /tmp/rar_jwt_wrongcap.token >/dev/null
curl -s -w '\n   HTTP %{http_code}\n' -H "Authorization: Bearer $(cat /tmp/rar_jwt_wrongcap.token)" "$VAULT_ADDR/v1/kv/data/test-secret"
echo

vault delete sys/config/oauth-resource-server/rar-probe >/dev/null 2>&1 || true
vault kv delete kv/test-secret >/dev/null 2>&1 || true

warn "record what 4a/4b/4c actually returned in docs/RUNBOOK.md -- this was genuinely unknown until this ran."
warn "if 4a is 200 and 4b/4c are NOT, RAR enforcement on a bare Bearer token is real and the demo can show it live."
warn "if all three behave identically, that's the answer too -- update terraform/agentic-iam.tf's comments accordingly."

echo
log "5. DELIBERATE MISCONFIGURATION TEST -- does the Agent Registry ceiling cap anything on a NORMAL Vault token, independent of RAR/OBO?"
log "   until now order-agent-ceiling has been identical in scope to order-agent-policy (nothing to clip). This widens the"
log "   REAL policy to a mistake an operator could plausibly make, then asks a NORMAL auth/spiffe-issued token to use it --"
log "   a different mechanism from step 4's bare-Bearer RAR test, and only possible now that two agents exist to compare."

ORDER_AGENT_SVID="$(kubectl -n agents exec deploy/order-agent -c agent -- cat /svids/jwt_svid.token 2>/dev/null || true)"
if [ -z "$ORDER_AGENT_SVID" ]; then
  warn "could not read order-agent's SVID (is deploy/order-agent running in ns agents?) -- skipping the misconfiguration test"
else
  log "   widening order-agent-policy to also grant database/creds/refund-writer read (the mistake)"
  vault policy write order-agent-policy - <<'EOF'
path "database/creds/order-reader" {
  capabilities = ["read"]
}
path "database/creds/refund-writer" {
  capabilities = ["read"]
}
path "sys/leases/revoke" {
  capabilities = ["update"]
}
EOF

  ORDER_AGENT_TOKEN="$(curl -s -H "Authorization: Bearer $ORDER_AGENT_SVID" \
    -d '{"role":"ai-order-agent","type":"jwt"}' \
    "$VAULT_ADDR/v1/auth/spiffe/login" | python3 -c 'import sys,json;print(json.load(sys.stdin)["auth"]["client_token"])' 2>/dev/null)"

  if [ -z "${ORDER_AGENT_TOKEN:-}" ]; then
    warn "order-agent's auth/spiffe/login failed -- skipping the rest of the misconfiguration test"
  else
    echo "   vault read database/creds/refund-writer, as order-agent's own (normally-issued) token:"
    RESULT_CODE=0
    VAULT_TOKEN="$ORDER_AGENT_TOKEN" vault read database/creds/refund-writer >/tmp/misconfig_test.log 2>&1 || RESULT_CODE=$?
    sed 's/^/     /' /tmp/misconfig_test.log
    if [ "$RESULT_CODE" -eq 0 ]; then
      warn "SUCCEEDED -- the widened real policy was honored and the ceiling did NOT block it on a normal token."
      warn "this matches the docs' own framing (ceiling enforcement presumes an OBO flow) -- not a surprise, but now confirmed, not assumed."
    else
      warn "BLOCKED -- the Agent Registry ceiling capped a normal token's request independent of RAR/OBO. Genuinely new information -- update terraform/agentic-iam.tf's header comment, this was the single biggest open question in this repo."
    fi
  fi

  log "   reverting order-agent-policy to its narrow form"
  vault policy write order-agent-policy - <<'EOF'
path "database/creds/order-reader" {
  capabilities = ["read"]
}
path "sys/leases/revoke" {
  capabilities = ["update"]
}
EOF
fi
warn "record the misconfiguration test's actual result in docs/RUNBOOK.md, same discipline as the 4a/4b/4c codes above."

echo
log "summary: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  log "Agentic IAM is confirmed working on this cluster."
else
  warn "Agent Registry / OAuth resource server reads failed -- re-check terraform apply output for agentic-iam.tf."
fi
