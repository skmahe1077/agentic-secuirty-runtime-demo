output "aws_region" {
  value = var.aws_region
}

output "db_master_username" {
  value = var.db_master_username
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_update_kubeconfig_command" {
  value = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "rds_endpoint" {
  value = aws_db_instance.nimbus.address
}

output "rds_master_password" {
  value     = random_password.db_master.result
  sensitive = true
}

output "vault_addr" {
  value = hcp_vault_cluster.main.vault_public_endpoint_url
}

output "vault_admin_token" {
  value     = hcp_vault_cluster_admin_token.main.token
  sensitive = true
}

output "hvn_cidr" {
  description = "Hand this to rds.tf's security group and to any other resource that needs to allow inbound from Vault."
  value       = var.hvn_cidr
}

output "spiffe_auth_in_use" {
  value = var.spiffe_auth_available ? "native auth/spiffe" : "auth/jwt fallback"
}
