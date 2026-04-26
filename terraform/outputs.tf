# =============================================================================
# outputs.tf — Key values printed after terraform apply
# Sensitive values (kubeconfigs) require: terraform output -raw <name>
# =============================================================================

# ── Chicago ───────────────────────────────────────────────────────────────────

output "chicago_cluster_id" {
  description = "Chicago LKE cluster ID"
  value       = module.chicago.cluster_id
}

output "chicago_cluster_name" {
  description = "Chicago LKE cluster label"
  value       = module.chicago.cluster_name
}

output "chicago_region" {
  description = "Chicago region"
  value       = module.chicago.region
}

output "chicago_api_endpoints" {
  description = "Chicago Kubernetes API endpoints"
  value       = module.chicago.api_endpoints
}

output "chicago_node_instance_ids" {
  description = "Chicago GPU node Linode IDs (for firewall/debugging)"
  value       = module.chicago.node_instance_ids
}

# ── Seattle ───────────────────────────────────────────────────────────────────

output "seattle_cluster_id" {
  description = "Seattle LKE cluster ID"
  value       = module.seattle.cluster_id
}

output "seattle_cluster_name" {
  description = "Seattle LKE cluster label"
  value       = module.seattle.cluster_name
}

output "seattle_region" {
  description = "Seattle region"
  value       = module.seattle.region
}

output "seattle_api_endpoints" {
  description = "Seattle Kubernetes API endpoints"
  value       = module.seattle.api_endpoints
}

output "seattle_node_instance_ids" {
  description = "Seattle GPU node Linode IDs"
  value       = module.seattle.node_instance_ids
}

# ── Kubeconfig Instructions ───────────────────────────────────────────────────

output "kubeconfig_instructions" {
  description = "Commands to export kubeconfigs and configure kubectl contexts"
  value       = <<-EOT

  ════════════════════════════════════════════════════════════
   KUBECONFIG — Run these commands after terraform apply
  ════════════════════════════════════════════════════════════

  # Kubeconfigs are saved automatically to:
  #   ../kubeconfig-chicago.yaml
  #   ../kubeconfig-seattle.yaml

  # Add both to KUBECONFIG:
  export KUBECONFIG=./kubeconfig-chicago.yaml:./kubeconfig-seattle.yaml

  # Rename contexts for convenience:
  kubectl config rename-context \
    $(kubectl config current-context --kubeconfig=./kubeconfig-chicago.yaml) \
    chicago --kubeconfig=./kubeconfig-chicago.yaml

  kubectl config rename-context \
    $(kubectl config current-context --kubeconfig=./kubeconfig-seattle.yaml) \
    seattle --kubeconfig=./kubeconfig-seattle.yaml

  # Verify:
  kubectl get nodes --context=chicago
  kubectl get nodes --context=seattle

  ════════════════════════════════════════════════════════════

  EOT
}

output "discover_ips_commands" {
  description = "Commands to find LoadBalancer IPs after workload deployment"
  value       = <<-EOT

  ════════════════════════════════════════════════════════════
   DISCOVER SERVICE IPs — Run after make deploy-all
  ════════════════════════════════════════════════════════════

  # All LoadBalancer IPs (both regions):
  kubectl get svc -A --context=chicago
  kubectl get svc -A --context=seattle

  # Specific services:
  kubectl get svc vllm       -n inference   --context=chicago
  kubectl get svc grafana    -n monitoring  --context=chicago
  kubectl get svc prometheus -n monitoring  --context=chicago

  # Describe for more detail:
  kubectl describe svc vllm -n inference --context=chicago

  # Node IPs:
  kubectl get nodes -o wide --context=chicago
  kubectl get nodes -o wide --context=seattle

  # Access pattern (no DNS):
  #   vLLM:       http://<LB-IP>:8000
  #   Grafana:    http://<LB-IP>:3000
  #   Prometheus: http://<LB-IP>:9090

  ════════════════════════════════════════════════════════════

  EOT
}

output "security_summary" {
  description = "Security configuration summary"
  value       = <<-EOT

  ════════════════════════════════════════════════════════════
   SECURITY SUMMARY
  ════════════════════════════════════════════════════════════

  allowed_admin_cidr : ${var.allowed_admin_cidr}
  Chicago firewall   : ${var.project_name}-chicago-fw (DROP all, allow admin)
  Seattle firewall   : ${var.project_name}-seattle-fw (DROP all, allow admin)

  Kubernetes Services: All LoadBalancers use loadBalancerSourceRanges
  Kubernetes API     : Public (LKE Normal limitation) — see docs/LIMITATIONS.md

  ════════════════════════════════════════════════════════════

  EOT
}
