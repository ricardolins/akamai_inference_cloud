# Limitations

## LKE Normal — Kubernetes API Server

**Limitation:** LKE Normal (non-Enterprise) does NOT support private Kubernetes API endpoints. The API server (port 6443) is publicly reachable.

**Impact:** Anyone with the kubeconfig credentials can reach the API server endpoint.

**Mitigations in this project:**
1. Linode Cloud Firewall restricts port 6443 to `allowed_admin_cidr` (your IP only)
2. Kubeconfig files are gitignored and file-permission 0600
3. Kubernetes RBAC uses cluster-admin role (minimum required for this setup)

**Full solution:** Upgrade to LKE Enterprise, which supports private API server endpoints and VPC integration. See: https://www.linode.com/docs/products/compute/kubernetes/

---

## Fermyon Spin Round-Robin

**Limitation:** Fermyon Spin components are stateless — no shared state between invocations. Round-robin is approximated by timestamp-based selection (alternates per second), not a true request counter.

**Impact:** Under low traffic (< 1 req/sec), both regions may serve the same ratio. Under high traffic (> 1 req/sec), distribution is effectively 50/50.

**Workaround:** Use the Node.js fallback router for more accurate round-robin (it maintains a counter in process memory).

---

## Single GPU Per Region

**Limitation:** One RTX 4000 Ada per region. No horizontal GPU scaling.

**Impact:**
- Max concurrency limited by single GPU KV cache (~16 concurrent requests at 4096 context)
- No redundancy within a region (GPU failure = region down)
- vLLM `replicas: 1` — Recreate strategy (brief downtime during updates)

**Workaround:** Add more GPU nodes to the pool and use tensor parallelism (requires matching GPU count to `TENSOR_PARALLEL_SIZE`).

---

## Model Download on First Start

**Limitation:** Mistral-7B is ~14GB. On first deployment, vLLM downloads the model from HuggingFace.

**Impact:**
- Cold start: 10-20 minutes (depending on network speed)
- Kubernetes readiness probe will fail during download (normal)
- PVC re-use avoids re-download on pod restarts

**Workaround:** Pre-download the model to a PVC before first deployment, or use a private model registry.

---

## RTX 4000 Ada — No MIG Support

**Limitation:** MIG (Multi-Instance GPU) is only available on NVIDIA A100/H100 (data center GPUs).

**Impact:** Cannot split the GPU into smaller independent instances. Each vLLM instance uses the full GPU.

**Workaround:** Time-slicing is available (GPU Operator supports it) but not recommended for LLM inference — it introduces latency spikes.

---

## No TLS / HTTPS

**Limitation:** All services are exposed via HTTP, not HTTPS. No certificates configured.

**Impact:** Traffic between your machine and the LoadBalancer IPs is unencrypted.

**Acceptable because:** Access is restricted to your IP only (LAN-equivalent trust level). For production, add a TLS-terminating proxy (Nginx, Caddy, or Kubernetes Gateway API with cert-manager).

---

## NodeBalancer Cost

**Limitation:** Each Kubernetes `LoadBalancer` Service creates a Linode NodeBalancer ($10/month each).

**Services in this project:** vLLM (×2 regions) + Grafana (×2) + Prometheus (×2) + Router (×2) = 8 NodeBalancers = ~$80/month in NodeBalancer fees alone.

**Reduction:** Use a single Ingress controller (Nginx or Traefik) with NodePort + 1 NodeBalancer per region. This reduces to 2 NodeBalancers total ($20/month). Not implemented here to keep the architecture simple and IP-addressable per service.

---

## Fermyon Spin Streaming

**Limitation:** Fermyon Spin's `fetch()` API buffers the full response before returning. True server-sent events (SSE) streaming is not passed through in the current implementation.

**Impact:** If you use `stream: true` in vLLM requests via the Spin router, you will receive the full response in one batch (no token-by-token streaming).

**Workaround:** Use the Node.js fallback router, which properly pipes SSE streams via `proxyRes.pipe(clientRes)`. Or use the vLLM endpoint directly (bypassing the router) for streaming requests.

---

## DCGM Metrics Availability

**Limitation:** DCGM (Data Center GPU Manager) is designed for data center GPUs (A100, H100, etc.). On RTX 4000 Ada (workstation/prosumer GPU), some DCGM metrics may not be available.

**Metrics that may be unavailable:**
- NVLink bandwidth (RTX 4000 Ada has no NVLink)
- ECC memory error counters (may be 0 or unavailable)
- Some power capping metrics

**Core metrics that DO work:** GPU utilization, VRAM usage, temperature, power draw, clock speeds.
