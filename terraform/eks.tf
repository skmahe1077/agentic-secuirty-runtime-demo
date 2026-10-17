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
    coredns = {}
    # vpc-cni and kube-proxy must install *before* the node group, not after:
    # bootstrap_self_managed_addons = false (this module's default) means EKS
    # provides no default networking at all, so without before_compute the
    # module's normal addon ordering (depends_on = [module.eks_managed_node_group])
    # creates a deadlock -- nodes can never go Ready without CNI, and the addon
    # that provides CNI waits for the node group to succeed first.
    kube-proxy = { before_compute = true }
    vpc-cni    = { before_compute = true }
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

# The in-tree "gp2" StorageClass that ships with every EKS cluster is NOT
# marked as the cluster default (no storageclass.kubernetes.io/is-default-class
# annotation) despite what eks.tf's addons comment above assumes -- without
# this, any PVC that doesn't name a storageClassName explicitly (Vault's own
# two PVCs, SPIRE's spire-data PVC) sits Pending forever with "no storage
# class is set".
resource "kubernetes_annotations" "gp2_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"
  metadata {
    name = "gp2"
  }
  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "true"
  }
  force     = true
  depends_on = [module.eks]
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
