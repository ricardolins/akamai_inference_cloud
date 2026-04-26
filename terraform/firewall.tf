# =============================================================================
# firewall.tf — Linode Cloud Firewall restricting node access to allowed_admin_cidr
#
# SECURITY MODEL:
#   inbound_policy  = DROP  (deny everything not explicitly allowed)
#   outbound_policy = ACCEPT (nodes need internet for image pulls, Helm, etc.)
#
# Allowed inbound ports (admin IP only):
#   22    SSH (node access / debugging)
#   6443  Kubernetes API server
#   8000  vLLM OpenAI-compatible API
#   3000  Grafana
#   9090  Prometheus
#   80    Fallback router HTTP
#   8080  Fallback router alt HTTP
#   9400  DCGM Exporter metrics
#
# NodePorts used by Kubernetes (30000-32767):
#   Monitoring services (Grafana, Prometheus) are exposed as NodePort.
#   Port range 30000-32767 is opened to admin IP only.
#   vLLM uses hostPort:8000 (port 8000 rule above covers it).
# =============================================================================

locals {
  # Extract just the IP without the prefix length for display purposes
  admin_ip = var.allowed_admin_cidr
}

# ── Chicago Firewall ──────────────────────────────────────────────────────────

resource "linode_firewall" "chicago" {
  label           = "${var.project_name}-chicago-fw"
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"
  tags            = var.tags

  # Allow SSH from admin IP only
  inbound {
    label    = "allow-admin-ssh"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = [local.admin_ip]
  }

  # Allow Kubernetes API from admin IP only
  inbound {
    label    = "allow-admin-k8s-api"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "6443"
    ipv4     = [local.admin_ip]
  }

  # Allow vLLM inference API from anywhere — router (Akamai Functions) enforces allowlist
  inbound {
    label    = "allow-public-vllm"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "8000"
    ipv4     = ["0.0.0.0/0"]
  }

  # Allow Grafana from admin IP only
  inbound {
    label    = "allow-admin-grafana"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "3000"
    ipv4     = [local.admin_ip]
  }

  # Allow Prometheus from admin IP only
  inbound {
    label    = "allow-admin-prometheus"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "9090"
    ipv4     = [local.admin_ip]
  }

  # Allow router HTTP from admin IP only
  inbound {
    label    = "allow-admin-router"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "80,8080"
    ipv4     = [local.admin_ip]
  }

  # Allow DCGM metrics (admin monitoring scrapes) from admin IP only
  inbound {
    label    = "allow-admin-dcgm"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "9400"
    ipv4     = [local.admin_ip]
  }

  # Allow Kubernetes NodePorts for monitoring (Grafana, Prometheus NodePort services)
  inbound {
    label    = "allow-admin-nodeports"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "30000-32767"
    ipv4     = [local.admin_ip]
  }

  # Allow inter-node communication (Kubernetes CNI requires node-to-node traffic)
  # Linode VPC / private IPs: 192.168.0.0/16 is the private range
  inbound {
    label    = "allow-node-internal"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "1-65535"
    ipv4     = ["192.168.128.0/17"]
  }

  inbound {
    label    = "allow-node-internal-udp"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "1-65535"
    ipv4     = ["192.168.128.0/17"]
  }

  # Attach this firewall to all Chicago GPU nodes
  linodes = module.chicago.node_instance_ids
}

# ── Seattle Firewall ──────────────────────────────────────────────────────────

resource "linode_firewall" "seattle" {
  label           = "${var.project_name}-seattle-fw"
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"
  tags            = var.tags

  inbound {
    label    = "allow-admin-ssh"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = [local.admin_ip]
  }

  inbound {
    label    = "allow-admin-k8s-api"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "6443"
    ipv4     = [local.admin_ip]
  }

  inbound {
    label    = "allow-public-vllm"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "8000"
    ipv4     = ["0.0.0.0/0"]
  }

  inbound {
    label    = "allow-admin-grafana"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "3000"
    ipv4     = [local.admin_ip]
  }

  inbound {
    label    = "allow-admin-prometheus"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "9090"
    ipv4     = [local.admin_ip]
  }

  inbound {
    label    = "allow-admin-router"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "80,8080"
    ipv4     = [local.admin_ip]
  }

  inbound {
    label    = "allow-admin-dcgm"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "9400"
    ipv4     = [local.admin_ip]
  }

  inbound {
    label    = "allow-admin-nodeports"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "30000-32767"
    ipv4     = [local.admin_ip]
  }

  inbound {
    label    = "allow-node-internal"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "1-65535"
    ipv4     = ["192.168.128.0/17"]
  }

  inbound {
    label    = "allow-node-internal-udp"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "1-65535"
    ipv4     = ["192.168.128.0/17"]
  }

  linodes = module.seattle.node_instance_ids
}
