# Vault-side config for HCP Vault Dedicated, applied through the `vault`
# provider (see provider block in versions.tf -- operates in the `admin`
# namespace throughout, per HCP's root-namespace restriction).
#
# `var.spiffe_auth_available` is NOT guessed -- it is set only after
# scripts/03-verify.sh's go/no-go probe (`vault auth enable spiffe`) has
# actually succeeded against this cluster. Default is false, i.e. the
# auth/jwt fallback, which is what was exercised locally (see "Validated
# locally" in docs/RUNBOOK.md's planning notes) -- the auth/spiffe branch
# below follows documented syntax but has NOT been run against a real
# cluster, since that path needs an Enterprise license HCP may or may not
# grant on this tier.

# ---- native auth/spiffe path (Enterprise, GA 1.21+) ----------------------
# No typed `vault_spiffe_auth_backend_*` resource exists in the provider at
# the time this was written (the method is too new) -- vault_generic_endpoint
# writes the raw API paths instead, which works regardless of provider
# version and is the standard escape hatch for just-GA Vault features.

resource "vault_auth_backend" "spiffe" {
  count = var.spiffe_auth_available ? 1 : 0
  type  = "spiffe"
  path  = "spiffe"

  # The SVID goes in the Authorization header on login, not the JSON body --
  # Vault must be told to pass it through. (Confirmed against the provider's
  # actual schema: this lives under the `tune` block, not as a top-level
  # argument -- `vault auth enable -passthrough-request-headers=...` on the
  # CLI maps to a tune call under the hood.)
  tune {
    passthrough_request_headers = ["Authorization"]
  }
}

resource "vault_generic_endpoint" "spiffe_config" {
  count                = var.spiffe_auth_available ? 1 : 0
  depends_on           = [vault_auth_backend.spiffe]
  path                 = "auth/spiffe/config"
  ignore_absent_fields = true
  data_json = jsonencode({
    trust_domain = var.trust_domain
    profile      = "static" # see docs/RUNBOOK.md: no network reachability to SPIRE required
    bundle       = file(var.spiffe_bundle_jwks_path)
    audience     = "vault"
  })
}

resource "vault_generic_endpoint" "spiffe_role" {
  count                = var.spiffe_auth_available ? 1 : 0
  depends_on           = [vault_generic_endpoint.spiffe_config]
  path                 = "auth/spiffe/role/${var.agent_service_account}"
  ignore_absent_fields = true
  data_json = jsonencode({
    # omits the `spiffe://<trust_domain>/` prefix -- see docs/RUNBOOK.md
    workload_id_patterns = ["ns/${var.agent_namespace}/sa/${var.agent_service_account}"]
    token_policies       = [vault_policy.agent_support.name]
    token_ttl            = "300"
  })
}

# ---- auth/jwt fallback (Community, the path validated locally) -----------

resource "vault_jwt_auth_backend" "jwt" {
  count                  = var.spiffe_auth_available ? 0 : 1
  path                   = "jwt"
  jwt_validation_pubkeys = var.spiffe_bundle_pem_paths == [] ? null : [for p in var.spiffe_bundle_pem_paths : file(p)]
}

resource "vault_jwt_auth_backend_role" "agent_secure" {
  count     = var.spiffe_auth_available ? 0 : 1
  backend   = vault_jwt_auth_backend.jwt[0].path
  role_name = "ai-support-agent"
  role_type = "jwt"

  user_claim      = "sub"
  bound_audiences = ["vault"]
  bound_subject   = "spiffe://${var.trust_domain}/ns/${var.agent_namespace}/sa/${var.agent_service_account}"

  # Confirmed locally (see docs/RUNBOOK.md): without this, `auth.metadata`
  # on the database/creds/* audit entry has no reliable, unmangled SPIFFE
  # ID -- `auth.display_name` sanitizes `:` and `/` into `-`.
  claim_mappings = {
    sub = "spiffe_id"
  }

  token_policies = [vault_policy.agent_support.name]
  token_ttl      = 300
}

# ---- database secrets engine ---------------------------------------------

resource "vault_mount" "database" {
  path = "database"
  type = "database"
}

resource "vault_database_secret_backend_connection" "nimbus" {
  backend       = vault_mount.database.path
  name          = "nimbus-rds"
  allowed_roles = ["refund-writer"]

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@${aws_db_instance.nimbus.address}:5432/${var.db_name}?sslmode=require"
    username       = var.db_master_username
    password       = random_password.db_master.result
  }

  # IMPORTANT: create a break-glass DB admin (see docs/RUNBOOK.md) BEFORE
  # running the rotate-root step below -- after rotation, this password is
  # known only to Vault.
}

# Terraform models state, not one-off actions -- root rotation is imperative
# ("rotate right now") so it is NOT a resource here. Run it explicitly from
# scripts/02-configure-vault.sh after `terraform apply` and after confirming
# the break-glass account exists:
#   vault write -f database/rotate-root/nimbus-rds

resource "vault_database_secret_backend_role" "refund_writer" {
  backend = vault_mount.database.path
  name    = "refund-writer"
  db_name = vault_database_secret_backend_connection.nimbus.name

  creation_statements = [
    <<-SQL
    CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
    GRANT CONNECT ON DATABASE ${var.db_name} TO "{{name}}";
    GRANT USAGE ON SCHEMA public TO "{{name}}";
    GRANT SELECT, UPDATE ON orders TO "{{name}}";
    GRANT INSERT ON refunds TO "{{name}}";
    GRANT USAGE, SELECT ON SEQUENCE refunds_refund_id_seq TO "{{name}}";
    SQL
  ]
  # REVOKE before DROP -- confirmed necessary locally: a bare `DROP ROLE`
  # fails in PostgreSQL while the role still holds grants, which would
  # silently break the on-stage revoke beat.
  revocation_statements = [
    <<-SQL
    REVOKE ALL PRIVILEGES ON refunds FROM "{{name}}";
    REVOKE ALL PRIVILEGES ON orders FROM "{{name}}";
    REVOKE USAGE, SELECT ON SEQUENCE refunds_refund_id_seq FROM "{{name}}";
    REVOKE USAGE ON SCHEMA public FROM "{{name}}";
    REVOKE CONNECT ON DATABASE ${var.db_name} FROM "{{name}}";
    DROP ROLE IF EXISTS "{{name}}";
    SQL
  ]

  default_ttl = 180 # 3 minutes
  max_ttl     = 600 # 10 minutes
}

# ---- policy ---------------------------------------------------------------
# sys/leases/revoke and auth/token/create are NOT implied by read access to
# database/creds/* -- both were missing in the first draft of this policy
# and both failed hard during local testing (see docs/RUNBOOK.md). Do not
# remove either without re-testing the revoke and human-approval beats.

resource "vault_policy" "agent_support" {
  name   = "agent-support"
  policy = <<-EOT
    path "database/creds/refund-writer" {
      capabilities = ["read"]
    }
    path "sys/leases/revoke" {
      capabilities = ["update"]
    }
    path "auth/token/create" {
      capabilities = ["create", "update"]
    }
  EOT
}
