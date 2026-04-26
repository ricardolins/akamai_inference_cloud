# Multi-Region Routing

## Router Architecture

Two router implementations, same logic:

| Router | Technology | Where it runs | Use when |
|---|---|---|---|
| Fermyon Spin | WebAssembly (TypeScript) | Local / Fermyon Cloud | Primary |
| Node.js Fallback | Node.js 20 | Kubernetes (inference ns) | Spin unavailable |

## Routing Logic

```
Client Request
  ↓
1. IP check → 403 if not in allowed_admin_cidr
  ↓
2. Health checks (concurrent, 5s timeout)
   ├── GET http://CHICAGO-IP:8000/health
   └── GET http://SEATTLE-IP:8000/health
  ↓
3. Region selection:
   ├── Both healthy    → Round-robin (alternates per second)
   ├── Chicago down    → Seattle (x-fallback: true)
   ├── Seattle down    → Chicago (x-fallback: true)
   └── Both down       → 503 Service Unavailable
  ↓
4. Proxy request to selected region
   ├── Forward all headers + body
   ├── Add x-region: chicago|seattle
   ├── Add x-fallback: true|false
   └── Add x-router: akai-spin-fermyon|akai-inference-nodejs
  ↓
5. If proxy fails → emergency fallback to other region
  ↓
6. Return response to client
```

## Response Headers

Every proxied response includes:

| Header | Values | Description |
|---|---|---|
| `x-region` | chicago \| seattle | Region that served the request |
| `x-fallback` | true \| false | Whether failover was used |
| `x-router` | akai-spin-fermyon \| akai-inference-nodejs | Which router handled it |

## Fermyon Spin Router

### Local testing
```bash
cd fermyon
cp variables.example.toml variables.toml
# Edit variables.toml with your vLLM IPs

spin build
spin up --runtime-config-file variables.toml
# Router available at http://localhost:3000
```

### Deploy to Fermyon Cloud
```bash
spin deploy \
  --variable chicago_vllm_url="http://CHICAGO-IP:8000" \
  --variable seattle_vllm_url="http://SEATTLE-IP:8000" \
  --variable allowed_admin_cidr="YOUR_IP/32"
```

### Test Fermyon router
```bash
# Health
curl http://localhost:3000/health

# Status (shows both regions)
curl http://localhost:3000/status | python3 -m json.tool

# Inference via router
curl http://localhost:3000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mistralai/Mistral-7B-Instruct-v0.3","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}'

# Check which region served it
curl -D - http://localhost:3000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mistralai/Mistral-7B-Instruct-v0.3","messages":[{"role":"user","content":"Hi"}],"max_tokens":10}' \
  | grep -i "x-region"
```

## Node.js Fallback Router

### Run locally
```bash
cd router
CHICAGO_VLLM_URL=http://CHICAGO-IP:8000 \
SEATTLE_VLLM_URL=http://SEATTLE-IP:8000 \
ALLOWED_ADMIN_CIDR=YOUR_IP/32 \
node src/index.js
```

### Run in Kubernetes
Deployed automatically by `deploy-all.sh` to the `inference` namespace.

```bash
# Get router IP
kubectl get svc inference-router -n inference --context=chicago

# Test
ROUTER_IP=$(kubectl get svc inference-router -n inference --context=chicago \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

curl http://${ROUTER_IP}:8080/status
```

## Failover Testing

```bash
make test-failover
# or
bash scripts/test-routing.sh
```

Manual failover test:
```bash
# 1. Stop Chicago vLLM
kubectl scale deployment vllm --replicas=0 -n inference --context=chicago

# 2. Wait for health checks (10-15s)
sleep 15

# 3. Send requests — should all go to Seattle
curl -D - http://ROUTER-IP:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"mistralai/Mistral-7B-Instruct-v0.3","messages":[{"role":"user","content":"test"}],"max_tokens":10}'

# Check headers: x-region: seattle, x-fallback: true

# 4. Restore Chicago
kubectl scale deployment vllm --replicas=1 -n inference --context=chicago
```

## Routing Limitations

### Round-robin is approximate
Fermyon Spin components are stateless — no shared memory between requests. Round-robin is approximated by alternating based on the current second. For true weighted load balancing, consider an external proxy (Nginx, Envoy) in front of the Spin app.

### Health check adds latency
Every request performs 2 concurrent health checks before routing. This adds ~5-50ms depending on network latency to the inference regions. For maximum performance, implement a background health cache (available in Node.js router but not in stateless Spin).

The Node.js fallback router uses a background health check interval (10 seconds by default) — no per-request health overhead.
