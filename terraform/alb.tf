# AWS Load Balancer Controller, so k8s_manifests/storefront/ingress.yaml can
# provision a public ALB. The storefront is now the demo itself -- a live
# retail website the conference audience watches -- not a port-forwarded
# presenter-only view.
#
# No vpc.tf change needed: public_subnet_tags already carries
# "kubernetes.io/role/elb" for ALB subnet auto-discovery.

module "lbc_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name                              = "${var.name}-lbc"
  attach_load_balancer_controller_policy = true # ships HashiCorp's/AWS's own ~200-line policy -- do not vendor the JSON

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = { Project = var.name }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.lbc_chart_version
  namespace  = "kube-system"

  # Unlike helm_release.vault, waiting here IS correct: the controller runs
  # a validating/mutating webhook for Ingress objects, so it must be Ready
  # before k8s_manifests/storefront/ingress.yaml is applied.
  wait    = true
  timeout = 600

  values = [yamlencode({
    clusterName = module.eks.cluster_name
    region      = var.aws_region
    vpcId       = module.vpc.vpc_id
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
      annotations = {
        "eks.amazonaws.com/role-arn" = module.lbc_irsa.iam_role_arn
      }
    }
  })]

  depends_on = [module.eks]
}
