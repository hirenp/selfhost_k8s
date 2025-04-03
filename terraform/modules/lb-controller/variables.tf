variable "cluster_oidc_issuer_url" {
  description = "The URL of the OIDC issuer for the Kubernetes cluster"
  type        = string
  default     = "https://kubernetes.default.svc"
}

variable "region" {
  description = "The AWS region to deploy to"
  type        = string
  default     = "us-west-1"
}

variable "cluster_name" {
  description = "The name of the Kubernetes cluster"
  type        = string
  default     = "selfhost-k8s"
}