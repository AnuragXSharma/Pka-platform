# 1. The URL for the UI (With a safety check)
output "argocd_loadbalancer_url" {
  description = "The URL to access the Argo CD UI"
  # Use try() because the hostname might be empty for the first 60 seconds 
  # while AWS provisions the ELB.
  value = try(
    "http://${data.kubernetes_service.argocd_server.status[0].load_balancer[0].ingress[0].hostname}",
    "Pending... (Wait 1-2 minutes for AWS DNS)"
  )
}

# 2. The Password Command
output "argocd_initial_admin_password_command" {
  description = "Run this command to get the initial admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
}

# 3. Reference to the EKS Cluster Name (Useful for your local kubeconfig)
output "eks_cluster_name" {
  value = module.eks.cluster_name
}

# --- Data source to "read" the service created by Helm ---
data "kubernetes_service" "argocd_server" {
  metadata {
    name      = "argocd-server"
    namespace = "argocd" # Hardcoded to match your helm_release namespace
  }

  # This is the most important line: don't look for the service until Helm is DONE
  depends_on = [helm_release.argocd]
}
