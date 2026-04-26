# =============================================================================
# modules/lke-cluster/outputs.tf — Exposes cluster identifiers and access info
# =============================================================================

output "cluster_id" {
  description = "LKE cluster ID"
  value       = linode_lke_cluster.this.id
}

output "cluster_name" {
  description = "LKE cluster label"
  value       = linode_lke_cluster.this.label
}

output "region" {
  description = "Akamai/Linode region"
  value       = linode_lke_cluster.this.region
}

output "k8s_version" {
  description = "Kubernetes version deployed"
  value       = linode_lke_cluster.this.k8s_version
}

output "api_endpoints" {
  description = "Kubernetes API server endpoints"
  value       = linode_lke_cluster.this.api_endpoints
}

# kubeconfig is base64-encoded YAML. Mark sensitive to prevent accidental output.
output "kubeconfig_b64" {
  description = "Base64-encoded kubeconfig. Decode with: terraform output -raw kubeconfig_b64 | base64 -d"
  value       = linode_lke_cluster.this.kubeconfig
  sensitive   = true
}

# Linode instance IDs of the GPU nodes — used to attach the Cloud Firewall
output "node_instance_ids" {
  description = "Linode instance IDs of nodes in the GPU pool"
  value       = [for node in tolist(linode_lke_cluster.this.pool[0].nodes) : node.instance_id]
}
