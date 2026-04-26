# Performance Testing — k6

## Test Suite Overview

| Test | File | Duration | Goal |
|---|---|---|---|
| Smoke | k6/smoke.js | ~2 min | Verify endpoint is alive |
| Load | k6/load.js | ~12 min | Measure throughput under sustained load |
| Stress | k6/stress.js | ~13 min | Find breaking point |
| Failover | k6/failover.js | ~9 min | Validate multi-region routing |

## Running Tests

```bash
# First: get your vLLM IPs
CHICAGO_IP=$(kubectl get svc vllm -n inference --context=chicago \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
SEATTLE_IP=$(kubectl get svc vllm -n inference --context=seattle \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
ROUTER_IP=$(kubectl get svc inference-router -n inference --context=chicago \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Smoke (always run first)
k6 run --env BASE_URL=http://${CHICAGO_IP}:8000 k6/smoke.js

# Load
k6 run --env BASE_URL=http://${CHICAGO_IP}:8000 k6/load.js

# Stress (will cause OOM/errors — expected)
k6 run --env BASE_URL=http://${CHICAGO_IP}:8000 k6/stress.js

# Failover
k6 run \
  --env BASE_URL_CHICAGO=http://${CHICAGO_IP}:8000 \
  --env BASE_URL_SEATTLE=http://${SEATTLE_IP}:8000 \
  --env ROUTER_URL=http://${ROUTER_IP}:8080 \
  k6/failover.js

# Or use Makefile targets:
CHICAGO_VLLM_IP=${CHICAGO_IP} make test-smoke
CHICAGO_VLLM_IP=${CHICAGO_IP} make test-load
```

## Expected Results — RTX 4000 Ada + Mistral-7B

### Smoke Test
```
✓ health endpoint returns 200
✓ models endpoint returns 200
✓ inference returns 200
✓ inference response has choices
Latency: 2-8s (first request may be slower — cold KV cache)
```

### Load Test (2 concurrent users)
```
Requests:     ~30-60 total
Error rate:   < 1%
Latency p50:  5-10s
Latency p95:  15-25s
Latency p99:  20-35s
Throughput:   ~5-10 tokens/sec (across both users combined)
GPU util:     70-90%
VRAM used:    ~15-17 GB
```

### Stress Test (peak: 12 VUs)
```
At 4 VUs:     Queue starts growing
At 8 VUs:     ~20-30% error rate (429 / queue full)
At 12 VUs:    ~40-60% error rate, possible OOM restarts
Recovery:     Returns to baseline within 30-60s after scale-down
```

### Failover Test
```
Phase 1 (both up):   Chicago ~50%, Seattle ~50% of requests
Phase 2 (CHI down):  100% → Seattle, x-fallback: true
Phase 3 (recovery):  Normal distribution resumes
Error during failover: < 10% (brief window during health check detection)
```

## Saving Test Results

```bash
# Save to JSON for analysis
k6 run --env BASE_URL=http://${CHICAGO_IP}:8000 \
  --out json=k6/results/load-$(date +%Y%m%d-%H%M%S).json \
  k6/load.js

# HTML report (requires k6 reporter)
k6 run --env BASE_URL=http://${CHICAGO_IP}:8000 \
  --out csv=k6/results/load.csv \
  k6/load.js
```

## Watching GPU During Tests

Open a second terminal and watch GPU metrics:
```bash
# Real-time GPU metrics
watch -n2 kubectl exec -it \
  $(kubectl get pod -n inference --context=chicago -l app=vllm -o jsonpath='{.items[0].metadata.name}') \
  -n inference --context=chicago \
  -- nvidia-smi --query-gpu=utilization.gpu,memory.used,temperature.gpu,power.draw \
  --format=csv,noheader

# Or watch Prometheus metrics
watch -n5 curl -s "http://${PROM_IP}:9090/api/v1/query?query=DCGM_FI_DEV_GPU_UTIL" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['result'][0]['value'][1],'%')"
```

## GPU Saturation Point

Based on Mistral-7B on RTX 4000 Ada:
- **1-2 concurrent requests:** GPU at 70-90%, best latency
- **3-4 concurrent requests:** GPU at ~100%, latency increases 2-3x
- **5+ concurrent requests:** Queue builds up, vLLM throttles via `MAX_NUM_SEQS`

Recommended production config: max 2-3 concurrent users per GPU node.
