#!/usr/bin/env bash
# The go/no-go gate. Run this before building anything else on top of a
# freshly provisioned stack, and again the morning of the talk.
#
# Each check is independent and prints PASS/FAIL rather than stopping at
# the first failure, so one failure doesn't hide the shape of the others.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

vault_env

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

log "1. self-managed Vault Enterprise is up, unsealed, and licensed"
check "Enterprise edition" bash -c 'vault status -format=json | python3 -c "import sys,json;assert \"+ent\" in json.load(sys.stdin)[\"version\"]"'
check "unsealed" bash -c 'vault status -format=json | python3 -c "import sys,json;assert json.load(sys.stdin)[\"sealed\"] is False"'
check "license not expired" bash -c '
  exp=$(vault read -format=json sys/license/status | python3 -c "import sys,json;print(json.load(sys.stdin)[\"data\"][\"autoloaded\"][\"expiration_time\"])")
  python3 -c "import sys,datetime;exp=datetime.datetime.fromisoformat(sys.argv[1].replace(\"Z\",\"+00:00\"));assert exp > datetime.datetime.now(datetime.timezone.utc), f\"license expired at {exp}\"" "$exp"
'

log "2. header passthrough tuning on the spiffe auth mount"
check "tune spiffe auth backend" vault auth tune -passthrough-request-headers=Authorization spiffe

log "3. database secrets engine round-trips to RDS (Vault runs on the EKS nodes now, same security group as the storefront)"
check "mint+revoke refund-writer credential" bash -c '
  set -e
  creds=$(vault read -format=json database/creds/refund-writer)
  lease_id=$(echo "$creds" | python3 -c "import sys,json;print(json.load(sys.stdin)[\"lease_id\"])")
  vault lease revoke "$lease_id"
'

log "4. sys/leases/revoke usable by the agent-support policy, not just the root token"
check "revoke permitted under agent-support policy" bash -c '
  set -e
  child=$(vault token create -policy=agent-support -field=token)
  creds=$(VAULT_TOKEN=$child vault read -format=json database/creds/refund-writer)
  lease_id=$(echo "$creds" | python3 -c "import sys,json;print(json.load(sys.stdin)[\"lease_id\"])")
  VAULT_TOKEN=$child vault write -f sys/leases/revoke lease_id="$lease_id"
'

log "5. audit device is enabled and actually recording (self-managed Enterprise can do this; HCP Vault Dedicated could not)"
check "file audit device enabled" bash -c 'vault audit list -detailed -format=json | python3 -c "import sys,json;assert \"file/\" in json.load(sys.stdin)"'
VAULT_NS="$(tf_output vault_k8s_namespace)"
check "a request actually lands in the log" bash -c '
  set -e
  creds=$(vault read -format=json database/creds/refund-writer)
  lease_id=$(echo "$creds" | python3 -c "import sys,json;print(json.load(sys.stdin)[\"lease_id\"])")
  vault lease revoke "$lease_id"
  kubectl -n "'"$VAULT_NS"'" exec vault-0 -- grep -q "database/creds/refund-writer" /vault/audit/vault_audit.log
'
warn "this is presenter-only verification -- the audit log itself is NOT shown on stage; the storefront's Audit correlation tile is the demo-facing proof point."

log "6. end-to-end: the secure agent actually logs in via auth/spiffe"
check "agent-secure reports a real SPIFFE identity" bash -c '
  # curl is not installed in the agent image (python:3.12-slim, kept minimal
  # on purpose) -- urllib is already there, no image change needed for one
  # verification check.
  resp=$(kubectl -n agents exec deploy/agent-secure -c agent -- python3 -c "import urllib.request;print(urllib.request.urlopen(\"http://localhost:8000/status\").read().decode())")
  echo "$resp" | python3 -c "import sys,json;d=json.load(sys.stdin);assert d[\"identity\"] and d[\"identity\"][\"spiffe_id\"], d"
'

log "7. the public storefront ALB is reachable"
check "storefront responds" curl -sf -o /dev/null "$STOREFRONT_URL/api/products"

echo
log "summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || die "fix the failures above before relying on this stack for a rehearsal"
