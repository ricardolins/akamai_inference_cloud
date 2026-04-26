# NVIDIA Stack — GPU Operator + DCGM

## Component Stack

```
┌─────────────────────────────────────────────────────────────────┐
│ Kubernetes Node (LKE — Ubuntu 22.04)                            │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │ NVIDIA GPU Operator (Kubernetes Operator)                │   │
│  │   Manages lifecycle of all GPU software components       │   │
│  └──────────────────────────────────────────────────────────┘   │
│                            │                                    │
│  ┌─────────────┐  ┌────────────────┐  ┌──────────────────────┐  │
│  │ NVIDIA      │  │ Container      │  │ Device Plugin        │  │
│  │ Driver      │  │ Toolkit        │  │ (nvidia.com/gpu)     │  │
│  │ DaemonSet   │  │ DaemonSet      │  │ DaemonSet            │  │
│  └─────────────┘  └────────────────┘  └──────────────────────┘  │
│                                                                 │
│  ┌──────────────────────┐  ┌───────────────────────────────┐    │
│  │ DCGM                 │  │ GPU Feature Discovery (GFD)   │    │
│  │ (health + metrics)   │  │ (node labels)                 │    │
│  └──────────────────────┘  └───────────────────────────────┘    │
│                                                                 │
│  ┌──────────────────────────────────────┐                       │
│  │ DCGM Exporter (port 9400)            │ ← Prometheus scrapes  │
│  │ Prometheus metrics /metrics          │                       │
│  └──────────────────────────────────────┘                       │
└─────────────────────────────────────────────────────────────────┘
```

## Installation Order

The GPU Operator handles all of this automatically. Manual order for reference:

1. **Node Feature Discovery (NFD)** — detects hardware
2. **NVIDIA Driver** — installs kernel module + CUDA runtime
3. **Container Toolkit** — configures containerd for GPU access
4. **Device Plugin** — exposes `nvidia.com/gpu` resource
5. **DCGM** — GPU health monitoring daemon
6. **DCGM Exporter** — Prometheus metrics endpoint
7. **GPU Feature Discovery** — detailed node labels

## Key Node Labels Applied by GFD

After GPU Operator succeeds:
```
nvidia.com/gpu.present=true
nvidia.com/gpu.deploy.driver=true
nvidia.com/gpu.deploy.container-toolkit=true
nvidia.com/gpu.deploy.device-plugin=true
nvidia.com/gpu.deploy.dcgm=true
nvidia.com/gpu.deploy.dcgm-exporter=true
nvidia.com/gpu.count=1
nvidia.com/gpu.memory=20480                    # 20GB VRAM
nvidia.com/gpu.product=NVIDIA-RTX-4000-Ada-Generation
nvidia.com/gpu.family=ada
nvidia.com/cuda.driver-version=535.154.05
nvidia.com/cuda.runtime-version=12.2.0
```

## DCGM Exporter — Scrape Config

DCGM Exporter runs on port 9400 and exposes metrics at `/metrics`.

ServiceMonitor (created by GPU Operator) auto-discovers it for Prometheus.

Manual scrape test:
```bash
DCGM_POD=$(kubectl get pod -n gpu-operator --context=chicago \
  -l app=nvidia-dcgm-exporter -o jsonpath='{.items[0].metadata.name}')

kubectl exec "${DCGM_POD}" -n gpu-operator --context=chicago \
  -- curl -s http://localhost:9400/metrics | grep "^DCGM_FI_DEV" | head -20
```

## Validate Full Stack

```bash
# 1. GPU Operator operator pod
kubectl get pod -n gpu-operator --context=chicago -l app=gpu-operator

# 2. Driver DaemonSet (should be Running on all GPU nodes)
kubectl get ds -n gpu-operator --context=chicago nvidia-driver-daemonset

# 3. Device Plugin DaemonSet
kubectl get ds -n gpu-operator --context=chicago nvidia-device-plugin-daemonset

# 4. DCGM Exporter DaemonSet
kubectl get ds -n gpu-operator --context=chicago nvidia-dcgm-exporter

# 5. GPU allocatable
kubectl get nodes --context=chicago \
  -o custom-columns="NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu"

# 6. Run CUDA sample to verify end-to-end
kubectl apply -f - --context=chicago << 'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cuda-vector-add
  namespace: default
spec:
  restartPolicy: OnFailure
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
  containers:
    - name: cuda-vector-add
      image: "nvcr.io/nvidia/k8s/cuda-sample:vectoradd-cuda12.3.0"
      resources:
        limits:
          nvidia.com/gpu: 1
EOF

kubectl wait --for=condition=Complete pod/cuda-vector-add --timeout=120s --context=chicago
kubectl logs cuda-vector-add --context=chicago
# Expected: "Test PASSED"
kubectl delete pod cuda-vector-add --context=chicago
```
