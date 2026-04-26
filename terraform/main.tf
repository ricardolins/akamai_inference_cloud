# =============================================================================
# main.tf — Creates two LKE clusters: Chicago (us-ord) and Seattle (us-sea)
# Each cluster gets one GPU RTX 4000 Ada node.
# Access is restricted to allowed_admin_cidr on all exposed ports.
# =============================================================================

# ── Chicago Cluster ───────────────────────────────────────────────────────────

module "chicago" {
  source = "./modules/lke-cluster"

  cluster_name   = "${var.project_name}-chicago"
  region         = var.chicago_region
  k8s_version    = var.k8s_version
  gpu_node_type  = var.gpu_node_type
  gpu_node_count = var.gpu_nodes_per_cluster
  tags           = concat(var.tags, ["region-chicago", "us-ord"])
}

# ── Seattle Cluster ───────────────────────────────────────────────────────────

module "seattle" {
  source = "./modules/lke-cluster"

  cluster_name   = "${var.project_name}-seattle"
  region         = var.seattle_region
  k8s_version    = var.k8s_version
  gpu_node_type  = var.gpu_node_type
  gpu_node_count = var.gpu_nodes_per_cluster
  tags           = concat(var.tags, ["region-seattle", "us-sea"])
}

# ── Kubeconfig Files ──────────────────────────────────────────────────────────
# Written locally so scripts can reference them. Both are .gitignored.

resource "local_sensitive_file" "kubeconfig_chicago" {
  content         = base64decode(module.chicago.kubeconfig_b64)
  filename        = "${path.root}/../kubeconfig-chicago.yaml"
  file_permission = "0600"
}

resource "local_sensitive_file" "kubeconfig_seattle" {
  content         = base64decode(module.seattle.kubeconfig_b64)
  filename        = "${path.root}/../kubeconfig-seattle.yaml"
  file_permission = "0600"
}
