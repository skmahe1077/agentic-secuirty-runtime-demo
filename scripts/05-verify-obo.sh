#!/usr/bin/env bash
# Phase 0a of the real-OBO-delegation work (see
# ~/.claude/plans/eventual-wandering-tower.md). Answers one question
# before IBM Verify is touched at all: does Vault's resource-server mode
# actually enforce the three-way intersection (ceiling policy ∧ the
# human's own policy ∧ RAR authorization_details) on a correctly-shaped
# OBO token -- not whether an external IdP can mint one (that's
# `--idp verify` below, Phase 0b -- a separate, Vault-independent
# question: does IBM Verify's token endpoint actually produce a token
# shaped the way Phase 0a needs? Needs a `.env.ibmverify` file at the
# repo root -- see docs/RUNBOOK.md's "OBO -- what was actually tested"
# section for exactly what it must contain. Never committed --
# .gitignore has an explicit `.env.ibmverify` entry.
#
# Default mode (no args) requires terraform/obo.tf to be applied first
# (its own `check` block refuses to apply with no signing key present --
# this script's setup step below generates one if missing, but does NOT
# run `terraform apply` itself; that stays a reviewed, explicit step,
# same discipline as every other terraform change this repo has made).
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

# Phase 0b -- does IBM Verify's token endpoint actually mint a token shaped
# the way Phase 0a needs (act.sub/jti/authorization_details all surviving
# the exchange)? Purely an IdP question -- doesn't touch Vault at all, so
# it's a separate code path, not folded into the Vault-side matrix below.
if [ "${1:-}" = "--idp" ] && [ "${2:-}" = "verify" ]; then
  ENV_FILE="$REPO_ROOT/.env.ibmverify"
  [ -f "$ENV_FILE" ] || die "no $ENV_FILE -- see this script's header comment / docs/RUNBOOK.md for what it needs"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
  for v in IBM_VERIFY_TOKEN_ENDPOINT IBM_VERIFY_CLIENT_ID IBM_VERIFY_CLIENT_SECRET IBM_VERIFY_HUMAN_ACCESS_TOKEN; do
    [ -n "${!v:-}" ] || die "$ENV_FILE is missing $v"
  done

  log "0b.1 -- client_credentials grant for the agent's own actor token"
  ACTOR_RESP="$(curl -s -X POST "$IBM_VERIFY_TOKEN_ENDPOINT" \
    -d grant_type=client_credentials \
    -d "client_id=$IBM_VERIFY_CLIENT_ID" \
    -d "client_secret=$IBM_VERIFY_CLIENT_SECRET")"
  ACTOR_TOKEN="$(echo "$ACTOR_RESP" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("access_token",""))' 2>/dev/null)"
  if [ -z "$ACTOR_TOKEN" ]; then
    warn "no access_token in response -- raw body (no secrets in it, this is the IdP's own response):"
    echo "$ACTOR_RESP" | sed 's/^/  /'
    die "client_credentials grant failed -- check the agent app registration in the IBM Verify console"
  fi
  log "   got an actor token (not printing it -- it's a live credential)"

  log "0b.2 -- RFC 8693 token exchange: subject=human, actor=agent, RAR=refund-writer read"
  RAR_JSON='[{"type":"vault:path_access","path":"database/creds/refund-writer","capabilities":["read"]}]'
  EXCHANGE_RESP="$(curl -s -X POST "$IBM_VERIFY_TOKEN_ENDPOINT" \
    -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    -d "subject_token=$IBM_VERIFY_HUMAN_ACCESS_TOKEN" \
    -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
    -d "actor_token=$ACTOR_TOKEN" \
    -d "actor_token_type=urn:ietf:params:oauth:token-type:access_token" \
    -d "client_id=$IBM_VERIFY_CLIENT_ID" \
    -d "client_secret=$IBM_VERIFY_CLIENT_SECRET" \
    --data-urlencode "authorization_details=$RAR_JSON")"

  OBO_TOKEN="$(echo "$EXCHANGE_RESP" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("access_token",""))' 2>/dev/null)"
  if [ -z "$OBO_TOKEN" ]; then
    warn "token-exchange did not return an access_token -- raw response (the IdP's own error, not a secret):"
    echo "$EXCHANGE_RESP" | python3 -m json.tool 2>/dev/null | sed 's/^/  /' || echo "$EXCHANGE_RESP" | sed 's/^/  /'
    die "Phase 0b FAILS here -- see this repo's fallback plan in eventual-wandering-tower.md (ship Phase 1 against the local obo-probe profile instead)"
  fi

  log "0b.3 -- decode the result and ASSERT the claims survived (HTTP 200 alone proves nothing)"
  python3 - "$OBO_TOKEN" "$RAR_JSON" <<'PYEOF'
import json, sys, base64

token, expected_rar = sys.argv[1], json.loads(sys.argv[2])
parts = token.split(".")
if len(parts) != 3:
    print("  FAIL: result doesn't look like a JWT (expected 3 dot-separated parts)")
    sys.exit(1)

def b64d(s):
    s += "=" * (-len(s) % 4)
    return json.loads(base64.urlsafe_b64decode(s))

claims = b64d(parts[1])
print(f"  decoded claims (unverified -- signature check is Vault's job, not this script's): {json.dumps(claims, indent=2)}")

ok = True
if "sub" in claims:
    print(f"  PASS: sub present -- {claims['sub']}")
else:
    print("  FAIL: no sub claim"); ok = False

act = claims.get("act", {})
if isinstance(act, dict) and act.get("sub"):
    print(f"  PASS: act.sub present -- {act['sub']}")
else:
    print("  FAIL: no act.sub claim -- Verify did not embed the actor; Phase 0b fails on this alone"); ok = False

if claims.get("authorization_details") == expected_rar:
    print("  PASS: authorization_details present and byte-equal to what was sent")
elif "authorization_details" in claims:
    print(f"  FAIL: authorization_details present but altered -- sent {expected_rar}, got {claims['authorization_details']}"); ok = False
else:
    print("  FAIL: authorization_details was dropped by the exchange"); ok = False

aud = claims.get("aud")
aud_list = aud if isinstance(aud, list) else [aud]
if "vault" in aud_list:
    print(f"  PASS: aud contains 'vault' -- {aud}")
else:
    print(f"  FAIL: aud does not contain 'vault' -- {aud} (may need a registered API/resource in the tenant)"); ok = False

print()
if ok:
    print("Phase 0b PASSES -- record these sub/act.sub values, they're what terraform/obo.tf's Verify profile aliases need as external_id.")
else:
    print("Phase 0b FAILS on at least one claim -- see eventual-wandering-tower.md's fallback plan (ship Phase 1 against the local obo-probe profile instead).")
sys.exit(0 if ok else 1)
PYEOF
  exit $?
fi

KEYS_DIR="$REPO_ROOT/terraform/obo-probe-keys"
ISSUER="spiffe://nimbus.demo/obo-probe"
KID="obo-probe-key-0"
HUMAN_SUB="human-approver"
AGENT_SUB="agent-secure"

vault_env

PASS=0
FAIL=0

# Unlike 04-verify-agentic-iam.sh's check(), these tests compare an actual
# HTTP status code, not a command's exit code -- curl exits 0 on a 403
# unless told otherwise, so the exit code alone can't distinguish
# "correctly denied" from "request never reached Vault."
expect_http() {
  local name="$1" expected="$2" jwt_path="$3" url="$4"
  local body status
  body="$(curl -s -w '\n%{http_code}' -H "Authorization: Bearer $(cat "$jwt_path")" "$url")"
  status="${body##*$'\n'}"
  body="${body%$'\n'*}"
  if [ "$status" = "$expected" ]; then
    printf '  \033[1;32mPASS\033[0m  %s (HTTP %s)\n' "$name" "$status"
    PASS=$((PASS+1))
  else
    printf '  \033[1;31mFAIL\033[0m  %s (expected HTTP %s, got %s)\n' "$name" "$expected" "$status"
    FAIL=$((FAIL+1))
  fi
  echo "$body" | sed 's/^/        /'
}

mint() {
  # $1=out $2=path $3=actor_sub (empty string "" means no act/jti claim --
  # T4's whole point) $4..=capabilities. Takes actor_sub as an explicit
  # positional rather than a global array -- macOS's default /bin/bash is
  # 3.2, which raises "unbound variable" under `set -u` when expanding an
  # EMPTY array with "${arr[@]}", even quoted; confirmed the hard way.
  local out="$1" path="$2" actor_sub="$3"; shift 3
  local args=(--path "$path" --capabilities "$@" --sub "$HUMAN_SUB" --issuer "$ISSUER" --kid "$KID" --keys-dir "$KEYS_DIR" --out "$out")
  [ -n "$actor_sub" ] && args+=(--actor-sub "$actor_sub")
  python3 "$REPO_ROOT/scripts/mint_rar_jwt.py" "${args[@]}" >/dev/null
}

log "0. setup -- ensure the throwaway OBO-probe signing key exists"
if [ ! -f "$KEYS_DIR/rar_probe_key.pub.pem" ]; then
  warn "no signing key at $KEYS_DIR -- generating one now (terraform/obo.tf must be (re-)applied after this, if not already)"
fi
mint /tmp/obo_setup.jwt "database/creds/refund-writer" "$AGENT_SUB" read
echo

log "1. diagnostics -- dump the real resource-server profile and entity-alias list"
log "   (this is the single biggest unknown in Phase 0a -- read the actual response, don't assume)"
vault read sys/config/oauth-resource-server/obo-probe 2>&1 || warn "profile not found -- did terraform apply obo.tf succeed?"
echo
ALIAS_IDS="$(vault list -format=json identity/entity-alias/id 2>/dev/null | python3 -c 'import json,sys; [print(x) for x in json.load(sys.stdin)]' 2>/dev/null || true)"
if [ -n "$ALIAS_IDS" ]; then
  while IFS= read -r aid; do
    echo "  --- entity-alias $aid ---"
    vault read identity/entity-alias/id/"$aid" 2>&1 | grep -E "mount_accessor|issuer|external_id|canonical_id|^name" | sed 's/^/    /'
  done <<< "$ALIAS_IDS"
else
  warn "could not list entity-aliases (or none exist yet -- did terraform apply obo.tf succeed?)"
fi
echo

VAULT_URL="$VAULT_ADDR/v1"

log "2. T1 -- happy path: human=$HUMAN_SUB, act=$AGENT_SUB, RAR grants refund-writer read, request matches"
mint /tmp/obo_t1.jwt "database/creds/refund-writer" "$AGENT_SUB" read
expect_http "T1 happy path" 200 /tmp/obo_t1.jwt "$VAULT_URL/database/creds/refund-writer"
echo

log "3. T2 -- THE PAYOFF: RAR grants customer-pii-reader (human's own policy allows it, agent's ceiling does not)"
mint /tmp/obo_t2.jwt "database/creds/customer-pii-reader" "$AGENT_SUB" read
expect_http "T2 ceiling should catch this" 403 /tmp/obo_t2.jwt "$VAULT_URL/database/creds/customer-pii-reader"
echo

log "4. T3 -- RAR path mismatch: claim says refund-writer, actual request is order-reader"
mint /tmp/obo_t3.jwt "database/creds/refund-writer" "$AGENT_SUB" read
expect_http "T3 RAR path mismatch" 403 /tmp/obo_t3.jwt "$VAULT_URL/database/creds/order-reader"
echo

log "5. T4 -- control: same as T1 but no act/jti claim (reproduces the 2026-10-17 finding)"
mint /tmp/obo_t4.jwt "database/creds/refund-writer" "" read
expect_http "T4 no-actor control" 403 /tmp/obo_t4.jwt "$VAULT_URL/database/creds/refund-writer"
echo

log "6. T5 -- narrow human-approver-policy to drop refund-writer, confirm the human half is real"
vault policy write human-approver-policy - <<'EOF'
path "database/creds/customer-pii-reader" {
  capabilities = ["read"]
}
EOF
mint /tmp/obo_t5.jwt "database/creds/refund-writer" "$AGENT_SUB" read
expect_http "T5 human policy narrowed" 403 /tmp/obo_t5.jwt "$VAULT_URL/database/creds/refund-writer"
log "   reverting human-approver-policy to its terraform-declared form"
vault policy write human-approver-policy - <<'EOF'
path "database/creds/refund-writer" {
  capabilities = ["read"]
}
path "database/creds/customer-pii-reader" {
  capabilities = ["read"]
}
EOF
echo

log "summary: $PASS passed, $FAIL failed"
log "PASS GATE: T1=200 and T2,T3,T4,T5=403 all hold -- record the actual results in docs/RUNBOOK.md either way."
if [ "$FAIL" -eq 0 ]; then
  log "Phase 0a PASSES -- Vault enforces the three-way intersection on a correctly-shaped OBO token. Proceed to Phase 0b/1."
else
  warn "Phase 0a has failures above -- do NOT proceed to Phase 1 until each is understood (see this repo's fallback plan in eventual-wandering-tower.md)."
fi
