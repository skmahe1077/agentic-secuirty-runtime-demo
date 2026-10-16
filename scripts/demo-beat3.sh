#!/usr/bin/env bash
# Beat 3 -- human intent -> agent action -> audit trail. ~4 min on stage.
# Pass an approver name as $1, defaulting to a generic one so the script
# still runs unattended during rehearsal.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

APPROVER="${1:-$(whoami)}"

chat() { curl -s -X POST "$STOREFRONT_URL/api/support/chat" -H 'content-type: application/json' -d "$1"; }
resume() { curl -s -X POST "$STOREFRONT_URL/api/support/resume" -H 'content-type: application/json' -d "$1"; }
show() { python3 -c "
import sys, json
d = json.load(sys.stdin)
if 'reply' in d:
    print('agent says:', d['reply'])
for e in d.get('events', []):
    print('  -', e['type'], '-', e['message'])
"
}

log "Carol asks for a £450 refund on order #1044 -- well over the auto-approval limit"
chat '{"customer_id":3,"agent":"secure","message":"please refund order #1044","thread_id":"beat3"}' | show
echo

log "approving as '$APPROVER' (pass a different name as \$1 to use yours)"
resume "{\"agent\":\"secure\",\"thread_id\":\"beat3\",\"approved_by\":\"$APPROVER\"}" | show
echo

log "one Vault audit record now carries BOTH the workload identity and the human approval:"
echo '  grep "database/creds/refund-writer" <audit log> | tail -1'
echo '  -> auth.metadata = {"approval_id": "...", "approved_by": "'"$APPROVER"'", "spiffe_id": "spiffe://..."}'
echo
warn "on HCP: this is a CloudWatch Logs Insights query, pre-saved and pre-run before you go on stage."
warn "locally: 'docker exec nimbus-demo-vault-1 sh -c \"tail -2 /tmp/vault_audit.log\"' -- see docs/RUNBOOK.md."
