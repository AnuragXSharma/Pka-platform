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
    values = ["pka-mgmt"]
  }
}

# Find the private subnets for the EKS nodes
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

# Fetch full subnet details so CIDR blocks can be used
data "aws_subnet" "app_private_details" {
  for_each = toset(data.aws_subnets.private.ids)
  id       = each.value
}

# 2. THE EKS CLUSTER (Using discovered IDs)
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "pka-mgmt-hub"
  cluster_version = "1.35"

  vpc_id     = data.aws_vpc.pka_vpc.id
  subnet_ids = data.aws_subnets.private.ids

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  # Disable CMK creation
  create_kms_key = false

  # Disable secrets encryption entirely
  cluster_encryption_config = {}

  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }

    egress_to_app_subnets = {
      description = "Allow ArgoCD nodes to reach App Private Subnets"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "egress"

      cidr_blocks = [
        for s in data.aws_subnet.app_private_details : s.cidr_block
      ]
    }
  }

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

# 5. Connect to pka-app-cluster
resource "kubernetes_secret" "app_cluster_registration" {
  depends_on = [helm_release.argocd]

  metadata {
    name      = "pka-app-cluster-secret"
    namespace = "argocd"

    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
    }
  }

  data = {
    name   = "pka-app-cluster"
    server = "https://241CB3294FAD0F7433CF401417433B75.gr7.us-east-1.eks.amazonaws.com"

    config = jsonencode({
      awsAuthConfig = {
        clusterName = "pka-app-cluster"
        roleARN     = "arn:aws:iam::622778846520:role/GitHubAction-EKS-Deployer"
      }

      tlsClientConfig = {
        insecure = false
        caData   = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSURCVENDQWUyZ0F3SUJBZ0lJWEVSY2k5QjIzSjB3RFFZSktvWklodmNOQVFFTEJRQXdGVEVUTUJFR0ExVUUKQXhNS2EzVmlaWEp1WlhSbGN6QWVGdzB5TmpBek1EY3dNalF4TkRoYUZ3MHpOakF6TURRd01qUTJORGhhTUJVeApFekFSQmdOVkJBTVRDbXQxWW1WeWJtVjBaWE13Z2dFaU1BMEdDU3FHU0liM0RRRUJBUVVBQTRJQkR3QXdnZ0VLCkFvSUJBUUMxUlNZVnlnZEM2UEgzZXIvSjdCUEFnN3RVZURkWlY5Z3d1RXlNL0lpN3A0WUVremFzQWNMcTJ6TlcKeG5WNHU3T1BLUVE3aDV6TkdJcnlZN1VNMjFPTytmM2hkWTNUYkJqZ1NEV1Z0UkhvMWpYdVlJajF6ZjVDTkU5LwptMHREL3FZTzBYMlR0WEFtK3hsZnBNRnZhZmRJcEp2Y1JrZmsyRXZUdWNTdFd2eDdTT3VQQUZqTFN1VllONU91Cm5mYWl1NHorMUt2T3haR3o0dU01U0JBY3NOdGFDSGF3aEZxOXNjcDNsbEdXUmFqazVkUUZTN2dHdmVsU2czYy8Kb0dKSzI1SW1nR0RyUjhhNkNoZDBvMXYrZTh6elg2TUp1TS9IOHQ3T2djaVBkemQrSDVCbFR4M1VGOGNrWE9OMQp5V2pKUjFpQVpGWnBhelN1bTV5SThBQlp0SWlqQWdNQkFBR2pXVEJYTUE0R0ExVWREd0VCL3dRRUF3SUNwREFQCkJnTlZIUk1CQWY4RUJUQURBUUgvTUIwR0ExVWREZ1FXQkJUQ0wvaDUwdXVETlZnWTZEUlVBMXFUSm82cVhEQVYKQmdOVkhSRUVEakFNZ2dwcmRXSmxjbTVsZEdWek1BMEdDU3FHU0liM0RRRUJDd1VBQTRJQkFRQ0hkWWVVOG9RYwpvL1EzbkxvSGVNVmdEdk9QVlZ0NE95REtFMitnOE9hOG1nYUVPekQvKzYvNkFFNlpxUDFkKzBDaUlnV2p0bFJlCjhuUExJQ3FicXRwNHdtR1ptR0NMZmlLOE4vWkoxZzZjdzBUenBhZS9qdlRXbzNtMFlFVEdGL2JvUFJkUmNrWW8KSW1mQ3hZckN3NjI0SEVtSElTZ2VhL0FTd1g1MlRNbVhOVENObFRUUXNTZnE0SXh0d1VPWm1kRk5sQjNkNmNzRgp5WW9kUktPeVdnQUVYbFZhaHNrY0N2V0E4OTIvSTMyNUVodjRwMWg2OGd3cFhrODVCZXRPWldid0Q0cmJQRUlYClFRdG1iUDVWUUJKeGFGdE4zT0JnSkJEeDNKYXMrY0c5QkNiZjJ1bTBwcElxU1FNdVRtZ1dJOTdFQ2R5VVdqZ0sKZGZ1OVZ3ZDBndGppCi0tLS0tRU5EIENFUlRJRklDQVRFLS0tLS0K"
      }
    })
  }
}

# 6. AUTOMATION SNIPPET
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
