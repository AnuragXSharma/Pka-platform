# pka-platform/terraform/main.tf

# 1. Fetch available AZs for the region
data "aws_availability_zones" "available" {}

# 2. Build the Networking (VPC)
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "pka-mgmt-vpc"
  cidr = "10.0.0.0/16"

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true # Saves cost for a Management Cluster
}

# 3. Create the EKS Cluster
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = "pka-mgmt-hub"
  cluster_version = "1.28"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    mgmt = {
      min_size     = 2
      max_size     = 3
      instance_types = ["t3.medium"] # Reliable for Argo CD workloads
    }
  }
}

# 4. Install Argo CD via Helm
resource "helm_release" "argocd" {
  # This is critical: Do not attempt install until the cluster is ready
  depends_on = [module.eks]

  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "7.3.11" 

  set {
    name  = "server.service.type"
    value = "LoadBalancer"
  }
}
