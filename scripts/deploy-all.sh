#!/usr/bin/env bash
# =============================================================================
# deploy-all.sh — Full Kubernetes deployment for both regions
#
# What it does:
#   1. Reads kubeconfigs written by Terraform
#   2. Renames kubectl contexts to "chicago" and "seattle"
#   3. Reads allowed_admin_cidr from terraform.tfvars
#   4. Substitutes ALLOWED_ADMIN_CIDR_PLACEHOLDER in all service manifests
#   5. Applies namespaces, GPU Operator, vLLM, monitoring, router
#   6. Waits for services to get LoadBalancer IPs
#   7. Updates router config with the discovered IPs
#   8. Deploys Fermyon Spin router (if spin CLI is available)
#
# Usage:
#   ./scripts/deploy-all.sh
#   ./scripts/deploy-all.sh --region=chicago
#   ./scripts/deploy-all.sh --region=seattle
#   ./scripts/deploy-all.sh --kubeconfig-only
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${ROOT_DIR}/terraform"
K8S_DIR="${ROOT_DIR}/kubernetes"

# ── Parse arguments ───────────────────────────────────────────────────────────

REGION="all"
KUBECONFIG_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --region=chicago) REGION="chicago" ;;
    --region=seattle) REGION="seattle" ;;
    --kubeconfig-only) KUBECONFIG_ONLY=true ;;
  esac
done

# ── Colors ────────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}→${NC} $*"; }
success() { echo -e "${GREEN}✓${NC} $*"; }
warn()    { echo -e "${YELLOW}⚠${NC} $*"; }
error()   { echo -e "${RED}✗${NC} $*" >&2; }

# ── Read allowed_admin_cidr from terraform.tfvars ─────────────────────────────

TFVARS="${TF_DIR}/terraform.tfvars"
if [[ ! -f "${TFVARS}" ]]; then
  error "terraform.tfvars not found at ${TFVARS}"
  error "Copy terraform.tfvars.example to terraform.tfvars and set allowed_admin_cidr"
  exit 1
fi

ALLOWED_CIDR=$(grep 'allowed_admin_cidr' "${TFVARS}" | awk -F'"' '{print $2}')
if [[ -z "${ALLOWED_CIDR}" ]]; then
  error "allowed_admin_cidr not found in terraform.tfvars"
  exit 1
fi
info "IP allowlist: ${ALLOWED_CIDR}"

# ── Setup kubeconfigs ─────────────────────────────────────────────────────────

setup_kubeconfig() {
  local region="$1"
  local kc="${ROOT_DIR}/kubeconfig-${region}.yaml"

  if [[ ! -f "${kc}" ]]; then
    warn "Kubeconfig not found: ${kc}"
    info "Generating from Terraform..."
    cd "${TF_DIR}"
    terraform output -raw "${region}_kubeconfig" 2>/dev/null | base64 -d > "${kc}" || {
      error "Cannot get kubeconfig for ${region}. Run: make terraform-apply first."
      return 1
    }
    chmod 600 "${kc}"
  fi

  # Rename context for convenience
  local current_ctx
  current_ctx=$(kubectl config current-context --kubeconfig="${kc}" 2>/dev/null || true)
  if [[ -n "${current_ctx}" && "${current_ctx}" != "${region}" ]]; then
    kubectl config rename-context "${current_ctx}" "${region}" --kubeconfig="${kc}" 2>/dev/null || true
    success "Renamed context to '${region}'"
  fi

  export KUBECONFIG="${ROOT_DIR}/kubeconfig-chicago.yaml:${ROOT_DIR}/kubeconfig-seattle.yaml"
  success "Kubeconfig ready for ${region}"
}

setup_kubeconfig "chicago"
setup_kubeconfig "seattle"
export KUBECONFIG="${ROOT_DIR}/kubeconfig-chicago.yaml:${ROOT_DIR}/kubeconfig-seattle.yaml"

[[ "${KUBECONFIG_ONLY}" == "true" ]] && { success "Kubeconfigs configured."; exit 0; }

# ── Deploy to a single region ─────────────────────────────────────────────────

deploy_region() {
  local ctx="$1"
  info "════════ Deploying to ${ctx} ════════"

  # 1. Namespaces (idempotent)
  info "[${ctx}] Applying namespaces..."
  kubectl apply -f "${K8S_DIR}/namespaces/namespaces.yaml" --context="${ctx}"

  # 2. GPU Operator (via Helm)
  info "[${ctx}] Installing NVIDIA GPU Operator..."
  helm repo add nvidia https://helm.ngc.nvidia.com/nvidia --force-update 2>/dev/null || true
  helm repo update 2>/dev/null
  helm upgrade --install gpu-operator nvidia/gpu-operator \
    --namespace gpu-operator \
    --create-namespace \
    -f "${K8S_DIR}/gpu-operator/values.yaml" \
    --kube-context="${ctx}" \
    --wait --timeout=20m || {
      warn "[${ctx}] GPU Operator install may take longer. Check: kubectl get pods -n gpu-operator --context=${ctx}"
    }

  # 3. vLLM
  info "[${ctx}] Deploying vLLM..."

  # Substitute IP allowlist placeholder in service manifest
  local vllm_svc
  vllm_svc=$(sed "s|ALLOWED_ADMIN_CIDR_PLACEHOLDER|${ALLOWED_CIDR}|g" \
    "${K8S_DIR}/vllm/service.yaml")

  kubectl apply -f "${K8S_DIR}/vllm/configmap.yaml" --context="${ctx}"
  kubectl apply -f "${K8S_DIR}/vllm/deployment.yaml" --context="${ctx}"
  echo "${vllm_svc}" | kubectl apply -f - --context="${ctx}"

  # 4. Prometheus
  info "[${ctx}] Installing Prometheus stack..."
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update 2>/dev/null || true
  helm repo update 2>/dev/null

  local prom_values
  prom_values=$(sed "s|ALLOWED_ADMIN_CIDR_PLACEHOLDER|${ALLOWED_CIDR}|g" \
    "${K8S_DIR}/monitoring/prometheus-values.yaml")

  echo "${prom_values}" | helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    --create-namespace \
    --values - \
    --kube-context="${ctx}" \
    --wait --timeout=10m || warn "[${ctx}] Prometheus may still be starting"

  # 5. Grafana
  info "[${ctx}] Installing Grafana..."
  helm repo add grafana https://grafana.github.io/helm-charts --force-update 2>/dev/null || true
  helm repo update 2>/dev/null

  # Create dashboard ConfigMap
  kubectl create configmap grafana-dashboards \
    --from-file="${K8S_DIR}/monitoring/dashboards/gpu-inference-dashboard.json" \
    --namespace monitoring \
    --context="${ctx}" \
    --dry-run=client -o yaml | kubectl apply -f - --context="${ctx}"

  local grafana_values
  grafana_values=$(sed "s|ALLOWED_ADMIN_CIDR_PLACEHOLDER|${ALLOWED_CIDR}|g" \
    "${K8S_DIR}/monitoring/grafana-values.yaml")

  echo "${grafana_values}" | helm upgrade --install grafana grafana/grafana \
    --namespace monitoring \
    --values - \
    --kube-context="${ctx}" \
    --wait --timeout=5m || warn "[${ctx}] Grafana may still be starting"

  success "[${ctx}] Core workloads deployed"
}

# ── Wait for LoadBalancer IP ──────────────────────────────────────────────────

wait_for_lb_ip() {
  local ctx="$1" svc="$2" ns="$3"
  local ip=""
  local attempts=0
  local max_attempts=30

  info "Waiting for LoadBalancer IP: ${svc} in ${ctx}/${ns}..."
  while [[ -z "${ip}" && ${attempts} -lt ${max_attempts} ]]; do
    ip=$(kubectl get svc "${svc}" -n "${ns}" --context="${ctx}" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [[ -z "${ip}" ]]; then
      sleep 10
      ((attempts++))
    fi
  done

  if [[ -z "${ip}" ]]; then
    warn "Timeout waiting for IP: ${svc} in ${ctx}. Get it manually with:"
    warn "  kubectl get svc ${svc} -n ${ns} --context=${ctx}"
    echo "PENDING"
  else
    success "  ${ctx}/${ns}/${svc} → ${ip}"
    echo "${ip}"
  fi
}

# ── Deploy fallback router with discovered IPs ────────────────────────────────

deploy_router() {
  local ctx="$1"
  local chicago_ip="$2"
  local seattle_ip="$3"

  info "[${ctx}] Deploying fallback router..."

  # Inject router JS code from router/src/index.js
  local router_code="${ROOT_DIR}/router/src/index.js"

  kubectl create configmap router-app-code \
    --from-file=index.js="${router_code}" \
    --namespace inference \
    --context="${ctx}" \
    --dry-run=client -o yaml | kubectl apply -f - --context="${ctx}"

  # Substitute all placeholders in router manifests
  sed \
    -e "s|CHICAGO_VLLM_IP_PLACEHOLDER|${chicago_ip}|g" \
    -e "s|SEATTLE_VLLM_IP_PLACEHOLDER|${seattle_ip}|g" \
    -e "s|ALLOWED_ADMIN_CIDR_PLACEHOLDER|${ALLOWED_CIDR}|g" \
    "${K8S_DIR}/router/deployment.yaml" | kubectl apply -f - --context="${ctx}"

  sed "s|ALLOWED_ADMIN_CIDR_PLACEHOLDER|${ALLOWED_CIDR}|g" \
    "${K8S_DIR}/router/service.yaml" | kubectl apply -f - --context="${ctx}"

  success "[${ctx}] Fallback router deployed"
}

# ── Deploy Fermyon Spin router ────────────────────────────────────────────────

deploy_fermyon() {
  local chicago_ip="$1"
  local seattle_ip="$2"

  if ! command -v spin &>/dev/null; then
    warn "Spin CLI not found — skipping Fermyon router deployment"
    warn "Install: curl -fsSL https://developer.fermyon.com/downloads/install.sh | bash"
    return
  fi

  info "Building Fermyon Spin router..."
  cd "${ROOT_DIR}/fermyon"

  # Substitute vLLM IPs in spin.toml
  sed -i.bak \
    -e "s|CHICAGO_VLLM_IP_PLACEHOLDER|${chicago_ip}|g" \
    -e "s|SEATTLE_VLLM_IP_PLACEHOLDER|${seattle_ip}|g" \
    spin.toml

  # Create variables file
  cat > variables.toml <<EOF
[variables]
chicago_vllm_url   = "http://${chicago_ip}:8000"
seattle_vllm_url   = "http://${seattle_ip}:8000"
allowed_admin_cidr = "${ALLOWED_CIDR}"
EOF

  npm install --silent
  spin build || { warn "Spin build failed — check fermyon/src/router.ts"; return; }

  info "Starting Fermyon Spin router locally (background)..."
  spin up --runtime-config-file variables.toml &
  SPIN_PID=$!
  echo "${SPIN_PID}" > /tmp/spin-router.pid
  success "Fermyon Spin router running (PID ${SPIN_PID}) at http://localhost:3000"
  success "To stop: kill \$(cat /tmp/spin-router.pid)"

  cd "${ROOT_DIR}"
}

# ── Main ──────────────────────────────────────────────────────────────────────

main() {
  # Deploy workloads
  if [[ "${REGION}" == "all" || "${REGION}" == "chicago" ]]; then
    deploy_region "chicago"
  fi
  if [[ "${REGION}" == "all" || "${REGION}" == "seattle" ]]; then
    deploy_region "seattle"
  fi

  # Wait for vLLM LoadBalancer IPs
  info "Waiting for LoadBalancer IPs (may take 2-5 minutes)..."
  CHICAGO_IP=$(wait_for_lb_ip "chicago" "vllm" "inference")
  SEATTLE_IP=$(wait_for_lb_ip "seattle" "vllm" "inference")

  # Deploy fallback router (needs both IPs)
  if [[ "${CHICAGO_IP}" != "PENDING" && "${SEATTLE_IP}" != "PENDING" ]]; then
    if [[ "${REGION}" == "all" || "${REGION}" == "chicago" ]]; then
      deploy_router "chicago" "${CHICAGO_IP}" "${SEATTLE_IP}"
    fi
    if [[ "${REGION}" == "all" || "${REGION}" == "seattle" ]]; then
      deploy_router "seattle" "${CHICAGO_IP}" "${SEATTLE_IP}"
    fi

    # Deploy Fermyon Spin router
    deploy_fermyon "${CHICAGO_IP}" "${SEATTLE_IP}"
  else
    warn "LoadBalancer IPs not ready — router deployment skipped"
    warn "Run 'make deploy-all' again after IPs are assigned"
  fi

  # Final summary
  echo ""
  success "═══════════════════════════════════════════════════"
  success " Deployment complete!"
  success "═══════════════════════════════════════════════════"
  echo ""
  info "Service IPs (get latest with: make get-ips):"
  kubectl get svc -A --context=chicago 2>/dev/null | grep -E "LoadBalancer|EXTERNAL" || true
  echo ""
  kubectl get svc -A --context=seattle 2>/dev/null | grep -E "LoadBalancer|EXTERNAL" || true
  echo ""
  info "Access pattern (no DNS, IP only):"
  info "  vLLM:       http://<LB-IP>:8000/v1/chat/completions"
  info "  Grafana:    http://<LB-IP>:3000"
  info "  Prometheus: http://<LB-IP>:9090"
  info "  Router:     http://<LB-IP>:8080"
  echo ""
  info "Next: make validate"
}

main
