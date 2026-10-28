#!/usr/bin/env bash
# Opens the port-forward to Vault's UI and prints the root token to the
# terminal -- nothing written to disk beyond what vault-init.sh already
# wrote (terraform/.vault-init.json, gitignored, or Secrets Manager).
# Ctrl+C stops the port-forward.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

vault_env

log "Vault UI:   http://127.0.0.1:8200/ui"
log "Root token: $VAULT_TOKEN"
log "Ctrl+C to stop the port-forward"

wait "$VAULT_PF_PID"
