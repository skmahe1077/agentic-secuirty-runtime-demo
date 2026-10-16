#!/usr/bin/env bash
# Beat 2 -- SPIFFE identity + just-in-time credential. ~5 min on stage.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

chat() { curl -s -X POST "$STOREFRONT_URL/api/support/chat" -H 'content-type: application/json' -d "$1"; }
revoke() { curl -s -X POST "$STOREFRONT_URL/api/admin/revoke" -H 'content-type: application/json' -d '{"agent":"secure"}'; }
show() { python3 -c "
import sys, json
d = json.load(sys.stdin)
if 'reply' in d:
    print('agent says:', d['reply'])
for e in d.get('events', []):
    print('  -', e['type'], '-', e['message'])
"
}
lease_id_from() { python3 -c "
import sys, json
d = json.load(sys.stdin)
for e in d['events']:
    if e['type'] == 'credential_issued':
        print(e['lease_id'])
"
}

log "no secret anywhere in this pod -- just a SPIFFE identity"
kubectl -n agents exec deploy/agent-secure -c agent -- env 2>/dev/null | grep -iE 'pass|secret' \
  && die "found a secret in the env -- that should not be there" \
  || echo "  (confirmed: no PASS/SECRET env vars)"
kubectl -n agents exec deploy/agent-secure -c agent -- cat /svids/jwt_svid.token 2>/dev/null | cut -d. -f2 | base64 -d 2>/dev/null \
  || warn "(no cluster reachable -- this step is EKS-only, see docs/RUNBOOK.md)"
echo

log "Alice asks to refund order #1045 -- a fresh, 3-minute credential gets minted for this"
RESP="$(chat '{"customer_id":1,"agent":"secure","message":"please refund order #1045","thread_id":"beat2"}')"
echo "$RESP" | show
LEASE_ID="$(echo "$RESP" | lease_id_from)"
echo

log "same agent, denied: order #1046 belongs to Bob, not the customer chatting"
chat '{"customer_id":1,"agent":"secure","message":"please refund order #1046","thread_id":"beat2"}' | show
echo

log "same agent, denied: this credential's database role has no grant on customers at all"
chat '{"customer_id":1,"agent":"secure","message":"what is the phone number for customer 2","thread_id":"beat2"}' | show
echo

log "the money shot -- revoke the lease on command, don't wait out the TTL"
echo "  (this is exactly what happens automatically in 3 minutes -- forcing it now so the point lands on stage)"
revoke | show
echo
log "prove it's actually gone -- run this against RDS (local: 'docker exec nimbus-demo-postgres-1 psql ...')"
echo "  SELECT rolname FROM pg_roles WHERE rolname LIKE 'v-%';   -- expect 0 rows"
[ -n "${LEASE_ID:-}" ] && echo "  (the role backing lease $LEASE_ID should be the one that's gone)"
