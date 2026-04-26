# =============================================================================
# modules/lke-cluster/main.tf — Creates one LKE cluster with a GPU node pool.
# This is LKE Normal (not Enterprise) — Kubernetes API is publicly accessible.
# See docs/SECURITY_IP_ALLOWLIST.md for mitigation strategy.
# =============================================================================

terraform {
  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
    }
  }
}

resource "linode_lke_cluster" "this" {
  label       = var.cluster_name
  region      = var.region
  k8s_version = var.k8s_version
  tags        = var.tags

  # GPU node pool — single node to minimize cost while validating GPU inference
  pool {
    type  = var.gpu_node_type
    count = var.gpu_node_count

    # Autoscaler: fixed at gpu_node_count — GPU is expensive, no auto-scale
    autoscaler {
      min = var.gpu_node_count
      max = var.gpu_node_count
    }
  }

  # LKE Normal does not support private Kubernetes API endpoints.
  # The API server is publicly reachable (port 6443).
  # Mitigation: strong RBAC, protect kubeconfig, use Cloud Firewall on nodes.
  # See docs/LIMITATIONS.md for details.
}
