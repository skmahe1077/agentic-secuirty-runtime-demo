#!/usr/bin/env bash
# Between-rehearsals reset: orders back to pre-refund state, event log
# cleared, any stray leases revoked. Safe to run as many times as you like.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

log "resetting storefront demo state (orders, refunds, event log)"
curl -s -X POST "$STOREFRONT_URL/api/admin/reset" -H 'content-type: application/json' | python3 -m json.tool

if VAULT_ADDR="$(tf_output vault_addr 2>/dev/null)"; then
  export VAULT_ADDR
  export VAULT_TOKEN="$(tf_output vault_admin_token)"
  export VAULT_NAMESPACE=admin
  log "revoking any stray database/creds/* leases on the real cluster"
  vault lease revoke -prefix database/creds/ || true
else
  log "no terraform state found -- assuming the local docker-compose stack"
  export VAULT_ADDR=http://localhost:8200
  export VAULT_TOKEN=root
  vault lease revoke -prefix database/creds/ 2>/dev/null || true
  log "re-minting the local fake SVID (5 min TTL)"
  python3 "$REPO_ROOT/scripts/dev/mint_fake_svid.py" --ttl 300
fi

# The lease revoke above happens on Vault directly -- the agent processes
# don't hear about it and will keep serving their cached (now-dead) lease
# until its own expires_at catches up. Tell them to drop it. Confirmed
# necessary the hard way: see vault.py's VaultSession.forget().
log "telling every agent to forget its cached credential"
curl -s -X POST "$STOREFRONT_URL/api/admin/forget" -H 'content-type: application/json' | python3 -m json.tool

log "done."
