# Self-managed Vault Enterprise on EKS, replacing HCP Vault Dedicated.
# Vault now runs inside this stack's own VPC, so there is no HVN<->VPC
# peering to build -- see rds.tf for the resulting (simpler) security group.
#
# 1 replica, not 3: this is a conference-talk demo torn down and
# re-provisioned daily, not production HA. Raft is still the storage
# backend (it is vault-helm's modern default and keeps the config
# identical if this is ever scaled up), but quorum arithmetic only matters
# above 1 node -- 2 replicas would tolerate zero failures same as 1, while
# costing twice as much and adding a split-brain failure mode. At 1
# replica there is also no hard pod anti-affinity problem to work around,
# so the EKS node group stays at its original size (see variables.tf).
data "aws_caller_identity" "current" {}

# ---- auto-unseal key ------------------------------------------------------
# Raft has no auto-unseal of its own: a restarted pod comes back sealed
# and stays down until someone supplies recovery keys by hand. This KMS
# key is what makes a pod restart mid-rehearsal a non-event.
resource "aws_kms_key" "vault_unseal" {
  description             = "${var.name} Vault auto-unseal"
  deletion_window_in_days = 7 # AWS minimum; the key keeps billing ~$1/mo until this elapses after destroy
  enable_key_rotation     = false
  tags                    = { Project = var.name }
}

resource "aws_kms_alias" "vault_unseal" {
  name          = "alias/${var.name}-vault-unseal"
  target_key_id = aws_kms_key.vault_unseal.key_id
}

resource "aws_iam_policy" "vault_unseal" {
  name = "${var.name}-vault-unseal"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
      Resource = aws_kms_key.vault_unseal.arn
    }]
  })
}

# IRSA via the EKS module's own OIDC provider (enable_irsa defaults true
# on v21, exposed as module.eks.oidc_provider_arn) -- no extra addon or
# association resource needed.
#
# UNVERIFIED: confirm this module path/version/argument names against the
# registry before the first apply (`terraform init` will fail loudly and
# immediately if wrong, so this is a cheap check, not a silent risk).
module "vault_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.name}-vault-unseal"
  role_policy_arns = {
    unseal = aws_iam_policy.vault_unseal.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${var.vault_namespace}:vault"]
    }
  }

  tags = { Project = var.name }
}

# ---- Enterprise license ---------------------------------------------------
# Created out of band, never by this repo or its state:
#   aws secretsmanager create-secret --name agentic-sec-demo/vault-license \
#     --secret-string "$(cat vault.hclic)"
# Terraform only READS it, so `scripts/destroy.sh` never deletes the license.
data "aws_secretsmanager_secret_version" "vault_license" {
  secret_id = var.vault_license_secret_name
}

resource "kubernetes_namespace" "vault" {
  metadata {
    name = var.vault_namespace
  }
}

resource "kubernetes_secret" "vault_license" {
  metadata {
    name      = "vault-ent-license"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
  # Key name "license" matches vault-helm's server.enterpriseLicense.secretKey default.
  data = {
    license = data.aws_secretsmanager_secret_version.vault_license.secret_string
  }
}

# ---- where `vault operator init`'s output goes ---------------------------
# Not a Terraform resource's attribute: the root token + recovery keys are
# the output of an imperative action (scripts/vault-init.sh), the same
# reason `database/rotate-root` lives in scripts/02-configure-vault.sh
# rather than in a vault_database_secret_backend_connection lifecycle.
resource "aws_secretsmanager_secret" "vault_init" {
  name                    = "${var.name}/vault-init"
  description             = "root token + KMS recovery keys from `vault operator init` -- written by scripts/vault-init.sh, not by Terraform"
  recovery_window_in_days = 0 # force-delete, so re-provisioning tomorrow doesn't hit "scheduled for deletion"
  tags                    = { Project = var.name }
}

# ---- the cluster -----------------------------------------------------------
resource "helm_release" "vault" {
  name       = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = var.vault_chart_version
  namespace  = kubernetes_namespace.vault.metadata[0].name

  # wait = false is required, not optional: vault-helm's default
  # readinessProbe execs `vault status`, which exits non-zero while the
  # node is uninitialized or sealed. The pod CANNOT become Ready until
  # scripts/vault-init.sh has run, so `helm install --wait` would block
  # until timeout and roll back the release.
  wait          = false
  wait_for_jobs = false
  timeout       = 600

  depends_on = [kubernetes_secret.vault_license, module.eks]

  values = [yamlencode({
    global = {
      enabled = true
      # No in-cluster TLS. Deliberate, demo-only: the SVID and the Vault
      # token travel in cleartext between pods, inside the VPC. Documented
      # in docs/RUNBOOK.md as "what you would not do in production."
      tlsDisable = true
    }

    # Not used: this demo's point is the agent authenticating with its own
    # SPIFFE identity, not a sidecar fetching secrets on its behalf.
    injector = { enabled = false }

    server = {
      image = {
        repository = "hashicorp/vault-enterprise"
        tag        = var.vault_image_tag
      }

      enterpriseLicense = {
        secretName = kubernetes_secret.vault_license.metadata[0].name
        secretKey  = "license"
      }

      serviceAccount = {
        create = true
        name   = "vault"
        annotations = {
          "eks.amazonaws.com/role-arn" = module.vault_irsa.iam_role_arn
        }
      }

      dataStorage = { enabled = true, size = var.vault_data_storage_size, storageClass = "gp2" }
      # Required, not optional: the file audit device in vault-config.tf
      # must be writable, or Vault treats the unwritable device as a hard
      # request failure.
      auditStorage = { enabled = true, size = var.vault_audit_storage_size, storageClass = "gp2" }

      resources = {
        requests = { cpu = "250m", memory = "256Mi" }
        limits   = { cpu = "1", memory = "1Gi" }
      }

      ha = {
        enabled  = true
        replicas = var.vault_replicas
        raft = {
          enabled   = true
          setNodeId = true
          config    = <<-HCL
            ui = true

            listener "tcp" {
              tls_disable     = 1
              address         = "[::]:8200"
              cluster_address = "[::]:8201"
            }

            storage "raft" {
              path = "/vault/data"
            }

            seal "awskms" {
              region     = "${var.aws_region}"
              kms_key_id = "${aws_kms_key.vault_unseal.key_id}"
            }

            service_registration "kubernetes" {}
          HCL
        }
      }
    }

    ui = { enabled = true }
  })]
}
