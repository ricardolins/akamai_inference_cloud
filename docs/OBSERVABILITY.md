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

## Demo: Métricas ao Vivo com Prometheus

Roteiro passo a passo para demonstrar observabilidade end-to-end durante o demo.

### 1. Acesso ao Prometheus (port-forward)

Prometheus usa NodePort — sem IP externo dedicado. Use port-forward local:

```bash
# Chicago
kubectl --kubeconfig=kubeconfig-chicago.yaml \
  port-forward -n monitoring \
  svc/prometheus-kube-prometheus-prometheus 9090:9090

# Seattle
kubectl --kubeconfig=kubeconfig-seattle.yaml \
  port-forward -n monitoring \
  svc/prometheus-kube-prometheus-prometheus 9091:9090
```

Acesse em `http://localhost:9090` (Chicago) e `http://localhost:9091` (Seattle).

---

### 2. Verificar targets ativos

No Prometheus UI → **Status → Targets**, ou via API:

```bash
curl -s http://localhost:9090/api/v1/targets | \
  python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data['data']['activeTargets']:
    print(t['health'], t['labels'].get('job','?'))
"
```

Targets esperados ativos (`up`):

| Job | O que coleta |
|-----|-------------|
| `vllm` | Latência, throughput, filas de inferência |
| `nvidia-dcgm-exporter` | GPU util, VRAM, temperatura, power |
| `node-exporter` | CPU, memória, disco, rede do nó |
| `kubelet` | Métricas do runtime Kubernetes |
| `kube-state-metrics` | Estado dos recursos (pods, deployments) |
| `apiserver` | API server do cluster |

> **Nota:** `kube-proxy` aparece como DOWN — esperado no LKE (porta 10249 fechada). Sem impacto funcional.

---

### 3. Warm-up: enviar requests de inferência

As métricas de latência e throughput do vLLM só aparecem após requisições. Envie um burst de teste:

```bash
# Via Fermyon router (multi-região)
ROUTER="https://17f18a23-dee8-456c-b825-7929f04c04ca.fwf.app"

for i in $(seq 1 10); do
  curl -s -X POST "$ROUTER/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"mistralai/Mistral-7B-Instruct-v0.3\",
         \"messages\":[{\"role\":\"user\",\"content\":\"Explique GPU inference em uma frase\"}],
         \"max_tokens\":50}" \
    -o /dev/null &
done
wait
echo "Burst concluído"

# Ou direto no Chicago
for i in $(seq 1 10); do
  curl -s -X POST "http://172.238.162.106:8000/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"mistralai/Mistral-7B-Instruct-v0.3\",
         \"messages\":[{\"role\":\"user\",\"content\":\"What is GPU inference?\"}],
         \"max_tokens\":30}" \
    -o /dev/null &
done
wait
```

---

### 4. Queries de demo — copie e cole no Prometheus UI

#### Latência de inferência (TTFT p50 / p95 / p99)

```promql
# Time to First Token — p50
histogram_quantile(0.50, rate(vllm:time_to_first_token_seconds_bucket[5m]))

# p95
histogram_quantile(0.95, rate(vllm:time_to_first_token_seconds_bucket[5m]))

# p99
histogram_quantile(0.99, rate(vllm:time_to_first_token_seconds_bucket[5m]))
```

Valores de referência observados (RTX 4000 Ada, Mistral 7B FP16):

| Percentil | Valor típico |
|-----------|-------------|
| p50 | ~56 ms |
| p95 | ~80 ms |
| p99 | ~120 ms |

#### Throughput de tokens

```promql
# Tokens gerados por segundo
rate(vllm:generation_tokens_total[1m])

# Tokens de prompt por segundo
rate(vllm:prompt_tokens_total[1m])
```

#### Latência end-to-end

```promql
# Latência média da requisição completa
rate(vllm:e2e_request_latency_seconds_sum[1m])
/ rate(vllm:e2e_request_latency_seconds_count[1m])

# p95
histogram_quantile(0.95, rate(vllm:e2e_request_latency_seconds_bucket[5m]))
```

Valor de referência: ~234 ms para `max_tokens=5`.

#### Estado da fila e concorrência

```promql
# Requests aguardando na fila
vllm:num_requests_waiting

# Requests sendo processados agora
vllm:num_requests_running

# KV Cache utilization (%)
vllm:gpu_cache_usage_perc * 100
```

#### GPU — RTX 4000 Ada (20GB VRAM)

```promql
# Utilização da GPU (%)
DCGM_FI_DEV_GPU_UTIL

# VRAM usada (GB)
DCGM_FI_DEV_FB_USED / 1024

# VRAM livre (GB)
DCGM_FI_DEV_FB_FREE / 1024

# Temperatura (°C) — limite térmico: 85°C
DCGM_FI_DEV_GPU_TEMP

# Power draw (W) — TDP: 130W
DCGM_FI_DEV_POWER_USAGE
```

#### Eficiência GPU

```promql
# Tokens/s por % de utilização GPU
rate(vllm:generation_tokens_total[1m]) / (DCGM_FI_DEV_GPU_UTIL / 100)

# Headroom térmico até o limite de 85°C
85 - DCGM_FI_DEV_GPU_TEMP
```

---

### 5. Demo multi-região side-by-side

Com os dois port-forwards ativos (9090 = Chicago, 9091 = Seattle), abra dois terminais e compare:

```bash
# Chicago
curl -s "http://localhost:9090/api/v1/query" \
  --data-urlencode 'query=DCGM_FI_DEV_GPU_UTIL' | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print('Chicago GPU:', d['data']['result'][0]['value'][1], '%')"

# Seattle
curl -s "http://localhost:9091/api/v1/query" \
  --data-urlencode 'query=DCGM_FI_DEV_GPU_UTIL' | \
  python3 -c "import sys,json; d=json.load(sys.stdin); print('Seattle GPU:', d['data']['result'][0]['value'][1], '%')"
```

---

### 6. Contexto para a audiência

Durante o demo, os pontos de narrativa:

- **TTFT < 100ms** — viável para aplicações interativas em tempo real
- **GPU util durante inferência** — demonstra que a carga de trabalho realmente usa a GPU (não CPU fallback)
- **VRAM: ~14GB usados dos 20GB disponíveis** — Mistral 7B FP16 ocupa 13.5GB de pesos + buffers KV cache
- **Temperatura estável** — workloads de inferência são mais previsíveis que training, temperatura permanece abaixo de 80°C
- **Multi-região**: latências similares em Chicago e Seattle validam que o modelo foi carregado corretamente nas duas regiões

---

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
