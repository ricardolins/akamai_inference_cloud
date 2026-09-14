# Akamai Inference Cloud — Multi-Region AI Inference

Production-grade, multi-region AI inference environment on Akamai Cloud (Linode) using:

| Component | Role |
|---|---|
| LKE (Linode Kubernetes Engine) | Kubernetes clusters — Normal tier |
| GPU RTX 4000 Ada — Chicago + Seattle | Hardware acceleration |
| vLLM | OpenAI-compatible inference engine |
| NVIDIA GPU Operator + DCGM Exporter | GPU lifecycle + metrics |
| Prometheus + Grafana | Observability |
| Fermyon Spin + Node.js Fallback Router | Multi-region routing |
| k6 | Performance + failover testing |
| Linode Cloud Firewall | IP-restricted access |
| Ray Serve (KubeRay) | Multi-model serving demo — toggles onto Chicago's GPU, see [docs/RAY_SERVE.md](docs/RAY_SERVE.md) |

## Security First

**Zero 0.0.0.0/0 exposure by default.**  
Admin-facing services (Grafana, Prometheus, Router, Kubernetes API, SSH) are restricted to `allowed_admin_cidr`. vLLM additionally requires an `--api-key` Bearer token, which lets it also be called by edge platforms with no fixed IP (e.g. a Zuplo AI Gateway) without opening the network layer to everyone — see [docs/SECURITY_IP_ALLOWLIST.md](docs/SECURITY_IP_ALLOWLIST.md).

```hcl
allowed_admin_cidr = "YOUR_PUBLIC_IP/32"
```

## Architecture

```
Client (your IP only)
  ↓
Fermyon Router (or Node.js fallback)
  ↓
  ├── Chicago (us-ord)
  │     ├── LKE cluster — 1 GPU node
  │     ├── GPU RTX 4000 Ada
  │     ├── NVIDIA GPU Operator + DCGM
  │     ├── vLLM  →  :8000  (1 replica, --api-key protected)
  │     ├── Prometheus  →  :9090
  │     └── Grafana  →  :3000
  └── Seattle (us-sea)
        ├── LKE cluster — 2 GPU nodes
        ├── GPU RTX 4000 Ada
        ├── NVIDIA GPU Operator + DCGM
        ├── vLLM  →  :8000  (2 replicas, one per node, --api-key protected)
        ├── Prometheus  →  :9090
        └── Grafana  →  :3000

External AI Gateway path (separate project, foodedge demo chat):
  Browser → foodedge (Akamai Functions) → Zuplo AI Gateway
    → vLLM :8000 (Authorization: Bearer <api-key>, no IP check)
```

## Quick Start

```bash
# 1. Get your public IP
export ALLOWED_IP=$(curl -s https://api.ipify.org)/32
echo "Your IP: $ALLOWED_IP"

# 2. Configure Terraform
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars — set allowed_admin_cidr = "$ALLOWED_IP"

# 3. Set Linode token (never hardcode)
export LINODE_TOKEN="your_token_here"

# 4. Deploy infrastructure
make terraform-init
make terraform-plan
make terraform-apply

# 5. Deploy Kubernetes workloads
make deploy-all

# 6. Validate
make validate

# 7. Run smoke tests
make test-smoke
```

## Access Services (IP only, no DNS)

After deployment:

```bash
# Get LoadBalancer IPs
kubectl get svc -A --context=chicago
kubectl get svc -A --context=seattle

# vLLM (Chicago)
curl http://<CHICAGO-LB-IP>:8000/health

# Grafana (Chicago)
http://<CHICAGO-LB-IP>:3000  (admin/admin)

# Prometheus (Chicago)
http://<CHICAGO-LB-IP>:9090
```

## Docs

- [Architecture](docs/ARCHITECTURE.md)
- [Deployment Guide](docs/DEPLOYMENT_GUIDE.md)
- [GPU Setup](docs/GPU_SETUP.md)
- [NVIDIA Stack](docs/NVIDIA_STACK.md)
- [Inference Runtime](docs/INFERENCE_RUNTIME.md)
- [Multi-region Routing](docs/MULTIREGION_ROUTING.md)
- [Observability](docs/OBSERVABILITY.md)
- [Performance Testing](docs/PERFORMANCE_TESTING.md)
- [Ray Serve Demo](docs/RAY_SERVE.md)
- [Security / IP Allowlist](docs/SECURITY_IP_ALLOWLIST.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Limitations](docs/LIMITATIONS.md)
- [References](docs/REFERENCES.md)
