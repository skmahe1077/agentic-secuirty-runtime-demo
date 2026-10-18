#!/usr/bin/env bash
# Beat 3 -- human intent -> agent action -> audit trail, via REAL Vault OBO
# delegation (not metadata on a child token -- see app/agent/src/agent/obo.py
# and docs/RUNBOOK.md's "OBO -- what was actually tested"). ~4 min on stage.
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

log "presenter-login: caching '$APPROVER' as the approver (NOT a real IdP login -- see docs/RUNBOOK.md)"
"$(dirname "${BASH_SOURCE[0]}")/presenter-login.sh" "$APPROVER"
echo

log "Ruba asks for a £450 refund on order #1044 -- well over the auto-approval limit"
chat '{"customer_id":3,"agent":"secure","message":"please refund order #1044","thread_id":"beat3"}' | show
echo

log "approving -- no name typed in, the Approve click just signals 'use the cached human credential now'"
resume '{"agent":"secure","thread_id":"beat3"}' | show
echo

log "the storefront's Agentic Workflow panel now shows the correlation -- not a log tail"
echo "  Audit correlation: approved by $APPROVER, act.sub=agent-secure, credential <lease id>"
echo
log 'say the line: "the credential is gone in under a minute -- this record is not."'
warn "the DB lease's TTL is capped by the delegation token's own ~60s validity (an OBO property, not a bug) -- shorter than the 3-minute TTL the non-delegated path gets. See credential_issued's ttl_seconds."
warn "Vault's own audit log carries the identical fields on this request (presenter-only verification, not shown on stage) -- see scripts/03-verify.sh check 5 and docs/RUNBOOK.md."
