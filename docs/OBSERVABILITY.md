# Observability — Prometheus + Grafana + DCGM

## Stack

```
RTX 4000 Ada
  → DCGM (Data Center GPU Manager)
      → DCGM Exporter (port 9400, /metrics)
          → Prometheus ServiceMonitor
              → Prometheus (port 9090)
                  → Grafana (port 3000)

vLLM
  → /metrics (port 8000)
      → Prometheus pod annotation scrape
          → Prometheus
              → Grafana
```

## Accessing Prometheus

```bash
PROM_IP=$(kubectl get svc prometheus-kube-prometheus-prometheus \
  -n monitoring --context=chicago \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# UI
http://${PROM_IP}:9090

# API query example
curl "http://${PROM_IP}:9090/api/v1/query?query=DCGM_FI_DEV_GPU_UTIL"
```

## Accessing Grafana

```bash
GRAFANA_IP=$(kubectl get svc grafana -n monitoring --context=chicago \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

http://${GRAFANA_IP}:3000
# Default credentials: admin / admin (change on first login)
```

## Pre-installed Dashboards

| Dashboard | ID | Description |
|---|---|---|
| Akamai GPU + vLLM | akai-gpu-vllm-001 | Custom — GPU metrics + vLLM latency |
| NVIDIA DCGM Exporter | 12239 | Official NVIDIA dashboard |
| Kubernetes Cluster | 7249 | Cluster resource overview |
| Node Exporter Full | 1860 | Node CPU/memory/disk/network |

## Key GPU Metrics (DCGM)

```promql
# GPU Utilization (%)
DCGM_FI_DEV_GPU_UTIL

# VRAM Used (MB)
DCGM_FI_DEV_FB_USED

# VRAM Free (MB)
DCGM_FI_DEV_FB_FREE

# GPU Temperature (°C)
DCGM_FI_DEV_GPU_TEMP

# Power Usage (W)
DCGM_FI_DEV_POWER_USAGE

# Memory Bandwidth Utilization (%)
DCGM_FI_DEV_MEM_COPY_UTIL

# SM Clock (MHz)
DCGM_FI_DEV_SM_CLOCK

# Memory Clock (MHz)
DCGM_FI_DEV_MEM_CLOCK
```

## Key vLLM Metrics

```promql
# Requests per second (success)
rate(vllm:request_success_total[1m])

# Time to First Token — p50, p95, p99
histogram_quantile(0.50, rate(vllm:time_to_first_token_seconds_bucket[5m]))
histogram_quantile(0.95, rate(vllm:time_to_first_token_seconds_bucket[5m]))
histogram_quantile(0.99, rate(vllm:time_to_first_token_seconds_bucket[5m]))

# End-to-end latency p95
histogram_quantile(0.95, rate(vllm:e2e_request_latency_seconds_bucket[5m]))

# Token throughput
rate(vllm:generation_tokens_total[1m])

# Queue depth
vllm:num_requests_waiting

# Running requests
vllm:num_requests_running

# KV Cache utilization
vllm:gpu_cache_usage_perc * 100
```

## Useful Grafana Panels to Create

### GPU Inference Performance Panel
```promql
# Tokens/second normalized by GPU utilization
rate(vllm:generation_tokens_total[1m]) / (DCGM_FI_DEV_GPU_UTIL / 100)
```

### GPU Efficiency Panel
```promql
# VRAM efficiency: tokens generated per MB of VRAM used
rate(vllm:generation_tokens_total[1m]) / DCGM_FI_DEV_FB_USED
```

### Thermal headroom
```promql
# How far from the 85°C thermal limit
85 - DCGM_FI_DEV_GPU_TEMP
```

## Alert Rules (add to Prometheus)

```yaml
# Add to kubernetes/monitoring/prometheus-values.yaml under additionalPrometheusRulesMap
additionalPrometheusRulesMap:
  akai-inference:
    groups:
      - name: gpu.rules
        rules:
          - alert: GPUHighTemperature
            expr: DCGM_FI_DEV_GPU_TEMP > 85
            for: 2m
            labels:
              severity: warning
            annotations:
              summary: "GPU temperature above 85°C (current: {{ $value }}°C)"

          - alert: GPUOOMRisk
            expr: DCGM_FI_DEV_FB_FREE < 1024
            for: 1m
            labels:
              severity: critical
            annotations:
              summary: "GPU VRAM < 1GB free — OOM risk"

          - alert: vLLMHighQueueDepth
            expr: vllm:num_requests_waiting > 10
            for: 2m
            labels:
              severity: warning
            annotations:
              summary: "vLLM queue depth {{ $value }} — requests backing up"

          - alert: vLLMHighErrorRate
            expr: rate(vllm:request_failure_total[5m]) / rate(vllm:request_success_total[5m]) > 0.05
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "vLLM error rate above 5%"
```
