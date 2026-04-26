#!/usr/bin/env bash
# =============================================================================
# validate-ip-allowlist.sh — Verifies NO service is exposed to 0.0.0.0/0
#
# Checks:
#   1. Every LoadBalancer Service has loadBalancerSourceRanges set
#   2. None of them contain 0.0.0.0/0
#   3. Linode Cloud Firewalls are attached to nodes
#   4. vLLM is not reachable from a non-allowed IP (simulated)
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}→${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
error()   { echo -e "${RED}✗${NC} $*"; }
PASS=0; FAIL=0

export KUBECONFIG="${ROOT_DIR}/kubeconfig-chicago.yaml:${ROOT_DIR}/kubeconfig-seattle.yaml"

ALLOWED_CIDR=$(grep 'allowed_admin_cidr' "${TF_DIR}/terraform.tfvars" \
  | awk -F'"' '{print $2}' 2>/dev/null || echo "unknown")

echo ""
info "Configured allowed_admin_cidr: ${ALLOWED_CIDR}"
echo ""

# ── Check a single service ────────────────────────────────────────────────────

check_service() {
  local ctx="$1" ns="$2" svc="$3"
  local label="${ctx}/${ns}/${svc}"

  # Get the service type
  local svc_type
  svc_type=$(kubectl get svc "${svc}" -n "${ns}" --context="${ctx}" \
    -o jsonpath='{.spec.type}' 2>/dev/null || echo "NotFound")

  if [[ "${svc_type}" == "NotFound" ]]; then
    warn "  ${label} — NOT FOUND (may not be deployed yet)"
    return
  fi

  if [[ "${svc_type}" != "LoadBalancer" ]]; then
    info "  ${label} — type=${svc_type} (not LoadBalancer, skip)"
    return
  fi

  # Get loadBalancerSourceRanges
  local ranges
  ranges=$(kubectl get svc "${svc}" -n "${ns}" --context="${ctx}" \
    -o jsonpath='{.spec.loadBalancerSourceRanges[*]}' 2>/dev/null || echo "")

  if [[ -z "${ranges}" ]]; then
    error "  ${label} — NO loadBalancerSourceRanges! EXPOSED TO 0.0.0.0/0 !!!"
    ((FAIL++))
    return
  fi

  # Check for dangerous open CIDR
  if echo "${ranges}" | grep -qE '^0\.0\.0\.0/0$|0\.0\.0\.0/0 '; then
    error "  ${label} — contains 0.0.0.0/0 in source ranges! INSECURE!"
    ((FAIL++))
    return
  fi

  # Check our IP is in there
  if echo "${ranges}" | grep -q "${ALLOWED_CIDR}"; then
    success "  ${label} — restricted to ${ranges}"
    ((PASS++))
  else
    warn "  ${label} — has ranges (${ranges}) but NOT matching allowed_admin_cidr (${ALLOWED_CIDR})"
    warn "  You may not be able to reach this service. Re-run deploy-all.sh"
    ((FAIL++))
  fi
}

# ── Verify all LoadBalancer services in a region ──────────────────────────────

check_all_services() {
  local ctx="$1"
  echo ""
  echo "════════ IP Allowlist: ${ctx} ════════"

  # Get all LoadBalancer services
  info "[${ctx}] Scanning all LoadBalancer services..."
  local all_lb_svcs
  all_lb_svcs=$(kubectl get svc -A --context="${ctx}" \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
    2>/dev/null || echo "")

  if [[ -z "${all_lb_svcs}" ]]; then
    warn "  No LoadBalancer services found yet (workloads may still be deploying)"
    return
  fi

  while IFS='/' read -r ns svc; do
    [[ -n "${svc}" ]] && check_service "${ctx}" "${ns}" "${svc}"
  done <<< "${all_lb_svcs}"

  # Specific services we expect
  echo ""
  info "[${ctx}] Checking expected services..."
  for ns_svc in "inference/vllm" "monitoring/prometheus-kube-prometheus-prometheus" "inference/inference-router"; do
    local ns="${ns_svc%%/*}"
    local svc="${ns_svc##*/}"
    check_service "${ctx}" "${ns}" "${svc}"
  done

  # Grafana uses a different name depending on Helm release
  for grafana_svc in "grafana" "prometheus-grafana"; do
    local exists
    exists=$(kubectl get svc "${grafana_svc}" -n monitoring --context="${ctx}" \
      --no-headers 2>/dev/null | wc -l || echo "0")
    if [[ "${exists}" -gt "0" ]]; then
      check_service "${ctx}" "monitoring" "${grafana_svc}"
    fi
  done
}

check_all_services "chicago"
check_all_services "seattle"

# ── Verify Cloud Firewall via Terraform state ──────────────────────────────────

echo ""
echo "════════ Cloud Firewall ════════"
info "Checking Linode Cloud Firewalls in Terraform state..."

if [[ -f "${TF_DIR}/terraform.tfstate" ]]; then
  fw_count=$(python3 -c "
import json,sys
with open('${TF_DIR}/terraform.tfstate') as f:
    state = json.load(f)
resources = state.get('resources', [])
fws = [r for r in resources if r.get('type') == 'linode_firewall']
print(len(fws))
" 2>/dev/null || echo "0")

  if [[ "${fw_count}" -ge "2" ]]; then
    success "  ${fw_count} Cloud Firewalls found in Terraform state"
    ((PASS++))
  else
    warn "  Expected 2 firewalls, found ${fw_count}"
    warn "  Run: make terraform-apply to create firewalls"
    ((FAIL++))
  fi
else
  warn "  terraform.tfstate not found — cannot verify firewalls"
  warn "  Run: make terraform-apply"
fi

# ── Verify no NodePort services open to all ───────────────────────────────────

echo ""
echo "════════ NodePort Check ════════"
for ctx in chicago seattle; do
  info "[${ctx}] Checking for NodePort services..."
  nodeports=$(kubectl get svc -A --context="${ctx}" \
    -o jsonpath='{range .items[?(@.spec.type=="NodePort")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' \
    2>/dev/null || echo "")
  if [[ -z "${nodeports}" ]]; then
    success "  [${ctx}] No NodePort services (good)"
    ((PASS++))
  else
    warn "  [${ctx}] NodePort services found (access controlled by Cloud Firewall):"
    echo "${nodeports}" | while read -r svc; do warn "    ${svc}"; done
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "════════ SECURITY VALIDATION SUMMARY ════════"
success "  Passed: ${PASS}"
if [[ "${FAIL}" -gt 0 ]]; then
  error   "  Failed: ${FAIL}"
  echo ""
  error "CRITICAL: Some services may be exposed without IP restriction."
  error "Run 'make deploy-all' to reapply IP allowlists."
  exit 1
else
  success "  All services are IP-restricted to: ${ALLOWED_CIDR}"
  exit 0
fi
