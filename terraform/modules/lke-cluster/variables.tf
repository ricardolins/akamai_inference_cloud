# =============================================================================
# modules/lke-cluster/variables.tf — Inputs for the LKE cluster module
# =============================================================================

variable "cluster_name" {
  description = "Human-readable name for the LKE cluster"
  type        = string
}

variable "region" {
  description = "Akamai/Linode region ID (e.g. us-ord, us-sea)"
  type        = string
}

variable "k8s_version" {
  description = "Kubernetes version string (e.g. 1.31)"
  type        = string
}

variable "gpu_node_type" {
  description = "Linode plan ID for GPU nodes (e.g. g1-gpu-rtx4000ada-1)"
  type        = string
}

variable "gpu_node_count" {
  description = "Number of GPU nodes in the pool"
  type        = number
  default     = 1
}

variable "tags" {
  description = "Resource tags"
  type        = list(string)
  default     = []
}
