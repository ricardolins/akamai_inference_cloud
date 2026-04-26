# Inference Runtime — vLLM on RTX 4000 Ada

## Why vLLM

- OpenAI-compatible API (`/v1/chat/completions`, `/v1/completions`, `/v1/models`)
- PagedAttention: most efficient KV cache management for GPU memory
- Continuous batching: processes multiple requests concurrently
- Best-in-class throughput for single-GPU setups
- Native streaming (SSE)

## Model Choice — Mistral-7B-Instruct-v0.3

| Property | Value |
|---|---|
| Parameters | 7 billion |
| License | Apache 2.0 (commercial use OK) |
| VRAM (FP16) | ~14 GB |
| Context window | 32k (using 4096 for safety) |
| Throughput on RTX 4000 Ada | ~25-40 tokens/sec |
| Source | https://huggingface.co/mistralai/Mistral-7B-Instruct-v0.3 |

### Why this model fits the RTX 4000 Ada (20GB)

```
Model weights (FP16):  7B × 2 bytes  = ~14 GB
KV cache (4096 ctx):   variable       = ~2-4 GB (depending on batch size)
CUDA overhead:                         ~0.5 GB
Total used:                           ~16-18 GB
Available headroom:                    ~2-4 GB

gpu_memory_utilization = 0.90 → 18GB budget → safe with ~2GB margin
```

## Alternative Models (all fit in 20GB)

| Model | VRAM | License | Tokens/sec | Quality |
|---|---|---|---|---|
| `mistralai/Mistral-7B-Instruct-v0.3` | ~14GB FP16 | Apache 2.0 | 25-40 | ★★★★☆ |
| `microsoft/Phi-3-mini-4k-instruct` | ~7GB | MIT | 40-60 | ★★★☆☆ |
| `TinyLlama/TinyLlama-1.1B-Chat-v1.0` | ~2GB | Apache 2.0 | 80-120 | ★★☆☆☆ |
| `Qwen/Qwen2-7B-Instruct` | ~14GB FP16 | Apache 2.0 | 25-40 | ★★★★☆ |
| `google/gemma-7b-it` | ~14GB FP16 | Gemma ToS | 25-40 | ★★★★☆ |
| `mistralai/Mistral-7B-v0.3-AWQ` | ~4GB AWQ | Apache 2.0 | 45-70 | ★★★☆☆ |

**DO NOT try on 20GB (will OOM):**
- Llama 3.1 70B (requires ~140GB)
- Llama 3.1 13B (requires ~26GB FP16)
- Mixtral 8x7B (requires ~90GB)

## Changing the Model

1. Edit `kubernetes/vllm/configmap.yaml`:
   ```yaml
   MODEL_NAME: "microsoft/Phi-3-mini-4k-instruct"
   MAX_MODEL_LEN: "4096"
   GPU_MEMORY_UTILIZATION: "0.90"
   ```

2. Rolling restart:
   ```bash
   kubectl rollout restart deployment/vllm -n inference --context=chicago
   kubectl rollout status deployment/vllm -n inference --context=chicago
   ```

3. Monitor model download:
   ```bash
   kubectl logs -f -l app=vllm -n inference --context=chicago
   ```

## API Endpoints

### Chat Completions (primary)
```bash
curl http://<IP>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mistralai/Mistral-7B-Instruct-v0.3",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Explain GPU inference in 2 sentences."}
    ],
    "max_tokens": 200,
    "temperature": 0.7
  }'
```

### Streaming response (SSE)
```bash
curl http://<IP>:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mistralai/Mistral-7B-Instruct-v0.3","messages":[{"role":"user","content":"Count to 10"}],"max_tokens":100,"stream":true}'
```

### List models
```bash
curl http://<IP>:8000/v1/models
```

### Health check
```bash
curl http://<IP>:8000/health
```

### Metrics (Prometheus format)
```bash
curl http://<IP>:8000/metrics
```

## vLLM Prometheus Metrics

Key metrics scraped from `/metrics`:

| Metric | Type | Description |
|---|---|---|
| `vllm:request_success_total` | Counter | Successful requests |
| `vllm:request_failure_total` | Counter | Failed requests |
| `vllm:time_to_first_token_seconds` | Histogram | Time to first token (TTFT) |
| `vllm:e2e_request_latency_seconds` | Histogram | End-to-end latency |
| `vllm:generation_tokens_total` | Counter | Total tokens generated |
| `vllm:prompt_tokens_total` | Counter | Total prompt tokens processed |
| `vllm:num_requests_running` | Gauge | Currently running requests |
| `vllm:num_requests_waiting` | Gauge | Requests in queue |
| `vllm:gpu_cache_usage_perc` | Gauge | KV cache GPU utilization |
| `vllm:cpu_cache_usage_perc` | Gauge | KV cache CPU swap utilization |

## OOM Risk Mitigation

The RTX 4000 Ada has 20GB. If you hit OOM:

1. **Reduce `MAX_MODEL_LEN`** — from 4096 to 2048
2. **Reduce `MAX_NUM_SEQS`** — from 16 to 8 (fewer concurrent requests)
3. **Reduce `GPU_MEMORY_UTILIZATION`** — from 0.90 to 0.85
4. **Use AWQ quantization** — `QUANTIZATION: "awq"` (cuts VRAM by ~4x)
5. **Switch to smaller model** — Phi-3-mini uses only 7GB

If you see `CUDA out of memory` in logs:
```bash
kubectl logs -l app=vllm -n inference --context=chicago | grep -i "out of memory"
```

Restart the pod:
```bash
kubectl rollout restart deployment/vllm -n inference --context=chicago
```
