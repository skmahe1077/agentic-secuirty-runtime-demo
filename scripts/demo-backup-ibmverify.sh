#!/usr/bin/env bash
# STANDALONE BACKUP CLIP -- not part of the main recorded demo flow.
# Purpose: real, on-screen evidence for the one-sentence claim in beat 3
# ("we tested this against a real IdP, RAR doesn't survive it") -- not
# something to cut into the primary recording, which stays focused on
# Vault's own mechanics. Keep this in your back pocket for a Q&A follow-up
# or an appendix slide, per docs/RUNBOOK.md's Phase 0b update.
#
# Requires .env.ibmverify at the repo root (gitignored, never committed):
#   IBM_VERIFY_TOKEN_ENDPOINT
#   IBM_VERIFY_CLIENT_ID / IBM_VERIFY_CLIENT_SECRET          (the AGENT's app registration)
#   IBM_VERIFY_HUMAN_CLIENT_ID / IBM_VERIFY_HUMAN_CLIENT_SECRET  (a SEPARATE app -- IBM Verify
#     refuses to exchange a token for itself if both halves come from the same client; confirmed
#     live, see docs/RUNBOOK.md)
#   IBM_VERIFY_HUMAN_USERNAME / IBM_VERIFY_HUMAN_PASSWORD    (a dedicated Cloud Directory test
#     user -- NOT your admin/SSO login, ROPC can't validate that)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

ENV_FILE="$REPO_ROOT/.env.ibmverify"
[ -f "$ENV_FILE" ] || die "no $ENV_FILE -- see this script's header comment for what it needs"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
for v in IBM_VERIFY_TOKEN_ENDPOINT IBM_VERIFY_CLIENT_ID IBM_VERIFY_CLIENT_SECRET \
         IBM_VERIFY_HUMAN_CLIENT_ID IBM_VERIFY_HUMAN_CLIENT_SECRET \
         IBM_VERIFY_HUMAN_USERNAME IBM_VERIFY_HUMAN_PASSWORD; do
  [ -n "${!v:-}" ] || die "$ENV_FILE is missing $v"
done

RAR='[{"type":"vault:path_access","path":"database/creds/refund-writer","capabilities":["read"]}]'

log "1. minting the human's token -- via its OWN app registration, not the agent's"
HUMAN_RESP="$(curl -s -X POST "$IBM_VERIFY_TOKEN_ENDPOINT" \
  -d grant_type=password \
  -d "client_id=$IBM_VERIFY_HUMAN_CLIENT_ID" \
  -d "client_secret=$IBM_VERIFY_HUMAN_CLIENT_SECRET" \
  --data-urlencode "username=$IBM_VERIFY_HUMAN_USERNAME" \
  --data-urlencode "password=$IBM_VERIFY_HUMAN_PASSWORD")"
SUBJECT_TOKEN="$(echo "$HUMAN_RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')"
[ -n "$SUBJECT_TOKEN" ] || die "ROPC failed -- raw response: $HUMAN_RESP"
log "   got it (not printing it on screen -- it's a live credential)"
echo

log "2. minting the agent's own token -- client_credentials, its real identity"
ACTOR_TOKEN="$(curl -s -X POST "$IBM_VERIFY_TOKEN_ENDPOINT" \
  -d grant_type=client_credentials \
  -d "client_id=$IBM_VERIFY_CLIENT_ID" \
  -d "client_secret=$IBM_VERIFY_CLIENT_SECRET" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("access_token",""))')"
[ -n "$ACTOR_TOKEN" ] || die "client_credentials grant failed"
echo

log "3. THE REAL RFC 8693 TOKEN EXCHANGE -- this is the money shot, narrate it live"
log "   subject = the human, actor = the agent, authorization_details = read-only on refund-writer"
EXCHANGE_RESP="$(curl -s -w '\n%{http_code}' -X POST "$IBM_VERIFY_TOKEN_ENDPOINT" \
  -d "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
  -d "client_id=$IBM_VERIFY_CLIENT_ID" \
  -d "client_secret=$IBM_VERIFY_CLIENT_SECRET" \
  -d "subject_token=$SUBJECT_TOKEN" \
  -d "subject_token_type=urn:ietf:params:oauth:token-type:access_token" \
  -d "actor_token=$ACTOR_TOKEN" \
  -d "actor_token_type=urn:ietf:params:oauth:token-type:access_token" \
  --data-urlencode "authorization_details=$RAR")"
STATUS="${EXCHANGE_RESP##*$'\n'}"
BODY="${EXCHANGE_RESP%$'\n'*}"
log "   HTTP $STATUS"
echo

log "4. decoding the result LIVE -- say the line: 'watch what's missing'"
echo "$BODY" | python3 -c "
import json, sys, base64

body = sys.stdin.read()
try:
    d = json.loads(body)
except Exception:
    print('  non-JSON response:', body)
    sys.exit(1)

if 'access_token' not in d:
    print('  exchange failed:', json.dumps(d, indent=2))
    sys.exit(1)

parts = d['access_token'].split('.')
padded = parts[1] + '=' * (-len(parts[1]) % 4)
claims = json.loads(base64.urlsafe_b64decode(padded))

print('  decoded claims (the raw JWT itself is not printed, only its contents):')
print('  ' + json.dumps(claims, indent=2).replace(chr(10), chr(10) + '  '))
print()
print('  sub (the human):', claims.get('sub'), '-- PRESENT, this is real delegation')
act = claims.get('act', {})
print('  act.sub (the agent):', act.get('sub'), '-- PRESENT, this is real delegation')
ad = claims.get('authorization_details')
print('  authorization_details:', ad if ad is not None else '(not present in the claims above -- scroll up and check)', '-- Say the line:')
print('    \"we asked for read-only on exactly one role -- that scoping request vanished.')
print('     Not rejected, not an error. Silently dropped. This is why this demo signs its')
print('     own delegation token locally -- what Vault enforces on receipt is identical')
print('     either way, but only one of these two paths can actually carry the scope.\"')
"
