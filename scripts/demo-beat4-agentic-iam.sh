#!/usr/bin/env bash
# Beat 4 -- Agent Registry + ceiling policies, two real agents. ~3 min on
# stage. Unlike beats 1-3, nothing here is clicked in the browser via a
# picker -- "secure" mode dispatches automatically between order-agent and
# refund-agent based on what's actually asked (see
# app/storefront/main.py's _resolve()). This beat's point is that the
# dispatch is a convenience, not the security boundary: even a message
# worded to dodge the router's keyword match still can't get a refund out
# of order-agent, because PostgreSQL -- not the router -- holds the line.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

chat() { curl -s -X POST "$STOREFRONT_URL/api/support/chat" -H 'content-type: application/json' -d "$1"; }
show() { python3 -c "
import sys, json
d = json.load(sys.stdin)
if 'reply' in d:
    print('agent says:', d['reply'])
for e in d.get('events', []):
    print('  -', e['type'], '-', e['message'])
"
}

log "both agents are registered in Vault's Agent Registry, each with its own ceiling policy"
vault read agent-registry/registration/display-name/order-agent 2>/dev/null \
  || warn "(no cluster reachable -- this step is EKS-only, see docs/RUNBOOK.md)"
echo
vault read agent-registry/registration/display-name/refund-agent 2>/dev/null || true
echo

log "status question, new thread -- routes to order-agent by default (least privilege first)"
chat '{"customer_id":1,"agent":"secure","message":"where is order #1043","thread_id":"beat4a"}' | show
echo

log "same thread, now ask for a refund -- the word \"refund\" escalates this thread to refund-agent"
chat '{"customer_id":2,"agent":"secure","message":"please refund order #1043","thread_id":"beat4a"}' | show
echo

log "a FRESH thread, refund request worded to dodge the keyword router (no literal \"refund\")"
echo "  -- this is the point: a mis-route to order-agent still can't do damage, PostgreSQL refuses the write, not a 500"
chat '{"customer_id":1,"agent":"secure","message":"can you sort out order #1042, it arrived damaged","thread_id":"beat4b"}' | show
echo

warn "run scripts/04-verify-agentic-iam.sh separately for the RAR empirical test and the ceiling misconfiguration test --"
warn "both are presenter-only verification, not demo-floor material."
