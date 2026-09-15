# Ray Serve Demo (Chicago) — Step-by-Step Walkthrough

## Why this exists

The rest of this project serves one model on one engine (vLLM) behind a thin
region-selecting router. Ray Serve answers a different question: **how do you
orchestrate multiple models/pipelines, with autoscaling and composition, on
top of an engine like vLLM?** This demo runs the exact same model
(`mistralai/Mistral-7B-Instruct-v0.3`) through Ray Serve instead, so you can
show a client "same GPU, same model, different serving layer" side by side
with the raw-vLLM setup documented in [ARCHITECTURE.md](ARCHITECTURE.md).

Read this whole doc once before running the demo live — step 2 below takes
several minutes on a cold start, and you don't want to discover that for the
first time in front of a client.

## The one thing you must understand first: the GPU constraint

Chicago has exactly **one** GPU node (RTX 4000 Ada, no MIG, and per
[LIMITATIONS.md](LIMITATIONS.md) time-slicing isn't viable for LLM inference
either). Ray Serve's GPU worker requests the same `nvidia.com/gpu: 1` vLLM's
pod already holds. **The two cannot run at the same time.** This demo is a
toggle, not an "always on" service — you turn vLLM off to turn Ray Serve on,
and vice versa. Two `make` targets do the whole swap:

```bash
make demo-ray-on     # vLLM → 0 replicas, Ray Serve GPU worker → 1
make demo-ray-off    # Ray Serve GPU worker → 0, vLLM → 1 replica
```

Seattle is completely unaffected either way — it keeps serving vLLM on its
two nodes the whole time. If you need vLLM reachable *during* the Ray Serve
demo (e.g. someone else is testing it), point them at Seattle instead of
Chicago.

## Before you start: a pre-demo checklist

Run this a few minutes before the client call, not during it.

1. **Confirm your IP is still the allowed one.** Everything here is
   restricted to `allowed_admin_cidr` (see
   [SECURITY_IP_ALLOWLIST.md](SECURITY_IP_ALLOWLIST.md)). If your IP changed
   since the last `terraform apply`, nothing below will be reachable.
   ```bash
   curl -s https://api.ipify.org
   grep allowed_admin_cidr terraform/terraform.tfvars
   ```
   These two must match (as `X.X.X.X` vs `X.X.X.X/32`). If not, update
   `terraform.tfvars` and run `make terraform-apply` first.

2. **Confirm Chicago is currently on vLLM** (the normal resting state — Ray
   Serve's GPU worker should be at 0 unless someone left a demo running):
   ```bash
   export KUBECONFIG=kubeconfig-chicago.yaml
   kubectl get pods -n inference -l app=vllm      # expect one Running
   kubectl get pods -n ray-serve                  # expect only the head, no worker
   ```

3. **Warm up the image cache if you can.** The first `demo-ray-on` after a
   node reboot has to pull the `rayproject/ray-llm` image (~11 GB) — if
   that hasn't happened recently, do a throwaway `make demo-ray-on` /
   `make demo-ray-off` cycle before the call so the image is already cached
   on the node and the live demo only pays the model-load time (still a few
   minutes, but much less than a full cold pull).

## The demo, step by step

### Step 1 — Show the baseline: vLLM answering directly

This is the "before" — the thing the client has presumably already seen
elsewhere in this project, worth a 10-second reminder before you switch it
out.

```bash
# Get the vLLM API key (never put this in a doc or commit it — always pull it live)
VLLM_KEY=$(KUBECONFIG=kubeconfig-chicago.yaml kubectl get secret vllm-auth -n inference \
  -o jsonpath='{.data.api-key}' | base64 -d)

VLLM_IP=$(KUBECONFIG=kubeconfig-chicago.yaml kubectl get svc vllm -n inference \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

curl -s -H "Authorization: Bearer ${VLLM_KEY}" \
  -X POST "http://${VLLM_IP}:8000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"mistralai/Mistral-7B-Instruct-v0.3","messages":[{"role":"user","content":"In one sentence, what are you?"}]}'
```

**What to say:** "This is Mistral-7B running directly on vLLM, on our one GPU
in Chicago. It's authenticated with an API key — see
[SECURITY_IP_ALLOWLIST.md §Layer 5](SECURITY_IP_ALLOWLIST.md#layer-5--vllm-api-key-application-level)
for why."

### Step 2 — Swap the GPU over to Ray Serve

```bash
make demo-ray-on
```

**What to say while this runs** (this is the part that takes a few minutes,
so narrate through it rather than sitting in silence):

- "First it scales vLLM down to zero — that's what frees the GPU."
- "Then it scales up a Ray Serve worker pod, which claims that same GPU and
  loads the model into it. This is a cold model load, same as vLLM's own
  startup — it's not slow because of Ray, it's slow because loading a 7B
  model onto a GPU always takes a couple of minutes."
- Optional, to fill time productively: open a second terminal and watch it
  live —
  ```bash
  export KUBECONFIG=kubeconfig-chicago.yaml
  watch kubectl get pods -n ray-serve -n inference
  ```

The script itself prints progress and exits with a clear ✓ or ⚠ — if you see
the warning, check `kubectl get rayservice ray-serve-llm -n ray-serve -o yaml`
before panicking; the model is very likely still loading (see
Troubleshooting below).

### Step 3 — Same question, through Ray Serve

```bash
RAY_IP=$(KUBECONFIG=kubeconfig-chicago.yaml kubectl get svc ray-serve-llm -n ray-serve \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

curl -s -X POST "http://${RAY_IP}:8000/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"mistralai/Mistral-7B-Instruct-v0.3","messages":[{"role":"user","content":"In one sentence, what are you?"}]}'
```

**What to point out in the response JSON:**
- `model` — same model ID as step 1.
- `system_fingerprint` — starts with `vllm-...`. Ray Serve LLM runs vLLM as
  its engine underneath; Ray is the orchestration layer around it, not a
  replacement for it. (The exact vLLM version differs from the standalone
  deployment's — Ray's bundled image pins its own — which is fine to
  mention if asked, but not the point of the demo.)
- No API key was needed this time — this demo path doesn't have Layer 5
  auth wired up (it's admin-IP-only instead, same as Grafana/Prometheus).
  Worth flagging as a deliberate scope cut for this demo, not a design
  recommendation — a production Ray Serve deployment meant for the same
  no-fixed-IP callers as the Zuplo/foodedge integration would need the same
  API-key treatment vLLM already has.

### Step 4 — Show the Ray dashboard

```bash
DASH_IP=$(KUBECONFIG=kubeconfig-chicago.yaml kubectl get svc ray-dashboard -n ray-serve \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "http://${DASH_IP}:8265"
```

Open that in a browser (admin IP only — it won't load from anywhere else).
Navigate to **Serve** in the left nav. This is the part that's actually
different from vLLM:

- The `llms` application and its `OpenAiIngress` + `LLMServer:mistralai...`
  deployments, each with their own replica count and autoscaling config —
  point out `deployment_config.autoscaling_config` in
  `kubernetes/ray-serve/rayservice.yaml` as the knob that controls this.
- **The pitch**: today this is one model, one deployment. The same
  dashboard, with the same `serveConfigV2` structure, is where you'd see
  *multiple* models each autoscaling independently, or a router deployment
  in front of several — that's the actual value Ray Serve adds over "just
  run vLLM in Kubernetes." This demo shows the mechanism on a single model
  because that's what the GPU budget allows; the architecture doesn't change
  when you add a second model, only the `llm_configs` list grows.
- If asked about LoRA: Ray Serve LLM can multiplex several LoRA adapters
  onto one base model deployment, serving many fine-tuned variants without
  a separate GPU replica per adapter — not configured in this demo, but the
  natural next `llm_configs` entry to add.

### Step 5 — Swap back

```bash
make demo-ray-off
```

Same shape as step 2 in reverse: Ray Serve's worker scales to 0, then vLLM
scales back to 1 and waits for it to become ready. Confirm with:

```bash
curl -s -H "Authorization: Bearer ${VLLM_KEY}" \
  "http://${VLLM_IP}:8000/v1/models"
```

**Always do this before ending the session**, even if the demo went short —
leaving Ray Serve's GPU worker up isn't dangerous (nothing else needs the
GPU right this second), but it does mean vLLM is unreachable for anyone else
using Chicago until someone remembers to flip it back.

## Talking points, condensed

- **Same model, same GPU, two engines.** The response content is
  identical — what's being demonstrated is the serving layer around it, not
  a model quality difference.
- **What Ray Serve adds that raw vLLM + Kubernetes doesn't**: per-deployment
  autoscaling, composing multiple models/pipelines behind one app (a router
  deployment fanning out to several model deployments), and multiplexing
  several LoRA adapters onto one base model.
- **What it costs**: another moving part (RayCluster head + worker
  lifecycle, its own dashboard/metrics) on top of the router layers this
  project already has (Fermyon Spin, Node.js fallback, and — in the
  separate `food_delivery_akamai_stack` demo — a Zuplo AI Gateway). It's
  worth that cost specifically when the story is multi-model orchestration,
  not "serve one model" — say that plainly if a client asks whether they
  need it.

## Troubleshooting

| Symptom | What's actually happening | What to do |
|---|---|---|
| `demo-ray-on` prints the ⚠ instead of ✓ | The model is very likely still loading — the script polls for up to 10 minutes, but a fully cold image pull + model load can exceed that on a slow network day. | `kubectl logs -n ray-serve -l ray.io/node-type=head \| grep controller` — look for `started successfully` at the bottom. Once it's there, retry the `curl` in step 3; no need to re-run `make demo-ray-on`. |
| `curl` to the Ray Serve endpoint hangs or connection-refuses | Either your IP doesn't match `allowed_admin_cidr` anymore, or the worker isn't up yet. | Re-check the pre-demo checklist's IP step; if that's fine, check `kubectl get pods -n ray-serve`. |
| `demo-ray-off` warns that vLLM didn't report Ready in time | vLLM is doing its own model load (same cold-start cost documented in [LIMITATIONS.md](LIMITATIONS.md)) — the warning fires if that takes past the wait window, not necessarily a real failure. | `kubectl get pods -n inference -l app=vllm` — wait for `1/1 Running`, then retest. |
| Old `Completed` pods showing up in `kubectl get pods` output for either vLLM or Ray | Harmless leftover — vLLM's `Recreate` deploy strategy (and Ray's own pod churn) don't clean these up automatically. `toggle-ray-demo.sh` already filters them out of its own wait logic. | Ignore, or `kubectl delete pod <name> -n <ns>` if it's visually annoying during a screen share. |

## What's deployed (reference)

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
- **`terraform/firewall.tf`** — one rule, `allow-admin-ray-dashboard` (port
  8265, admin IP only), in the **Chicago** firewall block only. No new rule
  was needed for port 8000 itself — `allow-public-vllm` already opens that
  port to `allowed_admin_cidr` on Chicago, and Ray Serve's LoadBalancer gets
  its own IP, so there's no collision.
- **`scripts/toggle-ray-demo.sh`** — does the actual GPU handoff behind
  `make demo-ray-on` / `make demo-ray-off`. Patches both the `RayService`
  and the underlying `RayCluster` directly (patching only the `RayService`
  didn't reliably propagate to the live `RayCluster` on this KubeRay
  version, 1.7.0), and filters out terminal-phase pods in its wait loops so
  old `Completed` leftovers don't cause false-negative timeouts.

## Observability

Ray head/worker pods carry `prometheus.io/scrape: "true"` annotations, same
convention as `kubernetes/vllm/deployment.yaml`, so Chicago's existing
Prometheus picks up Ray's native metrics without extra scrape-config changes.
There's no dedicated Grafana panel set for Ray yet — the existing
`kubernetes/monitoring/dashboards/vllm-gpu.json` GPU panels (DCGM-based) show
the same underlying hardware regardless of which engine is running on it.
