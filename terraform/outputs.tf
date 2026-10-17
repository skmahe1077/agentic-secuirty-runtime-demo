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

output "vault_k8s_namespace" {
  # Deliberately a resource attribute, not the bare var.vault_namespace --
  # scripts/lib/common.sh's tf_output needs this before Phase F's full
  # apply ever runs (vault-init.sh, vault_env), and Terraform only writes
  # an output during a `-target`ed apply if it's reachable from a targeted
  # resource. A pure-variable output has no such edge and silently never
  # gets written until a full, untargeted apply succeeds.
  value = kubernetes_namespace.vault.metadata[0].name
}

output "vault_replicas" {
  value = var.vault_replicas
}

output "vault_init_secret_name" {
  value = aws_secretsmanager_secret.vault_init.name
}

output "vault_unseal_kms_key_arn" {
  value = aws_kms_key.vault_unseal.arn
}

# What the agent pods use -- the in-cluster Service, not a public address.
# Vault deliberately has no ALB/NLB: the storefront is the only thing the
# audience needs to reach, and a publicly exposed, TLS-disabled Vault on a
# conference network is a needless risk.
output "vault_internal_addr" {
  value = "http://vault.${var.vault_namespace}.svc.cluster.local:8200"
}

output "vault_portforward_command" {
  value = "kubectl -n ${var.vault_namespace} port-forward svc/vault 8200:8200"
}
