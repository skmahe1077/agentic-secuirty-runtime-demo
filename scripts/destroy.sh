#!/usr/bin/env bash
# Tears down every billable resource this repo creates: EKS (which takes
# SPIRE down with it), RDS, the VPC, the HVN peering, and the HCP Vault
# Dedicated cluster. Run this after every rehearsal -- see the cost note
# in docs/RUNBOOK.md: this stack runs about $1.80/hr while up.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

warn "about to destroy the entire agentic-security-runtime-demo stack (EKS, RDS, VPC, HCP Vault, HVN)."
read -r -p "type 'destroy' to continue: " confirm
[ "$confirm" = "destroy" ] || die "aborted"

terraform -chdir="$TF_DIR" destroy

log "confirming nothing billable was left behind"
aws eks list-clusters --query 'clusters' --output table 2>/dev/null || true
aws rds describe-db-instances --query 'DBInstances[].DBInstanceIdentifier' --output table 2>/dev/null || true
warn "also check the HCP portal by hand -- the hcp CLI has no equivalent 'list and confirm empty' for Vault Dedicated clusters."

log "done."
