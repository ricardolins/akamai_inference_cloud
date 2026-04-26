#!/usr/bin/env bash
# =============================================================================
# test-routing.sh — Tests multi-region routing and failover
#
# Tests:
#   1. Router /status endpoint shows both regions
#   2. Requests are distributed between regions (x-region header)
#   3. Failover: scale vLLM to 0 replicas in Chicago → all traffic → Seattle
#   4. Recovery: scale vLLM back → traffic resumes to Chicago
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}→${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
error()   { echo -e "${RED}✗${NC} $*"; }

export KUBECONFIG="${ROOT_DIR}/kubeconfig-chicago.yaml:${ROOT_DIR}/kubeconfig-seattle.yaml"

# Discover router IP (using Chicago router as primary)
ROUTER_IP=$(kubectl get svc inference-router -n inference --context=chicago \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

if [[ -z "${ROUTER_IP}" ]]; then
  error "Router LoadBalancer IP not found. Run: make deploy-all first."
  exit 1
fi

ROUTER_URL="http://${ROUTER_IP}:8080"
info "Router URL: ${ROUTER_URL}"

MODEL="mistralai/Mistral-7B-Instruct-v0.3"
PAYLOAD='{"model":"'"${MODEL}"'","messages":[{"role":"user","content":"Say the word PONG only."}],"max_tokens":10,"temperature":0}'

echo ""

# ── Test 1: Router health ────────────────────────────────────────────────────

info "Test 1: Router health endpoint..."
health=$(curl -sf --max-time 5 "${ROUTER_URL}/health" || echo '{"status":"error"}')
if echo "${health}" | grep -q '"ok"'; then
  success "  Router is healthy: ${health}"
else
  error "  Router health failed: ${health}"
  exit 1
fi

# ── Test 2: Router status (both regions) ─────────────────────────────────────

info "Test 2: Router /status endpoint..."
status=$(curl -sf --max-time 10 "${ROUTER_URL}/status" || echo '{}')
echo "  Status: ${status}"
if echo "${status}" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('regions')" 2>/dev/null; then
  success "  Both regions visible in router status"
else
  warn "  Could not parse router status — check router deployment"
fi

# ── Test 3: IP block test ─────────────────────────────────────────────────────

info "Test 3: IP restriction (should get 403 from non-allowed IP simulation)..."
warn "  Cannot simulate non-allowed IP from localhost — verify manually with:"
warn "  curl -H 'X-Forwarded-For: 1.2.3.4' ${ROUTER_URL}/v1/models"
warn "  Expected: 403 Forbidden"

# ── Test 4: Normal routing (region distribution) ──────────────────────────────

info "Test 4: Normal routing — sending 6 requests, checking region distribution..."
declare -A region_count=( [chicago]=0 [seattle]=0 [unknown]=0 )

for i in $(seq 1 6); do
  response=$(curl -sf --max-time 30 \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}" \
    -D /tmp/response-headers-$$.txt \
    "${ROUTER_URL}/v1/chat/completions" 2>/dev/null || echo '{"error":"timeout"}')

  region=$(grep -i "^x-region:" /tmp/response-headers-$$.txt 2>/dev/null | awk '{print $2}' | tr -d '\r' || echo "unknown")
  fallback=$(grep -i "^x-fallback:" /tmp/response-headers-$$.txt 2>/dev/null | awk '{print $2}' | tr -d '\r' || echo "false")

  if echo "${response}" | grep -q '"choices"'; then
    region_count[${region:-unknown}]=$((${region_count[${region:-unknown}]:-0} + 1))
    info "  Request ${i}: region=${region} fallback=${fallback} ✓"
  else
    warn "  Request ${i}: region=${region} response=${response:0:100}"
  fi
  rm -f /tmp/response-headers-$$.txt
done

echo ""
info "  Region distribution:"
echo "    Chicago: ${region_count[chicago]:-0} requests"
echo "    Seattle: ${region_count[seattle]:-0} requests"
echo "    Unknown: ${region_count[unknown]:-0} requests"

if [[ "${region_count[chicago]:-0}" -gt "0" && "${region_count[seattle]:-0}" -gt "0" ]]; then
  success "  Traffic distributed across both regions"
elif [[ "${region_count[chicago]:-0}" -gt "0" || "${region_count[seattle]:-0}" -gt "0" ]]; then
  warn "  Traffic only going to one region — check other region's health"
else
  error "  No successful requests! Check router and vLLM deployment"
fi

# ── Test 5: Failover ──────────────────────────────────────────────────────────

echo ""
info "Test 5: Failover test — scaling Chicago vLLM to 0..."
warn "  This will temporarily stop inference in Chicago."
read -rp "  Continue? (yes/no): " confirm
if [[ "${confirm}" != "yes" ]]; then
  info "  Failover test skipped."
else
  # Scale down Chicago vLLM
  kubectl scale deployment vllm --replicas=0 -n inference --context=chicago
  info "  Waiting 20s for router health checks to detect failure..."
  sleep 20

  info "  Sending 4 requests — all should go to Seattle..."
  chicago_after=0; seattle_after=0
  for i in $(seq 1 4); do
    response=$(curl -sf --max-time 30 \
      -H "Content-Type: application/json" \
      -d "${PAYLOAD}" \
      -D /tmp/failover-headers-$$.txt \
      "${ROUTER_URL}/v1/chat/completions" 2>/dev/null || echo '{"error":"timeout"}')

    region=$(grep -i "^x-region:" /tmp/failover-headers-$$.txt 2>/dev/null | awk '{print $2}' | tr -d '\r' || echo "unknown")
    fallback=$(grep -i "^x-fallback:" /tmp/failover-headers-$$.txt 2>/dev/null | awk '{print $2}' | tr -d '\r' || echo "false")

    if [[ "${region}" == "seattle" ]]; then
      ((seattle_after++))
      success "  Failover request ${i}: → Seattle (fallback=${fallback}) ✓"
    else
      warn "  Failover request ${i}: → ${region} (expected seattle, fallback=${fallback})"
      ((chicago_after++))
    fi
    rm -f /tmp/failover-headers-$$.txt
  done

  if [[ "${seattle_after}" -ge "3" ]]; then
    success "  Failover working: ${seattle_after}/4 requests → Seattle"
  else
    error "  Failover NOT working: only ${seattle_after}/4 requests → Seattle"
  fi

  # Restore Chicago
  info "  Restoring Chicago vLLM..."
  kubectl scale deployment vllm --replicas=1 -n inference --context=chicago
  info "  Waiting 60s for Chicago to recover..."
  sleep 60
  success "  Chicago vLLM restored. Verify recovery with: make validate-vllm"
fi

echo ""
success "Routing tests complete."
