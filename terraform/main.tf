variable "github_token" {
  description = "GitHub PAT for Argo CD"
  type        = string
  sensitive   = true
}

# 1. FIND EXISTING INFRASTRUCTURE (Instead of building it)
# Find the VPC built in the infra repo
data "aws_vpc" "pka_vpc" {
  filter {
    name   = "tag:pka-project"
    values = ["pka-mgmt"] # Matches the tag we added to pka-infra
  }
}

# Find the Private Subnets for the EKS Nodes
data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.pka_vpc.id]
  }
  filter {
    name   = "tag:pka-network-type"
    values = ["private"]
  }
}

# 2. THE EKS CLUSTER (Using discovered IDs)
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "pka-mgmt-hub"
  cluster_version = "1.35"

  # Use data source IDs here
  vpc_id     = data.aws_vpc.pka_vpc.id
  subnet_ids = data.aws_subnets.private.ids 

  cluster_endpoint_public_access = true
  enable_cluster_creator_admin_permissions = true

  access_entries = {
    sso_admin = {
      principal_arn = "arn:aws:iam::622778846520:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_AdministratorAccess_f38fc6e676a1d99c"
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  eks_managed_node_groups = {
    mgmt = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.small"]
      capacity_type  = "SPOT"
      min_size       = 2
      max_size       = 2
      desired_size   = 2
    }
  }
}

# 3. Argo CD Installation via Helm
resource "helm_release" "argocd" {
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

  # This ensures the LoadBalancer is placed in the PUBLIC subnets 
  # of your existing VPC so you can access the UI from the internet.
  set {
    name  = "server.service.annotations.service\\.beta\\.kubernetes\\.io/aws-load-balancer-scheme"
    value = "internet-facing"
  }
}

# 4. REPO CREDENTIALS
resource "kubernetes_secret" "argocd_repo_credentials" {
  depends_on = [helm_release.argocd]

  metadata {
    name      = "pka-infra-repo-creds"
    namespace = "argocd"
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type     = "git"
    url      = "https://github.com/AnuragXSharma/pka-infra.git"
    password = var.github_token
    username = "git" 
  }
}

# 5. AUTOMATION SNIPPET
resource "null_resource" "post_install" {
  depends_on = [helm_release.argocd]

  provisioner "local-exec" {
    command = <<EOT
      aws eks update-kubeconfig --region us-east-1 --name pka-mgmt-hub
      echo "Waiting for Argo CD secret..."
      sleep 30
      kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d > argocd-password.txt
    EOT
  }
}
