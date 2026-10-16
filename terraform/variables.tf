variable "aws_region" {
  description = "AWS region for EKS/RDS/VPC. The user's other demos in this account live in eu-west-1."
  type        = string
  default     = "eu-west-1"
}

variable "name" {
  description = "Short name prefix for every resource this stack creates."
  type        = string
  default     = "agentic-sec-demo"
}

variable "hvn_region" {
  description = "HCP region for the HVN -- must be a region HCP supports for the chosen cloud_provider, not necessarily identical in spelling to aws_region."
  type        = string
  default     = "eu-west-1"
}

variable "hvn_cidr" {
  description = "CIDR for the HashiCorp Virtual Network. Must not overlap vpc_cidr."
  type        = string
  default     = "172.25.16.0/20"
}

variable "vpc_cidr" {
  description = "CIDR for the demo VPC."
  type        = string
  default     = "10.60.0.0/16"
}

variable "availability_zone_count" {
  type    = number
  default = 2
}

variable "eks_node_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "eks_node_count" {
  type    = number
  default = 2
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_name" {
  type    = string
  default = "nimbus"
}

variable "db_master_username" {
  description = "Break-glass DB admin, distinct from Vault's root DB account -- create this BEFORE running `vault write -f database/rotate-root/...`, or Vault's rotation locks everyone else out."
  type        = string
  default     = "dbadmin"
}

# HCP Vault Dedicated tier. The HCP *portal* now calls this "Essentials
# Small", but the Terraform provider schema (checked against the provider's
# own docs while this was written) still uses the legacy enum values --
# dev | standard_small | standard_medium | standard_large | plus_small |
# plus_medium | plus_large. `standard_small` is the best-available mapping
# for "Essentials Small" (the cheapest tier with audit log support) under
# the old naming, but this was NOT confirmed against a live cluster --
# CONFIRM with `hcp vault-clusters tiers` or current provider docs before
# `terraform apply`. This is exactly the kind of thing scripts/03-verify.sh
# checks early, not the kind of thing to find out on stage.
variable "vault_tier" {
  type    = string
  default = "standard_small"
}

variable "vault_min_version" {
  description = "Minimum Vault version. auth/spiffe needs 1.21+; confirm this version is actually offered on HCP Vault Dedicated before relying on it -- see the go/no-go probe in scripts/03-verify.sh."
  type        = string
  default     = "v1.21.2"
}

variable "vault_ip_allowlist" {
  description = "CIDRs allowed to reach the cluster's public endpoint. Tighten this to your current IP before a rehearsal; the cluster is provisioned with public_endpoint=true purely so `terraform apply` can run from a laptop without a bastion -- Vault still reaches RDS over the private HVN<->VPC peering regardless of this setting."
  type        = list(string)
  default     = []
}

variable "trust_domain" {
  description = "SPIFFE trust domain used by SPIRE and matched in Vault's auth config."
  type        = string
  default     = "nimbus.demo"
}

variable "agent_namespace" {
  type    = string
  default = "agents"
}

variable "agent_service_account" {
  type    = string
  default = "ai-support-agent-secure"
}

# Decided by scripts/03-verify.sh's go/no-go probe (`vault auth enable
# spiffe`), not guessed here. Pass `-var=spiffe_auth_available=true` only
# after that probe has actually succeeded against this cluster -- see
# docs/RUNBOOK.md "The one unresolved risk".
variable "spiffe_auth_available" {
  type    = bool
  default = false
}

variable "spiffe_bundle_jwks_path" {
  description = "Path to SPIRE's static JWKS bundle, for native auth/spiffe's `bundle` argument. Produced by scripts/refresh-bundle.sh; stale after ~24h (SPIRE's ca_ttl) -- see docs/RUNBOOK.md."
  type        = string
  default     = "./spiffe-bundle.jwks"
}

variable "spiffe_bundle_pem_paths" {
  description = "SPIRE's public signing keys as individual PEM files, for the auth/jwt fallback's `jwt_validation_pubkeys` (a list of PEM strings, not a JWKS doc). Also produced by scripts/refresh-bundle.sh."
  type        = list(string)
  default     = []
}

# Vault's "Agentic IAM" feature (Agent Registry, OAuth resource server, RAR)
# is Enterprise-only, GA in Vault 2.1. Unlike spiffe_auth_available, this
# could NOT be tested at all while building this repo -- Vault Enterprise's
# own dev-mode binary refuses to start without a real license (confirmed by
# direct test: `docker run hashicorp/vault-enterprise` fails with "license
# check failed: no autoloaded license provided"), and that license is
# sales/support-gated with no self-serve issuance found. See
# docs/RUNBOOK.md's "Agentic IAM" section before setting this true --
# scripts/04-verify-agentic-iam.sh is the probe that should decide it, same
# pattern as spiffe_auth_available.
variable "agentic_iam_available" {
  type    = bool
  default = false
}
