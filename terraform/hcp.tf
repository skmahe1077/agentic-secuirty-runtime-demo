# HCP Vault Dedicated + the peering that lets it reach RDS.
#
# NOT YET APPLIED IN THIS REPO -- both the AWS and HCP CLI credentials were
# expired when this was written (see docs/RUNBOOK.md Phase 1, step 1). This
# file follows the documented resource schemas as closely as research could
# confirm, but the peering wiring in particular (hcp_aws_network_peering +
# hcp_hvn_route + the AWS-side accepter/route) has NOT been run against a
# real cluster. Run `terraform plan` immediately after re-authenticating and
# before relying on this for a rehearsal.
data "aws_caller_identity" "current" {}

resource "hcp_hvn" "main" {
  hvn_id         = "${var.name}-hvn"
  cloud_provider = "aws"
  region         = var.hvn_region
  cidr_block     = var.hvn_cidr
}

resource "hcp_aws_network_peering" "main" {
  hvn_id          = hcp_hvn.main.hvn_id
  peering_id      = "${var.name}-peering"
  peer_vpc_id     = module.vpc.vpc_id
  peer_account_id = data.aws_caller_identity.current.account_id
  peer_vpc_region = var.aws_region
}

# HCP initiates the peering; AWS has to accept it on this side.
resource "aws_vpc_peering_connection_accepter" "main" {
  vpc_peering_connection_id = hcp_aws_network_peering.main.provider_peering_id
  auto_accept               = true

  tags = { Project = var.name }
}

resource "hcp_hvn_route" "to_vpc" {
  hvn_link         = hcp_hvn.main.self_link
  hvn_route_id     = "${var.name}-hvn-to-vpc"
  destination_cidr = var.vpc_cidr
  target_link      = hcp_aws_network_peering.main.self_link
}

# Private subnets need the return route so Vault's responses (and the RDS
# connection it initiates) actually route back over the peering.
resource "aws_route" "to_hvn" {
  for_each = toset(module.vpc.private_route_table_ids)

  route_table_id            = each.value
  destination_cidr_block    = var.hvn_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.main.id
}

resource "hcp_vault_cluster" "main" {
  cluster_id = "${var.name}-vault"
  hvn_id     = hcp_hvn.main.hvn_id

  tier              = var.vault_tier # see variables.tf -- confirm this enum value before applying
  min_vault_version = var.vault_min_version

  public_endpoint = true # see variables.tf: simplifies `terraform apply`/`vault` CLI from a laptop

  # var.vault_ip_allowlist is defined but NOT wired into an `ip_allowlist`
  # block here -- the nested block schema for it wasn't confirmed against
  # live docs while writing this (see the warning at the top of this file).
  # Until confirmed, tighten access via `hcp vault-clusters update
  # --ip-allowlist=<your-ip>/32` right before a rehearsal instead.
}

resource "hcp_vault_cluster_admin_token" "main" {
  cluster_id = hcp_vault_cluster.main.cluster_id
}
