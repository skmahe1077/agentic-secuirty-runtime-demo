# Vault's "Agentic IAM" feature: Agent Registry + ceiling policies, and an
# OAuth resource server profile enforcing RFC 9396 Rich Authorization
# Requests (RAR). Enterprise-only, GA in Vault 2.1 (2026-09-01).
#
# TWO agents are registered here, not one: refund-agent (can look up orders
# AND issue refunds) and order-agent (read-only, cannot issue refunds --
# see terraform/vault-config.tf's order_reader DB role and order_agent_policy).
# Each is a genuinely separate SPIFFE identity (separate k8s ServiceAccount,
# separate ClusterSPIFFEID), not two registrations pointing at the same
# workload -- a ceiling policy only means something if the agent's actual
# policy could grant more than the ceiling allows, and two registrations on
# one identity couldn't demonstrate that. The storefront dispatches to
# whichever one fits the customer's request automatically -- see
# app/storefront/main.py's _resolve(); the ceiling here caps what Agentic
# IAM additionally restricts on top of that, which is the open question
# below.
#
# Now ungated and unconditional: a Vault Enterprise trial license is
# installed on the self-managed cluster, so this is no longer "could not
# be tested at all" -- scripts/04-verify-agentic-iam.sh is the real
# assertion against the real cluster.
#
# UPDATE (2026-10-17): the Vault-side OBO mechanics ARE now confirmed
# working -- see terraform/obo.tf and docs/RUNBOOK.md's "OBO -- what was
# actually tested" section. A correctly-shaped delegated token (`act.sub`
# + `jti`, against a resource-server profile with `actor_claim` set) gets
# RAR-checked AND ceiling-checked for real (`CEILING_POLICY_DENIED` is a
# real Vault error code, not a hypothetical). What's still open is who
# SIGNS that token in production: this repo's spike uses a throwaway
# local key, not a real external IdP. Among HashiCorp's documented
# providers, real RFC 8693 token exchange with `act`/`may_act` claims is
# only IBM Verify (Auth0's documented path is NOT real OBO -- it's a
# single-identity authorization_code + PAR/RAR flow, and Auth0's RAR/PAR
# support itself needs an Enterprise-tier tenant); both are sales-gated
# products on top of an already-gated license. See
# ~/.claude/plans/eventual-wandering-tower.md's Phase 0b for that half.

resource "vault_identity_entity" "agent_secure" {
  name = "agent-${var.agent_service_account}"
}

resource "vault_identity_entity_alias" "agent_secure" {
  name           = "spiffe://${var.trust_domain}/ns/${var.agent_namespace}/sa/${var.agent_service_account}"
  mount_accessor = vault_auth_backend.spiffe.accessor
  canonical_id   = vault_identity_entity.agent_secure.id
}

# Deliberately narrower than policy "agent-support" (no sys/leases/revoke,
# no auth/token/create) -- a ceiling policy can only CAP what an agent's
# actual policies allow, never grant beyond them. Whether Vault enforces
# this ceiling at all OUTSIDE an OBO exchange is unconfirmed -- the docs
# frame enforcement as "the intersection of the ceiling policy, policies
# assigned to the human user, and RAR constraints," which presumes an OBO
# flow exists. Registering it is still correct per the schema; test its
# actual runtime effect now that there's a real license -- see
# scripts/04-verify-agentic-iam.sh.
resource "vault_policy" "agent_ceiling" {
  name   = "agent-ceiling"
  policy = <<-EOT
    path "database/creds/refund-writer" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_agent_registration" "agent_secure" {
  display_name     = "refund-agent"
  entity_id        = vault_identity_entity.agent_secure.id
  description      = "Mahi Stores support agent -- issues refunds via a Vault-scoped, 3-minute database credential"
  ceiling_policies = [vault_policy.agent_ceiling.name]
}

# ---- order-agent: the read-only counterpart ------------------------------
# Same pattern as refund-agent above, bound to its own SPIFFE identity
# (terraform/vault-config.tf's spiffe_role_order_agent,
# k8s_manifests/order-agent/). Its ceiling is identical in scope to its real
# policy (order_agent_policy) for the same reason refund-agent's always
# was -- nothing to misconfigure yet. scripts/04-verify-agentic-iam.sh's
# deliberate-misconfiguration test is what actually probes whether the
# ceiling does anything independent of the real policy.
resource "vault_identity_entity" "order_agent" {
  name = "agent-${var.order_agent_service_account}"
}

resource "vault_identity_entity_alias" "order_agent" {
  name           = "spiffe://${var.trust_domain}/ns/${var.agent_namespace}/sa/${var.order_agent_service_account}"
  mount_accessor = vault_auth_backend.spiffe.accessor
  canonical_id   = vault_identity_entity.order_agent.id
}

resource "vault_policy" "order_agent_ceiling" {
  name   = "order-agent-ceiling"
  policy = <<-EOT
    path "database/creds/order-reader" {
      capabilities = ["read"]
    }
  EOT
}

resource "vault_agent_registration" "order_agent" {
  display_name     = "order-agent"
  entity_id        = vault_identity_entity.order_agent.id
  description      = "Mahi Stores order-lookup agent -- read-only, cannot issue refunds"
  ceiling_policies = [vault_policy.order_agent_ceiling.name]
}

# Lets Vault validate a Bearer JWT directly against a configured profile on
# normal API calls (resource-server mode), as opposed to a `vault login`.
# Points at the SAME static SPIRE bundle as auth/spiffe -- nothing requires
# the "OAuth resource server" to be a classic consumer IdP like Auth0; it
# only needs a signer and a JWKS/public key set, which SPIRE already is.
# Whether this request-validation path actually activates (as opposed to
# only mattering inside a real OAuth/OBO flow) is the single biggest
# unverified assumption in this file -- see scripts/04-verify-agentic-iam.sh
# and docs/RUNBOOK.md, and RECORD the actual HTTP codes there once known.
resource "vault_oauth_resource_server_config_profile" "spire" {
  profile_name = "spire"
  issuer_id    = "spiffe://${var.trust_domain}"
  use_jwks     = false
  user_claim   = "sub"
  audiences    = ["vault"]

  dynamic "public_keys" {
    for_each = { for idx, path in local.spiffe_bundle_pem_paths : idx => path }
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

  lifecycle {
    precondition {
      condition     = length(local.spiffe_bundle_pem_paths) > 0
      error_message = "refusing to register the 'spire' OAuth resource server profile with zero public_keys -- run scripts/refresh-bundle.sh first"
    }
  }
}
