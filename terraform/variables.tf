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
  description = "RDS master username -- this is the SAME account `vault_database_secret_backend_connection.nimbus` uses, so `vault write -f database/rotate-root/...` rotates it out from under anyone else using it. There is no separate break-glass admin; after rotation only Vault knows this password. app/db/04_storefront_role.sql's nimbus_storefront is the account everything else (storefront, scripts/02-configure-vault.sh's pre-flight) uses instead."
  type        = string
  default     = "dbadmin"
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

variable "spiffe_bundle_jwks_path" {
  description = "Path to SPIRE's static JWKS bundle, for auth/spiffe's `bundle` argument. Produced by scripts/refresh-bundle.sh; stale after ~24h (SPIRE's ca_ttl) -- see docs/RUNBOOK.md."
  type        = string
  default     = "./spiffe-bundle.jwks"
}

variable "spiffe_bundle_pem_paths" {
  description = "SPIRE's public signing keys as individual PEM files, for agentic-iam.tf's OAuth resource server profile. Also produced by scripts/refresh-bundle.sh. Leave the default []; locals.tf reads terraform/spiffe-bundle-keys/*.pem automatically -- only set this to override that."
  type        = list(string)
  default     = []
}

# ---- self-managed Vault Enterprise on EKS ---------------------------------

variable "vault_namespace" {
  description = "Kubernetes namespace for the Vault StatefulSet. NOT a Vault namespace -- with self-managed Enterprise the Vault root namespace is ours, and VAULT_NAMESPACE is never set anywhere in this repo."
  type        = string
  default     = "vault"
}

variable "vault_chart_version" {
  description = "hashicorp/vault Helm chart version. CONFIRM against `helm search repo hashicorp/vault --versions` before the first apply."
  type        = string
  default     = "0.32.0"
}

variable "vault_image_tag" {
  description = "hashicorp/vault-enterprise image tag. CONFIRM the exact available GA tag on Docker Hub before pinning -- do not use `.hsm` / `.hsm.fips1403` variants or `latest`."
  type        = string
  default     = "2.2.0-ent"
}

variable "vault_replicas" {
  description = "Vault pod count. 1 for this demo -- see vault-cluster.tf's header comment on why 1, not 2 or 3. Left as a variable so scaling up later is a one-line change."
  type        = number
  default     = 1
}

variable "vault_data_storage_size" {
  type    = string
  default = "10Gi"
}

variable "vault_audit_storage_size" {
  type    = string
  default = "10Gi"
}

variable "vault_license_secret_name" {
  description = "AWS Secrets Manager secret holding the raw Vault Enterprise license string. Created out of band -- see README prerequisites. Terraform only READS it, so `destroy` never deletes your license."
  type        = string
  default     = "agentic-sec-demo/vault-license"
}

# ---- public access ---------------------------------------------------------

variable "lbc_chart_version" {
  description = "aws-load-balancer-controller Helm chart version. CONFIRM against `helm search repo eks/aws-load-balancer-controller --versions`."
  type        = string
  default     = "1.13.0"
}

variable "alb_inbound_cidrs" {
  description = "CIDRs allowed to reach the public storefront ALB. The storefront exposes unauthenticated /api/admin/reset and /api/admin/revoke endpoints, so leaving this at 0.0.0.0/0 means anyone who sees the URL can wipe the demo or kill the live Vault lease mid-talk. Narrow this to the presenter's current IP (`curl -s ifconfig.me`) right before the talk -- see docs/RUNBOOK.md."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}
