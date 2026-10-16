module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "${var.name}-eks"
  kubernetes_version = "1.31"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  # Public API endpoint for simplicity (`kubectl` from a laptop without a
  # bastion). Fine for a short-lived rehearsal cluster; lock this to
  # endpoint_private_access-only if this ever stops being torn down daily.
  endpoint_public_access = true

  enable_cluster_creator_admin_permissions = true

  # aws-ebs-csi-driver is mandatory, not optional: Vault's two PVCs
  # (dataStorage + auditStorage in vault-cluster.tf) use the default gp2
  # StorageClass, which is CSI-migrated since Kubernetes 1.23 -- without
  # this addon both PVCs stay Pending forever and the Vault StatefulSet
  # never starts. coredns/kube-proxy/vpc-cni are listed explicitly so
  # setting `addons` at all doesn't silently displace EKS's own defaults.
  addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = {}
    aws-ebs-csi-driver = {
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  eks_managed_node_groups = {
    demo = {
      instance_types = [var.eks_node_instance_type]
      min_size       = var.eks_node_count
      max_size       = var.eks_node_count
      desired_size   = var.eks_node_count
    }
  }

  tags = {
    Project = var.name
  }
}

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = { Project = var.name }
}
