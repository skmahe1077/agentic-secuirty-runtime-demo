#!/usr/bin/env bash
# Go/no-go probe for Agentic IAM (Agent Registry + OAuth resource server)
# on the REAL cluster -- same pattern as scripts/03-verify.sh's auth/spiffe
# probe. Run this against HCP Vault Dedicated before setting
# `agentic_iam_available=true` in terraform/agentic-iam.tf.
#
# This is a separate script, not folded into 03-verify.sh, because it is
# optional and almost certainly WILL fail without a Vault Enterprise
# license/entitlement -- see docs/RUNBOOK.md's "Agentic IAM" section.
# 03-verify.sh's checks are all things this demo needs; this script's
# checks are a bonus feature this demo can show IF the cluster supports it.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

export VAULT_ADDR="$(tf_output vault_addr)"
export VAULT_TOKEN="$(tf_output vault_admin_token)"
export VAULT_NAMESPACE=admin

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

log "2. Agent Registry reachable (root-mounted, unnamespaced -- the most likely thing HCP blocks)"
check "write agent-registry/register" vault write agent-registry/register \
  display_name="verify-probe-agent" entity_id="$(vault read -field=id identity/entity/name/verify-probe 2>/dev/null || vault write -field=id identity/entity name=verify-probe)"
check "read it back" vault read agent-registry/registration/display-name/verify-probe
check "clean up" vault delete agent-registry/registration/display-name/verify-probe

log "3. OAuth resource server config (sys/config/oauth-resource-server/* -- a sys/-level path)"
check "write a throwaway profile" vault write sys/config/oauth-resource-server/verify-probe \
  issuer_id="https://verify-probe.example.org" use_jwks=true jwks_uri="https://verify-probe.example.org/.well-known/jwks.json"
check "clean up" vault delete sys/config/oauth-resource-server/verify-probe

echo
log "summary: $PASS passed, $FAIL failed"
if [ "$FAIL" -eq 0 ]; then
  log "Agentic IAM paths are reachable. Re-apply with: terraform apply -var=agentic_iam_available=true"
else
  warn "Agentic IAM is not available on this cluster/entitlement -- stay with agentic_iam_available=false."
  warn "This does not block the demo: beats 1-3 and scripts/03-verify.sh's checks are all that's required."
fi
