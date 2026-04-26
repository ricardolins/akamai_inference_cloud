# GPU Setup — RTX 4000 Ada on LKE

## Hardware Specs — NVIDIA RTX 4000 Ada

| Spec | Value |
|---|---|
| Architecture | Ada Lovelace |
| CUDA Cores | 6144 |
| VRAM | 20 GB GDDR6 |
| Memory Bandwidth | 360 GB/s |
| TDP | 130W |
| CUDA Compute Capability | 8.9 |
| NVLink | No |
| MIG | No |
| FP16 Performance | ~26.7 TFLOPS |
| FP32 Performance | ~26.7 TFLOPS |

## Linode GPU Plan

The RTX 4000 Ada instances on Akamai Cloud:

```bash
# List GPU plans
linode-cli linodes types --json | python3 -c "
import sys, json
plans = json.load(sys.stdin)
for p in plans:
    if p.get('class') == 'gpu':
        print(p['id'], '|', p.get('label'), '|', p.get('vcpus'), 'vCPU |',
              p.get('memory')//1024, 'GB RAM |', p.get('disk')//1024, 'GB disk |',
              '\$'+str(p.get('price',{}).get('hourly',0)*730)+'/mo')
"
```

## NVIDIA GPU Operator — What It Does

The GPU Operator is a Kubernetes operator that automates:

```
1. NVIDIA Driver installation (DaemonSet on GPU nodes)
      ↓
2. Container Toolkit (nvidia-container-toolkit DaemonSet)
      ↓
3. CUDA libraries + runtime configuration for containerd
      ↓
4. Device Plugin (exposes nvidia.com/gpu resource)
      ↓
5. Node Feature Discovery (labels: nvidia.com/gpu.present=true)
      ↓
6. DCGM + DCGM Exporter (GPU metrics for Prometheus)
      ↓
7. GPU Feature Discovery (detailed GPU capability labels)
```

## Validating GPU After Deployment

### 1. Node labels
```bash
kubectl get nodes --context=chicago -o json | python3 -c "
import sys, json
nodes = json.load(sys.stdin)['items']
for n in nodes:
    labels = {k:v for k,v in n['metadata']['labels'].items() if 'nvidia' in k or 'gpu' in k}
    print(n['metadata']['name'])
    for k,v in labels.items():
        print(f'  {k}={v}')
"
```

Expected labels:
- `nvidia.com/gpu.present=true`
- `nvidia.com/gpu.deploy.driver=true`
- `nvidia.com/cuda.driver-version=<version>`
- `nvidia.com/gpu.product=NVIDIA-RTX-4000-Ada-Generation`

### 2. Allocatable resources
```bash
kubectl describe node --context=chicago | grep -A5 "Allocatable:"
# Should show: nvidia.com/gpu: 1
```

### 3. GPU Operator pods
```bash
kubectl get pods -n gpu-operator --context=chicago
```

Expected pods:
```
NAME                                           STATUS
gpu-operator-xxx                               Running
nvidia-driver-daemonset-xxx                    Running
nvidia-container-toolkit-daemonset-xxx         Running
nvidia-device-plugin-daemonset-xxx             Running
nvidia-dcgm-xxx                                Running
nvidia-dcgm-exporter-xxx                       Running
gpu-feature-discovery-xxx                      Running
node-feature-discovery-worker-xxx              Running
```

### 4. nvidia-smi inside a pod
```bash
# Run nvidia-smi in vLLM pod
kubectl exec -it \
  $(kubectl get pod -n inference --context=chicago -l app=vllm -o jsonpath='{.items[0].metadata.name}') \
  -n inference --context=chicago \
  -- nvidia-smi

# Run nvidia-smi in a dedicated test pod
kubectl run gpu-test --image=nvidia/cuda:12.3.0-base-ubuntu22.04 \
  --restart=Never --context=chicago \
  --overrides='{"spec":{"tolerations":[{"key":"nvidia.com/gpu","operator":"Exists"}],"containers":[{"name":"gpu-test","image":"nvidia/cuda:12.3.0-base-ubuntu22.04","resources":{"limits":{"nvidia.com/gpu":"1"}},"command":["nvidia-smi"]}]}}' \
  -- nvidia-smi

kubectl logs gpu-test --context=chicago
kubectl delete pod gpu-test --context=chicago
```

## Driver Version

RTX 4000 Ada (Ada Lovelace, compute capability 8.9) requires:
- CUDA >= 11.8
- Driver >= 520 (recommended: 535.x for stability)

The GPU Operator installs driver `535.154.05` as configured in `kubernetes/gpu-operator/values.yaml`.

## Troubleshooting GPU Not Detected

```bash
# Check GPU Operator logs
kubectl logs -n gpu-operator -l app=gpu-operator --context=chicago

# Check driver installation
kubectl logs -n gpu-operator -l app=nvidia-driver-daemonset --context=chicago

# Check device plugin
kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset --context=chicago

# Full diagnostics
kubectl describe node --context=chicago | grep -A20 "Conditions:"
```

Common issues:
- Driver build takes 5-10 minutes on first boot
- `Unknown` GPU status = driver still compiling
- `ImagePullBackOff` = cannot pull NVIDIA container images (check network)
