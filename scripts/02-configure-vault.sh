#!/usr/bin/env bash
# The one Vault step that is genuinely imperative rather than declarative
# state, and so deliberately lives outside terraform/vault-config.tf
# (Terraform models desired state; "rotate the password right now" is an
# action) -- see the comment in that file.
#
# Run AFTER terraform apply and AFTER app/db/04_storefront_role.sql has
# been applied against RDS: this rotates the RDS MASTER password, which
# is the SAME account vault_database_secret_backend_connection.nimbus
# uses -- there is no separate break-glass admin (see
# terraform/variables.tf's db_master_username comment). After this runs,
# only Vault knows that password, so the pre-flight check below verifies
# the account everything else actually uses instead.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

STOREFRONT_DB_PASSWORD="${STOREFRONT_DB_PASSWORD:?set STOREFRONT_DB_PASSWORD -- see app/db/04_storefront_role.sql}"

vault_env

log "confirming the dedicated storefront DB account works BEFORE rotating the account Vault owns"
RDS_ENDPOINT="$(tf_output rds_endpoint)"
PGPASSWORD="$STOREFRONT_DB_PASSWORD" psql -h "$RDS_ENDPOINT" -U nimbus_storefront -d nimbus -c "SELECT 1;" >/dev/null \
  || die "nimbus_storefront cannot reach RDS -- rotating root now would leave nothing but Vault able to log in. Apply app/db/04_storefront_role.sql first."

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
