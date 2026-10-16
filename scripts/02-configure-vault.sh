#!/usr/bin/env bash
# The one Vault step that is genuinely imperative rather than declarative
# state, and so deliberately lives outside terraform/vault-config.tf
# (Terraform models desired state; "rotate the password right now" is an
# action) -- see the comment in that file.
#
# Run AFTER terraform apply and AFTER confirming a break-glass DB admin
# exists that is NOT the one Vault is about to orphan itself from: this
# rotates the RDS master password Vault uses for the database secrets
# engine so that, after this runs, the password is known only to Vault.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

export VAULT_ADDR="$(tf_output vault_addr)"
export VAULT_TOKEN="$(tf_output vault_admin_token)"
export VAULT_NAMESPACE=admin

log "confirming a break-glass DB connection still works before rotating anything"
RDS_ENDPOINT="$(tf_output rds_endpoint)"
DB_MASTER_USERNAME="$(tf_output db_master_username)"
DB_MASTER_PASSWORD="$(tf_output rds_master_password)"
PGPASSWORD="$DB_MASTER_PASSWORD" psql -h "$RDS_ENDPOINT" -U "$DB_MASTER_USERNAME" -d nimbus -c "SELECT 1;" >/dev/null \
  || die "could not reach RDS as the master user -- do not rotate root until this works"

warn "about to rotate the RDS master password Vault uses -- after this, only Vault knows it."
warn "Terraform state still has the pre-rotation password; it will drift. That's expected."
read -r -p "type 'rotate' to continue: " confirm
[ "$confirm" = "rotate" ] || die "aborted"

vault write -f database/rotate-root/nimbus-rds
log "rotated. Vault now holds the only copy of the RDS master password."

log "sanity check: mint and immediately revoke a refund-writer credential"
LEASE_JSON="$(vault read -format=json database/creds/refund-writer)"
LEASE_ID="$(echo "$LEASE_JSON" | python3 -c 'import sys,json;print(json.load(sys.stdin)["lease_id"])')"
vault lease revoke "$LEASE_ID"
log "OK -- the database secrets engine round-trips."
