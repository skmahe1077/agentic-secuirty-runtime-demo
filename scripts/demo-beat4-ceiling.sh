#!/usr/bin/env bash
# Presenter-paced halves of the ceiling misconfiguration test, split out so
# each half can be run alone with a Agentic Workflow probe-button click in
# between -- scripts/04-verify-agentic-iam.sh runs widen -> CLI test ->
# revert in one shot, with no pause for a live click on stage.
#
#   bash scripts/demo-beat4-ceiling.sh widen order    # click 'order-agent -> refund-writer' before AND after this
#   bash scripts/demo-beat4-ceiling.sh revert order
#   bash scripts/demo-beat4-ceiling.sh widen refund   # click 'refund-agent -> customer-pii-reader' before AND after this
#   bash scripts/demo-beat4-ceiling.sh revert refund
#
# order-agent's escalation target is refund-writer (more money privilege --
# the thing order-agent is supposed to never get). refund-agent already
# holds refund-writer legitimately, so there's no role above it to test;
# its escalation target is customer-pii-reader instead (PII exposure --
# terraform/vault-config.tf's own comment calls `customers` "never granted
# to any agent role"). Must stay in sync with vault-config.tf's
# vault_policy.order_agent_policy / vault_policy.agent_support and
# scripts/04-verify-agentic-iam.sh's own widen/revert heredocs -- all are
# imperative-by-name writes to the same Vault policies, with no
# Terraform-state link between them (see docs/RUNBOOK.md's "Confirmed
# gotchas" on exactly this drift).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

mode="${1:-}"
agent="${2:-}"
[ "$mode" = "widen" ] || [ "$mode" = "revert" ] || die "usage: $0 widen|revert order|refund"
[ "$agent" = "order" ] || [ "$agent" = "refund" ] || die "usage: $0 widen|revert order|refund"

vault_env

if [ "$agent" = "order" ]; then
  if [ "$mode" = "widen" ]; then
    log "widening order-agent-policy to also grant database/creds/refund-writer read (the deliberate mistake)"
    vault policy write order-agent-policy - <<'EOF'
path "database/creds/order-reader" {
  capabilities = ["read"]
}
path "database/creds/refund-writer" {
  capabilities = ["read"]
}
path "sys/leases/revoke" {
  capabilities = ["update"]
}
path "agent-registry/registration/display-name/order-agent" {
  capabilities = ["read"]
}
EOF
    warn "now click 'order-agent -> refund-writer' in the Agentic Workflow -- it should succeed live and self-revoke."
  else
    log "reverting order-agent-policy to its narrow, Terraform-declared form"
    vault policy write order-agent-policy - <<'EOF'
path "database/creds/order-reader" {
  capabilities = ["read"]
}
path "sys/leases/revoke" {
  capabilities = ["update"]
}
path "agent-registry/registration/display-name/order-agent" {
  capabilities = ["read"]
}
EOF
    warn "click the probe button once more to confirm it's denied again before moving on."
  fi
else
  if [ "$mode" = "widen" ]; then
    log "widening agent-support to also grant database/creds/customer-pii-reader read (the deliberate mistake)"
    vault policy write agent-support - <<'EOF'
path "database/creds/refund-writer" {
  capabilities = ["read"]
}
path "database/creds/customer-pii-reader" {
  capabilities = ["read"]
}
path "sys/leases/revoke" {
  capabilities = ["update"]
}
path "auth/token/create" {
  capabilities = ["create", "update"]
}
path "agent-registry/registration/display-name/refund-agent" {
  capabilities = ["read"]
}
EOF
    warn "now click 'refund-agent -> customer-pii-reader' in the Agentic Workflow -- it should succeed live and self-revoke."
  else
    log "reverting agent-support to its narrow, Terraform-declared form"
    vault policy write agent-support - <<'EOF'
path "database/creds/refund-writer" {
  capabilities = ["read"]
}
path "sys/leases/revoke" {
  capabilities = ["update"]
}
path "auth/token/create" {
  capabilities = ["create", "update"]
}
path "agent-registry/registration/display-name/refund-agent" {
  capabilities = ["read"]
}
EOF
    warn "click the probe button once more to confirm it's denied again before moving on."
  fi
fi
