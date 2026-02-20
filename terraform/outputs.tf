# pka-platform/outputs.tf

output "argocd_loadbalancer_url" {
  description = "The URL to access the Argo CD UI"
  value       = "http://${data.kubernetes_service.argocd_server.status[0].load_balancer[0].ingress[0].hostname}"
}

output "argocd_initial_admin_password_command" {
  description = "Run this command to get the initial admin password"
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
}

# Data source needed to fetch the LoadBalancer URL after Helm installs it
data "kubernetes_service" "argocd_server" {
  metadata {
    name      = "argocd-server"
    namespace = helm_release.argocd.namespace
  }
  depends_on = [helm_release.argocd]
}
