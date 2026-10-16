#!/usr/bin/env bash
# Orchestrates one clean, paced run of all three beats so you can screen-
# record it as the fallback video. This script does NOT do the screen
# recording itself -- start QuickTime / OBS / `screencapture` first, with
# both the browser (storefront + Identity & Access panel) and this
# terminal visible, THEN run this script.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

PAUSE="${PAUSE_SECONDS:-4}"
pause() { echo; sleep "$PAUSE"; }

log "resetting to a clean state"
"$REPO_ROOT/scripts/reset.sh"
pause

log "=== BEAT 1: standing access ==="
"$REPO_ROOT/scripts/demo-beat1.sh"
pause

log "=== BEAT 2: SPIFFE identity + JIT credential ==="
"$REPO_ROOT/scripts/demo-beat2.sh"
pause

log "=== BEAT 3: human intent -> audit trail ==="
"$REPO_ROOT/scripts/demo-beat3.sh" "${1:-}"

log "done -- stop the recording."
