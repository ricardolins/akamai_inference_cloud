# Architecture — Akamai Inference Cloud

## Overview

Multi-region AI inference with automatic failover, GPU-accelerated inference, and full observability. Admin-facing services (Grafana, Prometheus, Kubernetes API, SSH) are IP-restricted — no domain, no DNS, IP only. vLLM additionally supports an application-level API key (see [Security Layers](#security-layers)) so it can also be called by edge platforms that have no fixed IP, such as the Zuplo AI Gateway used by the foodedge demo.

Chicago's single GPU node is also **toggleable** between raw vLLM and a Ray Serve demo of the same model (`make demo-ray-on` / `make demo-ray-off`) — see [RAY_SERVE.md](RAY_SERVE.md). Only one of the two holds the GPU at a time; Seattle is unaffected either way.

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


Chicago (us-ord)                       Seattle (us-sea)
──────────────────────                 ──────────────────────
LKE Cluster (Normal)                   LKE Cluster (Normal)
  │                                      │
  1 node: GPU RTX 4000 Ada               2 nodes: GPU RTX 4000 Ada (autoscaler min=max=2)
  │ 20 GB VRAM                           │ 20 GB VRAM each
  │                                      │
  ├── gpu-operator ns                    ├── gpu-operator ns
  │     ├── NVIDIA Driver                │     ├── NVIDIA Driver
  │     ├── GPU Device Plugin            │     ├── GPU Device Plugin
  │     ├── DCGM Exporter :9400          │     ├── DCGM Exporter :9400
  │     └── Node Feature Disc.           │     └── Node Feature Disc.
  │                                      │
  ├── inference ns                       ├── inference ns
  │     ├── vLLM :8000 (LB), 1 replica   │     ├── vLLM :8000 (LB), 2 replicas
  │     │   └── Mistral-7B               │     │   └── Mistral-7B (one per node)
  │     │   └── requires --api-key       │     │   └── requires --api-key
  │     └── Fallback Router              │     └── Fallback Router
  │           :8080 (LB)                 │           :8080 (LB)
  │                                      │
  └── monitoring ns                      └── monitoring ns
        ├── Prometheus :9090 (LB)              ├── Prometheus :9090 (LB)
        └── Grafana    :3000 (LB)              └── Grafana    :3000 (LB)
```

### External AI Gateway path (foodedge demo)

A separate project (`food_delivery_akamai_stack`) runs a food-delivery demo app with
an AI support chat. It reaches this project's vLLM through a Zuplo AI Gateway instead
of the Fermyon/Node.js router above, because that path needs application-level auth
rather than IP filtering (see [Layer 5](../docs/SECURITY_IP_ALLOWLIST.md#layer-5--vllm-api-key-application-level)):

```
Browser (foodedge visitor)
  │
  POST /api/chat  (same origin, no key exposed to the browser)
  ↓
foodedge Wasm component (Akamai Functions — separate app/project)
  │  holds the Zuplo API key server-side only
  ↓
Zuplo AI Gateway  (provider "custom" → vLLM, base URL = NodeBalancer hostname)
  │  adds "Authorization: Bearer <vllm-api-key>"
  ↓
vLLM Chicago :8000  (--api-key protected; network layer temporarily 0.0.0.0/0
                      because Zuplo/Cloudflare Workers has no fixed egress IP)
```

This path bypasses the Fermyon/Node.js router entirely — it's a second, independent
way to reach vLLM, aimed at external consumers management can't put on the admin
allowlist. The router above remains the path for admin-only, IP-restricted access.

## Component Roles

| Component | Role | Port | Namespace |
|---|---|---|---|
| NVIDIA GPU Operator | Installs driver, toolkit, device plugin | — | gpu-operator |
| DCGM Exporter | Exports GPU metrics to Prometheus | 9400 | gpu-operator |
| vLLM | OpenAI-compatible inference server, `--api-key` protected | 8000 | inference |
| Fermyon Spin Router | Primary multi-region router + IP filter | 3000 local | — |
| Node.js Fallback Router | Secondary router in Kubernetes | 8080 | inference |
| Zuplo AI Gateway | External entry point for the foodedge demo chat; auths to vLLM via API key, not IP | — | (external, Cloudflare Workers) |
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
  │
  Layer 5: vLLM API key (application-level, for no-fixed-IP callers)
    └── vLLM --api-key requires "Authorization: Bearer <key>"
         Used instead of (not in addition to) IP filtering when the
         caller is an edge platform with no stable egress IP — e.g.
         Zuplo AI Gateway. See docs/SECURITY_IP_ALLOWLIST.md.
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
