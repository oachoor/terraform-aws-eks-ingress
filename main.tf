locals {
  prefix = "ice-kube"
  tags = {
    Project     = "ice-kube"
    Environment = "dev"
    Terraform   = "yes"
  }
  cidr_subnets = cidrsubnets("10.0.0.0/16", 4, 4, 4, 4)
}

data "aws_region" "current" {}
data "aws_availability_zones" "available" {}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name            = "${local.prefix}-vpc"
  cidr            = "10.0.0.0/16"
  azs             = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets = slice(local.cidr_subnets, 0, 2)
  public_subnets  = slice(local.cidr_subnets, 2, 4)

  // Internet Gateway (IGW) allows instances with public IPs to access the internet. 
  // NAT Gateway (NGW) allows instances with no public IPs to access the internet
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  // Kuberenetes will find these subnets through the following tags
  public_subnet_tags = {
    // "kubernetes.io/cluster/${local.prefix}-cluster" = "shared"
    "kubernetes.io/role/elb" = "1"
  }

  /*private_subnet_tags = {
    "kubernetes.io/cluster/${local.prefix}-cluster" = "shared"
    "kubernetes.io/role/internal-elb"               = "1"
  }*/

  tags = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.15"

  cluster_name                   = "${local.prefix}-cluster"
  cluster_version                = "1.27"
  cluster_endpoint_public_access = true
  enable_irsa                    = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  // EKS: self-managed, managed-node or fargate
  // With a self-managed node there is a lot you are responsible for configuring. 
  // That includes installing the kubelet, container runtime, connecting to the cluster, autoscaling, networking, and more. Most EKS clusters do not need the level of customization that self-managed nodes provide.

  // Managed node groups handle the lifecycle of each worker node for you. A managed node group will come with all the prerequisite software and permissions, connect itself to the cluster, and provide an easier experience for lifecycle actions like autoscaling and updates. 
  // In most cases managed node groups will reduce the operational overhead of self managing nodes and provide a much easier experience.

  // pods per node calculator => https://docs.aws.amazon.com/eks/latest/userguide/choosing-instance-type.html 
  eks_managed_node_group_defaults = {
    use_custom_launch_template = false

    disk_size = 30
    ami_type  = "AL2_x86_64"
    instance_types = [
      "t3.medium", // ~17 pods
      "t3.small",  // ~11 pods
      "t3.nano",   // ~4 pods
    ]
  }

  eks_managed_node_groups = {
    ng01 = {
      name           = "ng01"
      min_size       = 1
      max_size       = 1
      desired_size   = 1
      instance_types = ["t3.small"]
      tags           = local.tags
    }
  }

  tags = local.tags
}

module "irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.20.0"

  role_name                              = "${local.prefix}-eks-irsa-role"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    one = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = local.tags
}

resource "kubernetes_service_account" "this" {
  metadata {
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
    labels = {
      "app.kubernetes.io/name"      = "aws-load-balancer-controller"
      "app.kubernetes.io/component" = "controller"
    }
    annotations = {
      "eks.amazonaws.com/role-arn"               = module.irsa_role.iam_role_arn
      "eks.amazonaws.com/sts-regional-endpoints" = "true"
    }
  }
}

resource "helm_release" "this" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  depends_on = [kubernetes_service_account.this]

  set {
    name  = "region"
    value = data.aws_region.current.name
  }

  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  set {
    name  = "clusterName"
    value = module.eks.cluster_name
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.create"
    value = "false"
  }
}
