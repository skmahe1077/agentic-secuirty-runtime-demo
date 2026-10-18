# Phase 0a of the real-OBO-delegation work (see
# ~/.claude/plans/eventual-wandering-tower.md). Answers ONE question before
# IBM Verify is touched at all: does Vault actually enforce the three-way
# intersection (ceiling ∧ human's own policy ∧ RAR authorization_details)
# on a correctly-shaped OBO token? A prior test (docs/RUNBOOK.md,
# 2026-10-17) sent a bare Bearer JWT with no `act` claim and no `jti`
# against a profile whose `actor_claim`/`unique_id_claim` default
# server-side to `act.sub`/`jti` -- that was never a real OBO request, so
# its "RAR isn't enforced outside OBO" conclusion is suspect, not settled.
# This file is deliberately throwaway/local-signed: it answers the
# enforcement question without any external IdP dependency. Whether IBM
# Verify can actually MINT a token shaped like this is a separate question
# (Phase 0b) -- this file doesn't depend on the answer.
#
# Signing key: terraform/obo-probe-keys/ (gitignored, same pattern as
# spiffe-bundle-keys/ below) -- generate it BEFORE running `terraform
# apply` here:
#   python3 scripts/mint_rar_jwt.py --keys-dir terraform/obo-probe-keys \
#     --sub human-approver --actor-sub agent-secure --out /tmp/obo_setup.jwt
# scripts/05-verify-obo.sh's setup step does this automatically.

locals {
  obo_probe_pub_key_paths = sort(tolist(fileset(path.module, "obo-probe-keys/*.pub.pem")))
}

check "obo_probe_key_present" {
  assert {
    condition     = length(local.obo_probe_pub_key_paths) > 0
    error_message = "terraform/obo-probe-keys/ is empty -- run scripts/05-verify-obo.sh's setup step (or the mint_rar_jwt.py command in this file's header comment) before applying obo.tf."
  }
}

# The "human's own policy" half of OBO's three-way intersection.
# Deliberately an ordinary ACL policy, not a vault_agent_registration
# (that resource is for AGENT identities with ceiling_policies) --
# broader than agent-ceiling on purpose, so T2 in scripts/05-verify-obo.sh
# can show the ceiling catching a delegated request the human's own
# policy would otherwise allow.
resource "vault_identity_entity" "human_approver" {
  name     = "human-approver"
  policies = [vault_policy.human_approver.name]
}

resource "vault_policy" "human_approver" {
  name   = "human-approver-policy"
  policy = <<-EOT
    path "database/creds/refund-writer" {
      capabilities = ["read"]
    }
    path "database/creds/customer-pii-reader" {
      capabilities = ["read"]
    }
  EOT
}

# OAuth resource-server profile for the OBO spike -- its own issuer_id,
# distinct from "spire" (terraform/agentic-iam.tf) and from "rar-probe"
# (scripts/04-verify-agentic-iam.sh's imperative, throwaway one). Unlike
# "spire", this one sets actor_claim explicitly (it happens to match
# Vault's own default, but naming it here makes the mechanism visible in
# the plan/diff rather than relying on an undocumented default) and a
# nonzero clock_skew_leeway -- 0 is the provider default and is a real
# failure mode against EKS node clock drift on a live demo.
resource "vault_oauth_resource_server_config_profile" "obo_probe" {
  profile_name = "obo-probe"
  issuer_id    = "spiffe://${var.trust_domain}/obo-probe"
  use_jwks     = false
  user_claim   = "sub"
  actor_claim  = "act.sub"
  audiences    = ["vault"]

  clock_skew_leeway              = 30
  optional_authorization_details = false

  dynamic "public_keys" {
    for_each = { for idx, path in local.obo_probe_pub_key_paths : idx => path }
    content {
      key_id = "obo-probe-key-${public_keys.key}"
      pem    = file(public_keys.value)
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.obo_probe_pub_key_paths) > 0
      error_message = "refusing to register the 'obo-probe' OAuth resource server profile with zero public_keys"
    }
  }
}

# Entity-alias binding for the OBO spike -- resolved empirically, not
# guessed: an OAuth resource-server profile DOES expose a real
# `mount_accessor` (auto-generated as
# "oauth-resource-server_root_<config_id>", confirmed by `vault read
# sys/config/oauth-resource-server/obo-probe` after applying the profile
# above) -- the plan's R1/R2 risk ("does a resource-server profile even
# have a mount accessor to alias against?") is answered: yes. So the
# ordinary vault_identity_entity_alias resource is exactly right here;
# the provider's "mount_accessor required" schema was not the obstacle it
# looked like. But vault_oauth_resource_server_config_profile does NOT
# export mount_accessor as a resource attribute (confirmed: Terraform
# rejects referencing it directly) -- read it back via the generic data
# source instead, which just does a raw `vault read` of the same path.
data "vault_generic_secret" "obo_probe_config" {
  path       = "sys/config/oauth-resource-server/obo-probe"
  depends_on = [vault_oauth_resource_server_config_profile.obo_probe]
}

resource "vault_identity_entity_alias" "obo_human_alias" {
  name           = "obo-human-approver"
  canonical_id   = vault_identity_entity.human_approver.id
  mount_accessor = data.vault_generic_secret.obo_probe_config.data["mount_accessor"]
  issuer         = vault_oauth_resource_server_config_profile.obo_probe.issuer_id
  external_id    = "human-approver"
}

# Binds the OBO spike's `act.sub` claim to the EXISTING refund-agent
# entity (terraform/agentic-iam.tf's vault_identity_entity.agent_secure) --
# not a new entity -- so the ceiling already tied to that entity via
# vault_agent_registration.agent_secure actually applies to this request.
resource "vault_identity_entity_alias" "obo_agent_alias" {
  name           = "obo-agent-secure"
  canonical_id   = vault_identity_entity.agent_secure.id
  mount_accessor = data.vault_generic_secret.obo_probe_config.data["mount_accessor"]
  issuer         = vault_oauth_resource_server_config_profile.obo_probe.issuer_id
  external_id    = "agent-secure"
}
