#!/usr/bin/env bash
# =============================================================================
# toggle-ray-demo.sh — Swap Chicago's single GPU node between vLLM and Ray Serve
#
# Chicago has exactly one GPU node, already used by kubernetes/vllm's
# Deployment. Ray Serve's GPU worker group requests the same nvidia.com/gpu:1,
# so only one of the two can be running at a time. This script scales one to
# 0 and waits for the GPU to free up before scaling the other to 1.
#
# Usage:
#   ./scripts/toggle-ray-demo.sh on    # vLLM -> 0, Ray Serve GPU worker -> 1
#   ./scripts/toggle-ray-demo.sh off   # Ray Serve GPU worker -> 0, vLLM -> 1
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
export KUBECONFIG="${ROOT_DIR}/kubeconfig-chicago.yaml"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}→${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
error()   { echo -e "${RED}✗${NC} $*" >&2; }

MODE="${1:-}"
if [[ "${MODE}" != "on" && "${MODE}" != "off" ]]; then
  error "Usage: $0 <on|off>"
  exit 1
fi

# Waits until no *active* (non-terminal) pod matches the label — ignores old
# Completed/Failed leftovers, which otherwise never disappear and make
# `kubectl wait --for=delete` block for its full timeout every time.
wait_for_gone() {
  local label="$1" ns="$2"
  info "Waiting for ${label} pods in ${ns} to terminate (releases the GPU)..."
  for _ in $(seq 1 24); do
    local active
    active=$(kubectl get pods -l "${label}" -n "${ns}" \
      --field-selector=status.phase!=Succeeded,status.phase!=Failed \
      -o name 2>/dev/null | wc -l | tr -d ' ')
    [[ "${active}" == "0" ]] && return 0
    sleep 5
  done
  warn "Timed out waiting for ${label} pods in ${ns} to terminate — continuing anyway."
}

# RayService is supposed to propagate spec.rayClusterConfig.workerGroupSpecs
# changes down to the live RayCluster automatically, but that doesn't always
# happen for pure replica-count changes on this KubeRay version — so patch
# the RayCluster directly too, right after the RayService, to force it.
patch_ray_worker_replicas() {
  local n="$1"
  kubectl patch rayservice ray-serve-llm -n ray-serve --type=json \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/rayClusterConfig/workerGroupSpecs/0/replicas\",\"value\":${n}}]"
  local rc
  rc=$(kubectl get raycluster -n ray-serve -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
  if [[ -n "${rc}" ]]; then
    kubectl patch raycluster "${rc}" -n ray-serve --type=json \
      -p="[{\"op\":\"replace\",\"path\":\"/spec/workerGroupSpecs/0/replicas\",\"value\":${n}}]" 2>&1 || \
      warn "Could not patch RayCluster ${rc} directly — RayService's own reconciliation may still catch up on its own."
  fi
}

if [[ "${MODE}" == "on" ]]; then
  info "Swapping Chicago's GPU: vLLM → Ray Serve"

  info "Scaling vLLM to 0 replicas..."
  kubectl scale deployment/vllm -n inference --replicas=0

  wait_for_gone "app=vllm" "inference"

  info "Scaling Ray Serve's GPU worker group to 1..."
  patch_ray_worker_replicas 1

  info "Waiting for the Ray Serve app to come up (this includes a model download/load, can take several minutes on first run)..."
  for _ in $(seq 1 60); do
    STATUS=$(kubectl get rayservice ray-serve-llm -n ray-serve -o jsonpath='{.status.serviceStatus}' 2>/dev/null || true)
    [[ "${STATUS}" == "Running" ]] && break
    sleep 10
  done

  if [[ "${STATUS}" == "Running" ]]; then
    success "Ray Serve is up and serving. vLLM is at 0 replicas."
  else
    warn "Ray Serve isn't reporting Running yet (status: '${STATUS:-unknown}'). Check: kubectl get rayservice ray-serve-llm -n ray-serve -o yaml"
  fi

else
  info "Swapping Chicago's GPU: Ray Serve → vLLM"

  info "Scaling Ray Serve's GPU worker group to 0..."
  patch_ray_worker_replicas 0

  wait_for_gone "ray.io/node-type=worker" "ray-serve"

  info "Scaling vLLM back to 1 replica..."
  kubectl scale deployment/vllm -n inference --replicas=1

  # Not `kubectl wait -l app=vllm` — that selector also matches old
  # Completed leftover pods from past deploys, which never turn Ready and
  # make the wait time out even once the real pod is fine. Poll instead.
  info "Waiting for vLLM to become ready (downloads/loads the model, can take several minutes)..."
  READY=""
  for _ in $(seq 1 90); do
    if [[ "$(kubectl get deployment/vllm -n inference -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" == "1" ]]; then
      READY=1
      break
    fi
    sleep 10
  done

  if [[ -n "${READY}" ]]; then
    success "vLLM is back up. Ray Serve's GPU worker is at 0 replicas."
  else
    warn "vLLM didn't report Ready in time — check: kubectl get pods -n inference -l app=vllm"
  fi
fi
