#!/usr/bin/env bash
# Run ONCE before a demo window, in the green room. Declares "a human is
# present for the next 30 minutes, call them X" to the storefront -- NOT a
# real IdP login. There's no external IdP in this fallback (see
# docs/RUNBOOK.md's "OBO -- what was actually tested", Phase 0b result:
# IBM Verify's documented token-exchange grant never mentions RFC 9396
# authorization_details at all, so there's nothing to log into). The
# agent itself signs the real delegated OBO token at refund-approval time
# (app/agent/src/agent/obo.py), using a FIXED subject identifier
# ("human-approver", matching terraform/obo.tf's entity-alias) regardless
# of whatever display name is entered here -- that's cosmetic, not
# cryptographic. Say so if asked: this is the one deliberate shortcut in
# an otherwise-real OBO flow.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

name="${1:-}"
if [ -z "$name" ]; then
  read -r -p "Approver's display name (shown in the Agentic Workflow, not cryptographically verified): " name
fi
[ -n "$name" ] || die "need a name"

resp="$(curl -s -X POST "$STOREFRONT_URL/api/admin/human-token" \
  -H 'content-type: application/json' \
  -d "$(python3 -c 'import json,sys; print(json.dumps({"display_name": sys.argv[1]}))' "$name")")"

echo "$resp"
log "cached. Approve as '$name' is live in the Agentic Workflow for the next 30 minutes."
warn "re-run this script if the demo runs long -- the cache expires, and Approve will show as disabled once it does."
