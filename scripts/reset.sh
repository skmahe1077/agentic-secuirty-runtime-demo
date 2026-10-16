#!/usr/bin/env bash
# Between-rehearsals reset: orders back to pre-refund state, event log
# cleared, any stray leases revoked. Safe to run as many times as you like.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

log "resetting storefront demo state (orders, refunds, event log)"
curl -s -X POST "$STOREFRONT_URL/api/admin/reset" -H 'content-type: application/json' | python3 -m json.tool

if terraform -chdir="$TF_DIR" output -raw eks_cluster_name >/dev/null 2>&1; then
  vault_env
  log "revoking any stray database/creds/* leases"
  vault lease revoke -prefix database/creds/ || true
else
  log "no terraform state -- local docker-compose stack; there is no Vault here, nothing to revoke"
fi

# The lease revoke above happens on Vault directly -- the agent processes
# don't hear about it and will keep serving their cached (now-dead) lease
# until its own expires_at catches up. Tell them to drop it. Confirmed
# necessary the hard way: see vault.py's VaultSession.forget().
log "telling every agent to forget its cached credential"
curl -s -X POST "$STOREFRONT_URL/api/admin/forget" -H 'content-type: application/json' | python3 -m json.tool

log "done."
