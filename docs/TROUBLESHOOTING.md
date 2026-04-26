# Troubleshooting

## GPU Not Available

**Symptom:** `kubectl describe node` shows `nvidia.com/gpu: 0` or label missing.

**Steps:**
```bash
# 1. Check GPU Operator pods
kubectl get pods -n gpu-operator --context=chicago

# 2. If nvidia-driver-daemonset is Pending or CrashLoopBackOff:
kubectl logs -n gpu-operator -l app=nvidia-driver-daemonset --context=chicago --tail=50

# 3. Driver compilation takes 5-10 min on first boot. Check age:
kubectl get pods -n gpu-operator --context=chicago
# If pods are < 10min old, wait.

# 4. If driver pod fails with kernel header error:
# LKE nodes use Ubuntu — driver should compile fine. If not, check kernel version:
kubectl debug node/$(kubectl get node --context=chicago -o jsonpath='{.items[0].metadata.name}') \
  -it --image=ubuntu -- uname -r
```

## vLLM Pod Stuck in Init

**Symptom:** vLLM pod stays in `Init:0/1` state.

**Cause:** The initContainer waits for `nvidia.com/gpu` to be allocatable (GPU Operator not ready yet).

```bash
kubectl describe pod -l app=vllm -n inference --context=chicago | grep -A20 "Init Containers"
# Wait for GPU Operator to finish (~10 min)
```

## vLLM OOM — CUDA out of memory

**Symptom:** `CUDA out of memory` in vLLM logs. Pod restarts.

```bash
kubectl logs -l app=vllm -n inference --context=chicago | grep -i "out of memory"
```

**Fix options (in order of impact):**
1. Reduce `MAX_MODEL_LEN` from 4096 to 2048
2. Reduce `MAX_NUM_SEQS` from 16 to 4
3. Reduce `GPU_MEMORY_UTILIZATION` from 0.90 to 0.80
4. Switch to AWQ quantized model (`mistralai/Mistral-7B-v0.3-AWQ`)

```bash
kubectl edit configmap vllm-config -n inference --context=chicago
# Change values, then:
kubectl rollout restart deployment/vllm -n inference --context=chicago
```

## vLLM Model Download Fails

**Symptom:** vLLM logs show `401 Unauthorized` or `404 Not Found` from HuggingFace.

```bash
kubectl logs -l app=vllm -n inference --context=chicago | grep -i "huggingface\|404\|401"
```

**Fix:**
- For gated models (Llama 3): create HF token secret
  ```bash
  kubectl create secret generic hf-secret \
    --from-literal=token=hf_YOUR_TOKEN \
    -n inference --context=chicago
  ```
- For public models (Mistral 7B): no token needed. Check network connectivity.

## LoadBalancer IP Stuck as `<pending>`

**Symptom:** `kubectl get svc` shows `EXTERNAL-IP: <pending>` for minutes.

```bash
# Check NodeBalancer events
kubectl describe svc vllm -n inference --context=chicago | grep -A20 "Events:"
```

**Common causes:**
- Linode API quota exceeded (contact support)
- Node not yet healthy (check `kubectl get nodes --context=chicago`)
- IP restrictions conflict in LKE networking

**Fix:**
```bash
# Force reconciliation
kubectl delete svc vllm -n inference --context=chicago
kubectl apply -f kubernetes/vllm/service.yaml --context=chicago
# Wait 2-3 minutes
```

## Can't Access Service from My IP

**Symptom:** Connection timeout or refused from your machine.

**Checklist:**
1. Verify your current IP:
   ```bash
   curl -s https://api.ipify.org
   ```
2. Check it matches `allowed_admin_cidr` in `terraform.tfvars`
3. Check Cloud Firewall in Linode UI: https://cloud.linode.com/firewalls
4. Verify `loadBalancerSourceRanges` on the service:
   ```bash
   kubectl get svc vllm -n inference --context=chicago \
     -o jsonpath='{.spec.loadBalancerSourceRanges}'
   ```
5. If IP changed: update `terraform.tfvars` and run `make terraform-apply && make deploy-all`

## Grafana Datasource Error

**Symptom:** Grafana shows `Error: No data` or `Datasource connection error`.

```bash
# Check Prometheus URL in Grafana values
kubectl get cm grafana -n monitoring --context=chicago -o yaml | grep prometheus

# Verify Prometheus is running
kubectl get pods -n monitoring --context=chicago | grep prometheus
```

The Grafana datasource uses the cluster-internal service name:
`http://prometheus-kube-prometheus-prometheus.monitoring.svc:9090`

This is correct for in-cluster access. If you changed the Helm release name, update accordingly.

## kubectl Context Not Found

**Symptom:** `error: no context exists with the name "chicago"`

```bash
export KUBECONFIG=./kubeconfig-chicago.yaml:./kubeconfig-seattle.yaml
kubectl config get-contexts
# If context is named differently, rename it:
kubectl config rename-context <current-name> chicago --kubeconfig=./kubeconfig-chicago.yaml
```

## Terraform Error: GPU Plan Not Found

**Symptom:** `Error: Invalid plan_id` during `terraform apply`.

```bash
# List available GPU plans
linode-cli linodes types --json | python3 -c "
import sys, json
for t in json.load(sys.stdin):
    if t.get('class') == 'gpu':
        print(t['id'])
"
```

Update `gpu_node_type` in `terraform.tfvars` with the correct plan ID.

## Spin Build Fails

**Symptom:** `spin build` returns WebAssembly compile error.

```bash
cd fermyon
npm install
# Check TypeScript errors
npx tsc --noEmit

# If JS2Wasm target missing:
spin plugins update
spin plugins install js2wasm
```

## Slow Inference (>60s for short prompts)

**Expected:** RTX 4000 Ada should generate 25-40 tokens/sec.

If much slower:
1. Check GPU is actually being used:
   ```bash
   kubectl exec -it -l app=vllm -n inference --context=chicago \
     -- nvidia-smi dmon -s u
   # GPU utilization should spike to 80-100% during inference
   ```
2. Check if running on CPU fallback (should never happen with correct GPU Operator setup):
   ```bash
   kubectl logs -l app=vllm -n inference --context=chicago | grep "device"
   # Should show: Using CUDA device
   ```
3. Check for KV cache swapping to CPU:
   ```bash
   # vllm:cpu_cache_usage_perc > 0 means CPU swapping (slow)
   curl http://<PROMETHEUS-IP>:9090/api/v1/query?query=vllm:cpu_cache_usage_perc
   ```
