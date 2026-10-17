# Vault-side config for the self-managed Vault Enterprise cluster on EKS,
# applied through the `vault` provider (see versions.tf -- the root
# namespace is ours now, nothing here runs inside an "admin" namespace).
#
# auth/spiffe is unconditional: self-managed Vault Enterprise definitely
# has it (it's GA in 1.21+), so there is no auth/jwt fallback branch and
# no feature gate here any more.

resource "vault_auth_backend" "spiffe" {
  type = "spiffe"
  path = "spiffe"

  # The SVID goes in the Authorization header on login, not the JSON body --
  # Vault must be told to pass it through. Confirmed against the provider's
  # schema: this lives under the `tune` block, not as a top-level argument.
  tune {
    passthrough_request_headers = ["Authorization"]
  }
}

resource "vault_generic_endpoint" "spiffe_config" {
  path                 = "auth/spiffe/config"
  ignore_absent_fields = true
  data_json = jsonencode({
    trust_domain = var.trust_domain
    profile      = "static" # see docs/RUNBOOK.md: no network reachability to SPIRE's OIDC endpoint required
    bundle       = file(var.spiffe_bundle_jwks_path)
    audience     = ["vault"] # array, not a bare string -- an empty list denies all JWT-based SVIDs
  })

  depends_on = [vault_auth_backend.spiffe]
}

resource "vault_generic_endpoint" "spiffe_role" {
  path                 = "auth/spiffe/role/${var.agent_service_account}"
  ignore_absent_fields = true
  data_json = jsonencode({
    # omits the `spiffe://<trust_domain>/` prefix -- see docs/RUNBOOK.md
    workload_id_patterns = ["ns/${var.agent_namespace}/sa/${var.agent_service_account}"]
    token_policies       = [vault_policy.agent_support.name]
    token_ttl            = "300"
  })

  depends_on = [vault_generic_endpoint.spiffe_config]
}

# A second, genuinely separate SPIFFE identity for order-agent -- not a
# second role bound to the same workload. Its own ClusterSPIFFEID
# (k8s_manifests/spire/values.yaml) issues it its own SVID; this role is
# what lets THAT identity (and no other) log in as order-agent.
resource "vault_generic_endpoint" "spiffe_role_order_agent" {
  path                 = "auth/spiffe/role/${var.order_agent_service_account}"
  ignore_absent_fields = true
  data_json = jsonencode({
    workload_id_patterns = ["ns/${var.agent_namespace}/sa/${var.order_agent_service_account}"]
    token_policies       = [vault_policy.order_agent_policy.name]
    token_ttl            = "300"
  })

  depends_on = [vault_generic_endpoint.spiffe_config]
}

# ---- database secrets engine ---------------------------------------------

resource "vault_mount" "database" {
  path = "database"
  type = "database"
}

resource "vault_database_secret_backend_connection" "nimbus" {
  backend       = vault_mount.database.path
  name          = "nimbus-rds"
  allowed_roles = ["refund-writer", "order-reader"]

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@${aws_db_instance.nimbus.address}:5432/${var.db_name}?sslmode=require"
    username       = var.db_master_username
    password       = random_password.db_master.result
  }

  # IMPORTANT: app/db/04_storefront_role.sql's dedicated nimbus_storefront
  # account must exist BEFORE running the rotate-root step below -- after
  # rotation, var.db_master_username's password is known only to Vault.
}

# Terraform models state, not one-off actions -- root rotation is imperative
# ("rotate right now") so it is NOT a resource here. Run it explicitly from
# scripts/02-configure-vault.sh after `terraform apply` and after confirming
# nimbus_storefront works:
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

# order-agent's role: read-only, deliberately no INSERT on refunds and no
# UPDATE anywhere. This -- not the ceiling policy -- is the PROVEN
# restriction mechanism in this repo: if order-agent is asked for a refund,
# PostgreSQL refuses the write, exactly like the customers-table denial
# below. See app/agent/src/agent/actions.py's issue_refund() for the
# InsufficientPrivilege catch that turns this into a clean `denied` event.
resource "vault_database_secret_backend_role" "order_reader" {
  backend = vault_mount.database.path
  name    = "order-reader"
  db_name = vault_database_secret_backend_connection.nimbus.name

  creation_statements = [
    <<-SQL
    CREATE ROLE "{{name}}" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';
    GRANT CONNECT ON DATABASE ${var.db_name} TO "{{name}}";
    GRANT USAGE ON SCHEMA public TO "{{name}}";
    GRANT SELECT ON orders TO "{{name}}";
    GRANT SELECT ON products TO "{{name}}";
    SQL
  ]
  revocation_statements = [
    <<-SQL
    REVOKE ALL PRIVILEGES ON products FROM "{{name}}";
    REVOKE ALL PRIVILEGES ON orders FROM "{{name}}";
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

# order-agent's real Vault policy -- deliberately narrower than
# agent-support: no auth/token/create (order-agent never mints an approval
# child-token, it never issues anything that needs approval). Keeps
# sys/leases/revoke so the storefront's "Revoke now" button still works on
# an order-agent credential -- revoking its own lease early is strictly
# MORE restrictive, not less, so there's no reason to withhold it.
resource "vault_policy" "order_agent_policy" {
  name   = "order-agent-policy"
  policy = <<-EOT
    path "database/creds/order-reader" {
      capabilities = ["read"]
    }
    path "sys/leases/revoke" {
      capabilities = ["update"]
    }
  EOT
}

# ---- audit ------------------------------------------------------------------
# Self-managed Enterprise can do what HCP Vault Dedicated could not: enable
# a real audit device declaratively. This is NOT a demo step -- the
# audience never sees this -- it exists so the correlation the storefront's
# "Audit correlation" panel claims is actually verifiable by the presenter,
# and so beat 3's claim is literally true rather than merely asserted.
# Depends on server.auditStorage.enabled = true in vault-cluster.tf's
# helm_release.vault: Vault fails a request outright if any enabled audit
# device cannot be written.
resource "vault_audit" "file" {
  type = "file"
  path = "file"
  options = {
    file_path = "/vault/audit/vault_audit.log"
  }
}
