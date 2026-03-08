variable "register_app_cluster" {
  description = "Set to true only after the pka-app-cluster has been created in its own repo"
  type        = bool
  default     = false
}

variable "app_cluster_name" {
  description = "The name of the target EKS cluster"
  type        = string
  default     = "pka-app-cluster"
}

variable "app_cluster_region" {
  description = "The AWS region where the app cluster resides"
  type        = string
  default     = "us-east-1"
}
