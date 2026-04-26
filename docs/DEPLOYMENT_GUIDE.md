# Deployment Guide

Step-by-step guide to deploy the complete Akamai Inference Cloud environment.

## Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| Terraform | >= 1.5.0 | Infrastructure provisioning |
| kubectl | >= 1.28 | Kubernetes management |
| helm | >= 3.12 | Kubernetes package manager |
| k6 | >= 0.47 | Load testing |
| curl | any | Health checks |
| spin | >= 2.0 | Fermyon router (optional) |

```bash
# Install Terraform
brew install terraform

# Install kubectl
brew install kubectl

# Install Helm
brew install helm

# Install k6
brew install k6

# Install Spin CLI (optional, for Fermyon router)
curl -fsSL https://developer.fermyon.com/downloads/install.sh | bash
```

## Step 1 — Get Your Public IP

```bash
MY_IP=$(curl -s https://api.ipify.org)
echo "Your IP: ${MY_IP}"
# Example: 200.100.50.25
```

## Step 2 — Configure Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars

# Edit terraform.tfvars
# Set: allowed_admin_cidr = "YOUR_IP/32"
```

Example `terraform.tfvars`:
```hcl
allowed_admin_cidr = "200.100.50.25/32"
```

## Step 3 — Set Linode Token

Never hardcode your token. Always use the environment variable:

```bash
export LINODE_TOKEN="your_linode_api_token_here"

# Verify it works:
curl -H "Authorization: Bearer ${LINODE_TOKEN}" \
  https://api.linode.com/v4/profile | python3 -m json.tool | grep username
```

Generate a token at: https://cloud.linode.com/profile/tokens
Required scopes: Linodes (Read/Write), Kubernetes (Read/Write), Firewalls (Read/Write)

## Step 4 — Verify GPU Plan Availability

Before applying, confirm the GPU plan exists in your target regions:

```bash
# Install Linode CLI if needed
pip3 install linode-cli

linode-cli linodes types --json \
  | python3 -c "import sys,json; [print(t['id'],t.get('label','')) for t in json.load(sys.stdin) if 'gpu' in t.get('class','')]"
```

Update `gpu_node_type` in `terraform.tfvars` if the plan ID differs from `g1-gpu-rtx4000ada-1`.

## Step 5 — Deploy Infrastructure

```bash
make terraform-init
make terraform-plan   # Review what will be created
make terraform-apply  # Creates 2 LKE clusters + 2 firewalls
```

**What gets created:**
- `akai-inference-chicago` LKE cluster in us-ord
- `akai-inference-seattle` LKE cluster in us-sea
- `akai-inference-chicago-fw` Cloud Firewall attached to Chicago nodes
- `akai-inference-seattle-fw` Cloud Firewall attached to Seattle nodes
- `kubeconfig-chicago.yaml` and `kubeconfig-seattle.yaml` written locally

Estimated time: 5-10 minutes.

## Step 6 — Configure kubectl Contexts

```bash
export KUBECONFIG=./kubeconfig-chicago.yaml:./kubeconfig-seattle.yaml

# Verify both clusters are reachable:
kubectl get nodes --context=chicago
kubectl get nodes --context=seattle
```

Note: LKE uses GPU nodes which take longer to boot (~5 min) due to driver init.

## Step 7 — Deploy Kubernetes Workloads

```bash
make deploy-all
```

This script:
1. Applies namespaces in both clusters
2. Installs NVIDIA GPU Operator (Helm)
3. Deploys vLLM with Mistral-7B
4. Installs Prometheus + Grafana (Helm)
5. Waits for LoadBalancer IPs
6. Deploys fallback Node.js router with discovered IPs
7. Builds and starts Fermyon Spin router (if `spin` is installed)

Estimated time: 15-20 minutes (GPU Operator + model download).

## Step 8 — Wait for Model Load

vLLM downloads Mistral-7B (~14GB) on first start. Monitor:

```bash
kubectl logs -f -l app=vllm -n inference --context=chicago
```

You'll see:
```
INFO  Loading model weights...
INFO  GPU blocks: 1024, CPU blocks: 256
INFO  Starting vLLM API server at http://0.0.0.0:8000
```

## Step 9 — Validate

```bash
make validate
```

Individual validations:
```bash
make validate-gpu       # GPU is accessible and running
make validate-security  # No 0.0.0.0/0 exposure
make validate-vllm      # /health returns 200
```

## Step 10 — Get Service IPs

```bash
make get-ips
```

Or manually:
```bash
# Chicago vLLM
CHICAGO_VLLM_IP=$(kubectl get svc vllm -n inference --context=chicago \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Seattle vLLM
SEATTLE_VLLM_IP=$(kubectl get svc vllm -n inference --context=seattle \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "Chicago vLLM: http://${CHICAGO_VLLM_IP}:8000"
echo "Seattle vLLM: http://${SEATTLE_VLLM_IP}:8000"
```

## Step 11 — Run First Inference

```bash
curl http://${CHICAGO_VLLM_IP}:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mistralai/Mistral-7B-Instruct-v0.3",
    "messages": [{"role": "user", "content": "Hello! What GPU are you running on?"}],
    "max_tokens": 100
  }'
```

## Step 12 — Access Grafana

```bash
GRAFANA_IP=$(kubectl get svc grafana -n monitoring --context=chicago \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "Grafana: http://${GRAFANA_IP}:3000"
# Login: admin / admin (change immediately)
```

## Step 13 — Run Tests

```bash
make test-smoke   # Quick verification
make test-load    # Sustained load
make test-stress  # Breaking point
make test-failover # Multi-region failover
```

## Teardown

```bash
make terraform-destroy
# Type 'destroy' to confirm
```

This deletes ALL resources including GPU nodes. Linode Block Storage PVCs are
retained by default (storageClassName: linode-block-storage-retain).
Delete them manually in the Linode Cloud Manager if needed.
