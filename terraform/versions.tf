terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.79.0" # the eks module (~> 21.0) pulls in a >= 6.59.0 constraint
    }
    hcp = {
      source  = "hashicorp/hcp"
      version = "~> 0.100"
    }
    vault = {
      source  = "hashicorp/vault"
      # 5.x, not 4.x: vault_agent_registration and
      # vault_oauth_resource_server_config_profile (terraform/agentic-iam.tf)
      # don't exist before 5.x -- confirmed by dumping the provider's own
      # schema at both versions, not assumed.
      version = "~> 5.13"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Configured against the admin namespace -- see docs/RUNBOOK.md: HCP Vault
# Dedicated reserves the root namespace for itself, every provider call here
# runs inside `admin`.
provider "vault" {
  address   = hcp_vault_cluster.main.vault_public_endpoint_url
  token     = hcp_vault_cluster_admin_token.main.token
  namespace = "admin"
}
