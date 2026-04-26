#!/usr/bin/env bash
# =============================================================================
# validate-gpu.sh — Validates GPU availability in both LKE clusters
#
# Checks:
#   1. Node labels show nvidia.com/gpu.present=true
#   2. nvidia.com/gpu resource is allocatable
#   3. GPU Operator pods are running
#   4. DCGM Exporter is running and returning metrics
#   5. vLLM pod is using the GPU (nvidia-smi inside pod)
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}→${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
error()   { echo -e "${RED}✗${NC} $*"; }
PASS=0; FAIL=0

check() {
  local label="$1"; shift
  if "$@" &>/dev/null; then
    success "${label}"
    ((PASS++))
  else
    error "${label}"
    ((FAIL++))
  fi
}

export KUBECONFIG="${ROOT_DIR}/kubeconfig-chicago.yaml:${ROOT_DIR}/kubeconfig-seattle.yaml"

validate_region() {
  local ctx="$1"
  echo ""
  echo "════════ GPU Validation: ${ctx} ════════"

  # 1. Node is Ready
  info "[${ctx}] Node readiness..."
  local node_status
  node_status=$(kubectl get nodes --context="${ctx}" \
    -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  if [[ "${node_status}" == "True" ]]; then
    success "  Node is Ready"
    ((PASS++))
  else
    error "  Node is NOT Ready (status=${node_status})"
    ((FAIL++))
  fi

  # 2. GPU label present
  info "[${ctx}] GPU node label..."
  check "  nvidia.com/gpu.present=true label" \
    kubectl get nodes --context="${ctx}" \
    -l "nvidia.com/gpu.present=true" --no-headers -o name

  # 3. Allocatable GPU resource
  info "[${ctx}] nvidia.com/gpu allocatable resource..."
  local gpu_count
  gpu_count=$(kubectl get nodes --context="${ctx}" \
    -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null || echo "0")
  if [[ "${gpu_count}" -ge "1" ]]; then
    success "  nvidia.com/gpu allocatable: ${gpu_count}"
    ((PASS++))
  else
    error "  nvidia.com/gpu NOT allocatable (value='${gpu_count}')"
    error "  GPU Operator may still be installing. Check:"
    error "  kubectl get pods -n gpu-operator --context=${ctx}"
    ((FAIL++))
  fi

  # 4. GPU Operator pods running
  info "[${ctx}] GPU Operator pods..."
  local not_running
  not_running=$(kubectl get pods -n gpu-operator --context="${ctx}" \
    --no-headers 2>/dev/null | grep -v Running | grep -v Completed | wc -l || echo "99")
  if [[ "${not_running}" -eq "0" ]]; then
    success "  All GPU Operator pods Running/Completed"
    ((PASS++))
  else
    warn "  ${not_running} GPU Operator pod(s) not Running:"
    kubectl get pods -n gpu-operator --context="${ctx}" 2>/dev/null | grep -v Running | grep -v Completed || true
    ((FAIL++))
  fi

  # 5. DCGM Exporter pod running
  info "[${ctx}] DCGM Exporter..."
  check "  DCGM Exporter pod running" \
    kubectl get pods -n gpu-operator --context="${ctx}" \
    -l "app=nvidia-dcgm-exporter" --no-headers

  # 6. nvidia-smi inside vLLM pod
  info "[${ctx}] nvidia-smi inside vLLM pod..."
  local vllm_pod
  vllm_pod=$(kubectl get pod -n inference --context="${ctx}" \
    -l "app=vllm" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "${vllm_pod}" ]]; then
    warn "  vLLM pod not running yet — skipping nvidia-smi check"
    warn "  Check: kubectl get pods -n inference --context=${ctx}"
    ((FAIL++))
  else
    info "  Running nvidia-smi in pod ${vllm_pod}..."
    local smi_output
    smi_output=$(kubectl exec "${vllm_pod}" -n inference --context="${ctx}" \
      -- nvidia-smi --query-gpu=name,memory.total,memory.used,utilization.gpu \
      --format=csv,noheader 2>/dev/null || echo "")

    if [[ -n "${smi_output}" ]]; then
      success "  nvidia-smi output:"
      echo "    ${smi_output}"
      ((PASS++))

      # Check it's RTX 4000 Ada
      if echo "${smi_output}" | grep -qi "RTX 4000"; then
        success "  RTX 4000 Ada confirmed"
        ((PASS++))
      else
        warn "  GPU name doesn't match RTX 4000 Ada: ${smi_output%%,*}"
      fi
    else
      error "  nvidia-smi failed inside vLLM pod"
      error "  The GPU may not be accessible inside the container"
      ((FAIL++))
    fi
  fi

  # 7. vLLM /health endpoint
  info "[${ctx}] vLLM health endpoint..."
  local vllm_ip
  vllm_ip=$(kubectl get svc vllm -n inference --context="${ctx}" \
    -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

  if [[ -z "${vllm_ip}" ]]; then
    warn "  vLLM LoadBalancer IP not assigned yet"
    ((FAIL++))
  else
    local health_status
    health_status=$(curl -sf --max-time 10 "http://${vllm_ip}:8000/health" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','unknown'))" 2>/dev/null || echo "error")
    if [[ "${health_status}" == "ok" || "${health_status}" == "healthy" ]]; then
      success "  vLLM health: ${health_status} (http://${vllm_ip}:8000)"
      ((PASS++))
    else
      warn "  vLLM /health returned: ${health_status} (model may still be loading)"
      warn "  This is normal for up to 10 minutes after first deploy"
      ((FAIL++))
    fi
  fi

  # 8. GPU metrics via DCGM
  info "[${ctx}] DCGM metrics endpoint..."
  local dcgm_pod
  dcgm_pod=$(kubectl get pod -n gpu-operator --context="${ctx}" \
    -l "app=nvidia-dcgm-exporter" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -n "${dcgm_pod}" ]]; then
    local dcgm_metrics
    dcgm_metrics=$(kubectl exec "${dcgm_pod}" -n gpu-operator --context="${ctx}" \
      -- curl -sf http://localhost:9400/metrics 2>/dev/null | grep "^DCGM_FI_DEV_GPU_UTIL" | head -1 || echo "")
    if [[ -n "${dcgm_metrics}" ]]; then
      success "  DCGM metrics available: ${dcgm_metrics}"
      ((PASS++))
    else
      warn "  DCGM metrics not yet available (GPU Operator may still be initializing)"
      ((FAIL++))
    fi
  fi

  echo ""
}

# ── Run for both regions ──────────────────────────────────────────────────────

validate_region "chicago"
validate_region "seattle"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "════════ VALIDATION SUMMARY ════════"
echo ""
success "  Passed: ${PASS}"
if [[ "${FAIL}" -gt 0 ]]; then
  error   "  Failed: ${FAIL}"
else
  success "  Failed: 0"
fi
echo ""

if [[ "${FAIL}" -eq 0 ]]; then
  success "All GPU checks passed! Ready to run inference."
  exit 0
else
  warn "Some checks failed. See docs/GPU_SETUP.md and docs/TROUBLESHOOTING.md"
  exit 1
fi
