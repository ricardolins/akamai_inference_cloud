# =============================================================================
# variables.tf — All configurable inputs for the inference infrastructure.
# Required: allowed_admin_cidr must be set in terraform.tfvars
# =============================================================================

# ── Security (REQUIRED) ───────────────────────────────────────────────────────

variable "allowed_admin_cidr" {
  description = <<-EOT
    Your public IP in CIDR /32 notation. ALL services will be restricted to
    this IP only. No 0.0.0.0/0 exposure anywhere.
    Get your IP: curl -s https://api.ipify.org
    Example: "200.100.50.25/32"
  EOT
  type        = string

  validation {
    condition     = can(regex("^(\\d{1,3}\\.){3}\\d{1,3}/32$", var.allowed_admin_cidr))
    error_message = "allowed_admin_cidr must be a /32 IPv4 CIDR. Example: 200.100.50.25/32"
  }
}

# ── Regions ───────────────────────────────────────────────────────────────────

variable "chicago_region" {
  description = "Akamai/Linode region ID for Chicago"
  type        = string
  default     = "us-ord"
}

variable "seattle_region" {
  description = "Akamai/Linode region ID for Seattle"
  type        = string
  default     = "us-sea"
}

# ── GPU Instance Type ─────────────────────────────────────────────────────────

variable "gpu_node_type" {
  description = <<-EOT
    Linode instance plan for GPU nodes.
    Verify available GPU plans with:
      linode-cli linodes types --json | jq '.[] | select(.class=="gpu") | .id'
    RTX 4000 Ada Small plan is typically: g1-gpu-rtx4000ada-1
  EOT
  type        = string
  default     = "g1-gpu-rtx4000ada-1"
}

variable "gpu_nodes_per_cluster" {
  description = "Number of GPU nodes per cluster. Keep at 1 for cost control."
  type        = number
  default     = 1
}

# ── Kubernetes ────────────────────────────────────────────────────────────────

variable "k8s_version" {
  description = <<-EOT
    Kubernetes version for LKE clusters.
    List available versions:
      linode-cli lke versions-list
  EOT
  type    = string
  default = "1.31"
}

# ── Project ───────────────────────────────────────────────────────────────────

variable "project_name" {
  description = "Prefix applied to all resource names for identification"
  type        = string
  default     = "akai-inference"
}

variable "tags" {
  description = "Tags applied to all Linode resources"
  type        = list(string)
  default     = ["akai-inference", "gpu", "production"]
}
