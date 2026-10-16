# Vault's "Agentic IAM" feature: Agent Registry + a ceiling policy, and an
# OAuth resource server profile enforcing RFC 9396 Rich Authorization
# Requests (RAR). Enterprise-only, GA in Vault 2.1 (2026-09-01).
#
# Gated behind var.agentic_iam_available (default false) -- see
# docs/RUNBOOK.md's "Agentic IAM" section. Unlike every other optional
# branch in this repo, NONE of this could be tested at all while it was
# written: Vault Enterprise's own dev-mode binary refuses to start without
# a real license (confirmed directly -- `docker run hashicorp/vault-
# enterprise` fails with "license check failed: no autoloaded license
# provided"), and that license is sales/support-gated. Once a trial license
# is installed (scripts/dev/configure_agentic_iam.sh runs the equivalent
# config locally for testing), set agentic_iam_available=true here.
#
# Deliberately does NOT attempt the on-behalf-of (OBO) / token-exchange
# half of Agentic IAM -- that needs `actor_claim`, which the Terraform
# provider documents as requiring Vault 2.2.0+ (only at rc1, not GA, as of
# this writing), AND an external IdP actually capable of RFC 8693 token
# exchange with `act`/`may_act` claims, which among HashiCorp's documented
# providers is only IBM Verify (Auth0's documented path is NOT real OBO --
# it's a single-identity authorization_code + PAR/RAR flow). Both are
# sales-gated enterprise products on top of an already sales-gated license.
# This stays scoped to what's achievable without a human-delegation
# identity exchange: register the agent, cap it with a ceiling policy, and
# enforce a per-request RAR constraint.

resource "vault_identity_entity" "agent_secure" {
  count = var.agentic_iam_available ? 1 : 0
  name  = "agent-${var.agent_service_account}"
}

# Binds the entity to whichever auth backend actually authenticates this
# workload (the auth/jwt fallback by default -- see vault-config.tf), using
# the SPIFFE ID as the alias name, matching user_claim=sub on that role.
resource "vault_identity_entity_alias" "agent_secure" {
  count          = var.agentic_iam_available ? 1 : 0
  name           = "spiffe://${var.trust_domain}/ns/${var.agent_namespace}/sa/${var.agent_service_account}"
  mount_accessor = var.spiffe_auth_available ? vault_auth_backend.spiffe[0].accessor : vault_jwt_auth_backend.jwt[0].accessor
  canonical_id   = vault_identity_entity.agent_secure[0].id
}

# Deliberately narrower than policy "agent-support" (no sys/leases/revoke,
# no auth/token/create) -- a ceiling policy can only CAP what an agent's
# actual policies allow, never grant beyond them. Whether Vault enforces
# this ceiling at all OUTSIDE an OBO exchange is unconfirmed -- the docs
# frame enforcement as "the intersection of the ceiling policy, policies
# assigned to the human user, and RAR constraints," which presumes an OBO
# flow exists. Registering it is still correct per the schema; test its
# actual runtime effect once you have a license -- see
# scripts/04-verify-agentic-iam.sh.
resource "vault_policy" "agent_ceiling" {
  count  = var.agentic_iam_available ? 1 : 0
  name   = "agent-ceiling"
  policy = <<-EOT
    path "database/creds/refund-writer" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_agent_registration" "agent_secure" {
  count            = var.agentic_iam_available ? 1 : 0
  display_name     = var.agent_service_account
  entity_id        = vault_identity_entity.agent_secure[0].id
  description      = "Nimbus Store support agent -- issues refunds via a Vault-scoped, 3-minute database credential"
  ceiling_policies = [vault_policy.agent_ceiling[0].name]
}

# Lets Vault validate a Bearer JWT directly against a configured profile on
# normal API calls (resource-server mode), as opposed to a `vault login`.
# Points at the SAME static SPIRE bundle used for the auth/jwt fallback --
# nothing requires the "OAuth resource server" to be a classic consumer IdP
# like Auth0; it only needs a signer and a JWKS/public key set, which SPIRE
# already is. Whether this request-validation path actually activates
# (as opposed to only mattering inside a real OAuth/OBO flow) is the single
# biggest unverified assumption in this file -- see
# scripts/04-verify-agentic-iam.sh and docs/RUNBOOK.md.
resource "vault_oauth_resource_server_config_profile" "spire" {
  count        = var.agentic_iam_available ? 1 : 0
  profile_name = "spire"
  issuer_id    = "spiffe://${var.trust_domain}"
  use_jwks     = false
  user_claim   = "sub"
  audiences    = ["vault"]

  dynamic "public_keys" {
    for_each = { for idx, path in var.spiffe_bundle_pem_paths : idx => path }
    content {
      key_id = "spire-key-${public_keys.key}"
      pem    = file(public_keys.value)
    }
  }

  # RAR is additive to ACL policy, never a substitute for it -- a request
  # must pass BOTH. optional_authorization_details=false means a request
  # through this profile without an authorization_details claim is refused
  # outright, rather than falling back to plain policy enforcement.
  optional_authorization_details = false
}
