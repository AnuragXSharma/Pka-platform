variable "github_token" {
  description = "GitHub PAT for Argo CD"
  type        = string
  sensitive   = true
}
# 1. Network Infrastructure (VPC)
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "pka-mgmt-vpc"
  cidr = "10.0.0.0/16"
  azs  = ["us-east-1a", "us-east-1b"]

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = true
  single_nat_gateway = true # Massive cost saver for development
}

# 2. The EKS Cluster (The "Hub")
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.0"

  cluster_name    = "pka-mgmt-hub"
  cluster_version = "1.35"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    mgmt = {
      instance_types = ["t3.small"]
      capacity_type  = "SPOT" # Saves ~90% on compute costs
      min_size       = 2
      max_size       = 2
      desired_size   = 2
    }
  }
}

# 3. Argo CD Installation via Helm
resource "helm_release" "argocd" {
  depends_on = [module.eks] # Wait for cluster to be healthy

  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  create_namespace = true
  version          = "7.3.11"

  set {
    name  = "server.service.type"
    value = "LoadBalancer" # Generates the external URL for the UI
  }
}
# 4. PASTE THE REPO SECRET HERE
resource "kubernetes_secret" "argocd_repo_credentials" {
  # This "depends_on" is crucial. It tells Terraform: 
  # "Don't try to create the secret until the Argo CD namespace exists!"
  depends_on = [helm_release.argocd]

  metadata {
    name      = "pka-infra-repo-creds"
    namespace = "argocd"
    labels = {
      # This label tells Argo CD: "This secret is a repository credential"
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

 data = {
    type     = "git"
    url      = "https://github.com/AnuragXSharma/pka-infra.git" # Update this!
    password = var.github_token
    username = "git" 
  }
}
# 5. Automation Snippet: Fetch Password & Update Kubeconfig
resource "null_resource" "post_install" {
  depends_on = [helm_release.argocd]

  provisioner "local-exec" {
    # This command updates your local ~/.kube/config so you can run kubectl immediately
    # Then it grabs the auto-generated Argo CD password and saves it locally
    command = <<EOT
      aws eks update-kubeconfig --region us-east-1 --name pka-mgmt-hub
      echo "Waiting for Argo CD secret to be generated..."
      sleep 30
      kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d > argocd-password.txt
      echo "-----------------------------------------------------------"
      echo "SETUP COMPLETE"
      echo "Argo CD Password has been saved to: terraform/argocd-password.txt"
      echo "-----------------------------------------------------------"
    EOT
  }
}
