# Ray Serve Demo (Chicago)

## Why this exists

The rest of this project serves one model on one engine (vLLM) behind a thin
region-selecting router. Ray Serve answers a different question: **how do you
orchestrate multiple models/pipelines, with autoscaling and composition, on
top of an engine like vLLM?** This demo runs the exact same model
(`mistralai/Mistral-7B-Instruct-v0.3`) through Ray Serve instead, so a client
can see "same GPU, same model, different serving layer" side by side with the
raw-vLLM setup documented in [ARCHITECTURE.md](ARCHITECTURE.md).

## The GPU constraint — read this before touching it

Chicago has exactly **one** GPU node (RTX 4000 Ada, no MIG, and per
[LIMITATIONS.md](LIMITATIONS.md) time-slicing isn't viable for LLM inference
either). Ray Serve's GPU worker requests the same `nvidia.com/gpu: 1` vLLM's
pod already holds — the two cannot run at once. So this is not an "always on"
service: it's a **toggle**.

```
make demo-ray-on     # vLLM → 0 replicas, Ray Serve GPU worker → 1
make demo-ray-off    # Ray Serve GPU worker → 0, vLLM → 1 replica
```

Both directions wait for the outgoing pod to fully terminate (releasing the
GPU) before scaling the incoming one up — see `scripts/toggle-ray-demo.sh`.
`demo-ray-on` includes a first-run model download inside the Ray worker
container, so budget several minutes the first time.

Seattle is untouched by any of this — its two nodes keep running vLLM as
normal, independent of whatever state Chicago is in.

## What's deployed

- **KubeRay operator** (`kuberay-operator`, Helm, namespace `ray-system`) —
  cluster-wide controller for the `RayService`/`RayCluster` CRDs. CPU-only,
  installed once, doesn't touch the GPU budget.
- **`kubernetes/ray-serve/rayservice.yaml`** — a `RayService` with:
  - a CPU-only head (runs the HTTP proxy + control plane, resourced small
    since Chicago's node is already ~80% CPU-allocated by vLLM + gpu-operator)
  - one GPU worker group, `replicas: 0` by default (see constraint above),
    scheduled with the same `nodeSelector`/toleration pattern as
    `kubernetes/vllm/deployment.yaml`
  - a `serveConfigV2` app using Ray Serve LLM
    (`ray.serve.llm:build_openai_app`) with engine args mirrored from
    `kubernetes/vllm/configmap.yaml` (`max_model_len: 4096`,
    `gpu_memory_utilization: 0.90`, `dtype: float16`) so behavior is
    comparable to the vLLM baseline
  - image: `rayproject/ray-llm:2.59.0.bfe9b7-py312-cu130` (CUDA 13.0 —
    confirmed compatible with the node's driver, which supports up to CUDA
    13.2: `kubectl exec -n gpu-operator daemonset/nvidia-device-plugin-daemonset -- nvidia-smi`)
- **`kubernetes/ray-serve/service.yaml`** — two `LoadBalancer` Services,
  same `loadBalancerSourceRanges: [allowed_admin_cidr]` pattern as
  `kubernetes/vllm/service.yaml`:
  - `ray-serve-llm` (port 8000) — the OpenAI-compatible endpoint. Traffic
    always enters through the Ray **head** pod's HTTP proxy, which routes
    internally to the GPU worker — the Service selects the head, not the
    worker.
  - `ray-dashboard` (port 8265) — Ray's own web dashboard.
- **`terraform/firewall.tf`** — one new rule, `allow-admin-ray-dashboard`
  (port 8265, admin IP only), added to the **Chicago** firewall block only.
  No new rule was needed for port 8000 itself — `allow-public-vllm` already
  opens that port to `allowed_admin_cidr` on Chicago, and Ray Serve's
  LoadBalancer gets its own IP, so there's no collision.

## Using it

```bash
make demo-ray-on

curl -s http://<ray-serve-llm-LB-IP>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mistralai/Mistral-7B-Instruct-v0.3","messages":[{"role":"user","content":"hi"}]}'

# Ray dashboard (admin IP only)
open http://<ray-dashboard-LB-IP>:8265

make demo-ray-off
```

## Talking points for a client demo

- **Same model, same GPU, two engines** — vLLM alone vs. vLLM orchestrated by
  Ray Serve. The response quality/content is identical; what differs is the
  serving layer around it.
- **What Ray Serve adds that raw vLLM + Kubernetes doesn't**: native
  autoscaling of replicas per deployment (`autoscaling_config` in
  `serveConfigV2`), composing multiple models/pipelines behind one app (a
  router deployment calling into several model deployments — not shown in
  this single-model demo, but the natural next step), and multiplexing
  several LoRA adapters onto one base model without a separate deployment
  per adapter.
- **What it costs**: another moving part (RayCluster head + worker
  lifecycle, its own dashboard/metrics) on top of the router layers this
  project already has (Fermyon Spin, Node.js fallback, and — for the
  separate `food_delivery_akamai_stack` demo — a Zuplo AI Gateway). Worth it
  specifically when the story is multi-model orchestration, not "serve one
  model."

## Observability

Ray head/worker pods carry `prometheus.io/scrape: "true"` annotations, same
convention as `kubernetes/vllm/deployment.yaml`, so Chicago's existing
Prometheus picks up Ray's native metrics without extra scrape-config changes.
There's no dedicated Grafana panel set for Ray yet — the existing
`kubernetes/monitoring/dashboards/vllm-gpu.json` GPU panels (DCGM-based) show
the same underlying hardware regardless of which engine is running on it.
