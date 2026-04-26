# Architecture — Akamai Inference Cloud

## Overview

Multi-region AI inference with automatic failover, GPU-accelerated inference, and full observability. All services are IP-restricted — no domain, no DNS, IP only.

## Topology

```
Your Machine (allowed_admin_cidr)
  │
  ├── Fermyon Spin Router (PRIMARY)
  │     ├── /health       → router health
  │     ├── /status       → region health status
  │     └── /v1/*         → proxy to vLLM (after IP check)
  │           ↓
  │     Region selection: round-robin or failover
  │           │
  │     ┌─────┴──────┐
  │     ↓             ↓
  │  Chicago        Seattle
  │  us-ord          us-sea
  │
  └── Node.js Fallback Router (SECONDARY — in Kubernetes)
        └── Same routing logic — used if Spin is unavailable


Chicago (us-ord)                Seattle (us-sea)
──────────────────────          ──────────────────────
LKE Cluster (Normal)            LKE Cluster (Normal)
  │                               │
  Node: GPU RTX 4000 Ada          Node: GPU RTX 4000 Ada
  │ 20 GB VRAM                    │ 20 GB VRAM
  │                               │
  ├── gpu-operator ns             ├── gpu-operator ns
  │     ├── NVIDIA Driver         │     ├── NVIDIA Driver
  │     ├── GPU Device Plugin     │     ├── GPU Device Plugin
  │     ├── DCGM Exporter :9400   │     ├── DCGM Exporter :9400
  │     └── Node Feature Disc.    │     └── Node Feature Disc.
  │                               │
  ├── inference ns                ├── inference ns
  │     ├── vLLM :8000 (LB)       │     ├── vLLM :8000 (LB)
  │     │   └── Mistral-7B        │     │   └── Mistral-7B
  │     └── Fallback Router       │     └── Fallback Router
  │           :8080 (LB)          │           :8080 (LB)
  │                               │
  └── monitoring ns               └── monitoring ns
        ├── Prometheus :9090 (LB)       ├── Prometheus :9090 (LB)
        └── Grafana    :3000 (LB)       └── Grafana    :3000 (LB)
```

## Component Roles

| Component | Role | Port | Namespace |
|---|---|---|---|
| NVIDIA GPU Operator | Installs driver, toolkit, device plugin | — | gpu-operator |
| DCGM Exporter | Exports GPU metrics to Prometheus | 9400 | gpu-operator |
| vLLM | OpenAI-compatible inference server | 8000 | inference |
| Fermyon Spin Router | Primary multi-region router + IP filter | 3000 local | — |
| Node.js Fallback Router | Secondary router in Kubernetes | 8080 | inference |
| Prometheus | Metrics collection + 7-day retention | 9090 | monitoring |
| Grafana | Metrics dashboards | 3000 | monitoring |

## Security Layers

```
Request from allowed_admin_cidr IP
  │
  Layer 1: Linode Cloud Firewall (Terraform)
    └── DROP all except allowed_admin_cidr on
         ports: 22, 6443, 8000, 3000, 9090, 80, 8080
  │
  Layer 2: Kubernetes LoadBalancer (NodeBalancer)
    └── spec.loadBalancerSourceRanges = [allowed_admin_cidr]
         Enforced at cloud provider level
  │
  Layer 3: Application IP check (Router)
    └── Fermyon Spin / Node.js checks X-Forwarded-For
         Returns 403 for any non-allowed IP
  │
  Layer 4: Kubeconfig protection
    └── 0600 permissions, gitignored
         Only admin has cluster access
```

## Inference Request Flow

```
1. POST /v1/chat/completions → Router
2. Router checks IP → 403 if blocked
3. Router checks health of both regions (concurrent, 5s timeout)
4. Router selects region (round-robin or failover)
5. Router proxies request to vLLM LB IP:8000
6. vLLM queues request, runs inference on RTX 4000 Ada GPU
7. vLLM returns OpenAI-compatible JSON
8. Router adds x-region + x-fallback headers
9. Response → Client
```

## Storage

| Resource | Size | Storage Class | Purpose |
|---|---|---|---|
| vLLM model cache | 50 GB | linode-block-storage-retain | Model weights — survives pod restarts |
| Grafana persistence | 5 GB | linode-block-storage-retain | Dashboard + alert state |
| Prometheus | 10 GB | ephemeral | 7-day metric window |
