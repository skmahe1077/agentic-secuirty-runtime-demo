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

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}
