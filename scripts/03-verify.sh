#!/usr/bin/env bash
# The go/no-go gate. Run this before building anything else on top of a
# freshly provisioned stack, and again the morning of the talk.
#
# Each check is independent and prints PASS/FAIL rather than stopping at
# the first failure, because the result of one (spiffe_auth) changes how
# you'd configure the next run, not just whether this one succeeds.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

export VAULT_ADDR="$(tf_output vault_addr)"
export VAULT_TOKEN="$(tf_output vault_admin_token)"
export VAULT_NAMESPACE=admin

PASS=0
FAIL=0
check() {
  local name="$1"; shift
  if "$@" >/tmp/verify_check.log 2>&1; then
    printf '  \033[1;32mPASS\033[0m  %s\n' "$name"
    PASS=$((PASS+1))
  else
    printf '  \033[1;31mFAIL\033[0m  %s\n' "$name"
    sed 's/^/        /' /tmp/verify_check.log
    FAIL=$((FAIL+1))
  fi
}

log "1. native auth/spiffe availability (decides terraform's spiffe_auth_available)"
if vault auth enable spiffe 2>/tmp/verify_check.log; then
  printf '  \033[1;32mPASS\033[0m  auth/spiffe enabled -- re-run: terraform apply -var=spiffe_auth_available=true\n'
  vault auth disable spiffe # leave state exactly as terraform expects to manage it
  PASS=$((PASS+1))
else
  printf '  \033[1;33mN/A\033[0m   auth/spiffe unavailable on this cluster/license -- staying on the auth/jwt fallback\n'
  sed 's/^/        /' /tmp/verify_check.log
fi

log "2. header passthrough tuning permitted (sys/auth/*/tune)"
check "tune jwt auth backend" vault auth tune -passthrough-request-headers=Authorization jwt

log "3. database secrets engine round-trips to RDS (proves Vault<->RDS reachability over the HVN peering)"
check "mint+revoke refund-writer credential" bash -c '
  set -e
  creds=$(vault read -format=json database/creds/refund-writer)
  lease_id=$(echo "$creds" | python3 -c "import sys,json;print(json.load(sys.stdin)[\"lease_id\"])")
  vault lease revoke "$lease_id"
'

log "4. sys/leases/revoke usable by the agent-support policy, not just the admin token"
check "revoke permitted under agent-support policy" bash -c '
  set -e
  child=$(vault token create -policy=agent-support -field=token)
  creds=$(VAULT_TOKEN=$child vault read -format=json database/creds/refund-writer)
  lease_id=$(echo "$creds" | python3 -c "import sys,json;print(json.load(sys.stdin)[\"lease_id\"])")
  VAULT_TOKEN=$child vault write -f sys/leases/revoke lease_id="$lease_id"
'

log "5. audit log visibility -- NOT automated: sys/audit is blocked on HCP Vault Dedicated"
warn "enable streaming by hand: HCP Portal -> cluster -> Audit Logs -> Enable log Streaming -> CloudWatch"
warn "then measure ingestion lag during rehearsal -- see docs/RUNBOOK.md. This script cannot check it."

echo
log "summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || die "fix the failures above before relying on this stack for a rehearsal"
