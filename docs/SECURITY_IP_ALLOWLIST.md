# Security — IP Allowlist

## Principle

**Zero 0.0.0.0/0 exposure.** Every service is restricted to `allowed_admin_cidr`.

## Defense Layers

### Layer 1 — Linode Cloud Firewall (node level)

Created by Terraform in `terraform/firewall.tf`. Attached to all GPU nodes.

```
Policy: DROP all inbound by default
Allow only from allowed_admin_cidr:
  TCP 22     → SSH
  TCP 6443   → Kubernetes API
  TCP 8000   → vLLM
  TCP 3000   → Grafana
  TCP 9090   → Prometheus
  TCP 80/8080 → Router
  TCP 9400   → DCGM Exporter
Allow internal node-to-node communication:
  TCP/UDP 192.168.128.0/17 (Linode private network)
Outbound: ACCEPT (nodes need internet for image pulls)
```

Verify in Linode Cloud Manager: https://cloud.linode.com/firewalls

### Layer 2 — Kubernetes LoadBalancer Source Ranges

Every `LoadBalancer` Service has:
```yaml
spec:
  loadBalancerSourceRanges:
    - "YOUR_IP/32"
```

This is enforced at the Linode NodeBalancer level — traffic from other IPs is dropped before reaching the node.

Verify:
```bash
kubectl get svc -A --context=chicago \
  -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.name}: {.spec.loadBalancerSourceRanges}{"\n"}{end}'
```

Expected output (NO 0.0.0.0/0):
```
vllm: [200.100.50.25/32]
inference-router: [200.100.50.25/32]
prometheus-kube-prometheus-prometheus: [200.100.50.25/32]
grafana: [200.100.50.25/32]
```

### Layer 3 — Application-Level IP Check (Router)

Both Fermyon Spin and Node.js router validate the client IP on every request:

```typescript
// Fermyon router (fermyon/src/router.ts)
if (!isIpAllowed(clientIp, allowedCidr)) {
  return { status: 403, body: JSON.stringify({ error: "forbidden" }) };
}
```

Returns `403 Forbidden` with JSON error for any non-allowed IP.

### Layer 4 — RBAC

- Kubeconfig files contain cluster admin certificates
- Keep `kubeconfig-chicago.yaml` and `kubeconfig-seattle.yaml` private (gitignored)
- Rotate via: `linode-cli lke kubeconfig-delete <cluster-id>`

## Automated Security Validation

```bash
make validate-security
# Runs scripts/validate-ip-allowlist.sh
```

The script checks:
1. Every LoadBalancer Service has `loadBalancerSourceRanges`
2. None contain `0.0.0.0/0`
3. Cloud Firewalls exist in Terraform state
4. No unexpected NodePort services

## Changing Your IP

If your IP changes:

1. Update `terraform/terraform.tfvars`:
   ```hcl
   allowed_admin_cidr = "NEW_IP/32"
   ```

2. Update firewall + service manifests:
   ```bash
   make terraform-apply   # Updates Cloud Firewall
   make deploy-all        # Reapplies loadBalancerSourceRanges
   ```

## What Is NOT Protected

### Kubernetes API Server (port 6443)

**LKE Normal does NOT support private API endpoints.** The Kubernetes API server is publicly accessible on port 6443.

Mitigations in place:
- Cloud Firewall restricts port 6443 to `allowed_admin_cidr` only
- Strong kubeconfig certificate rotation available via Linode API
- RBAC: only admin roles in kubeconfig

If you need private API access, upgrade to LKE Enterprise (see docs/LIMITATIONS.md).

### Model Downloads (HuggingFace)

vLLM downloads models from HuggingFace Hub on first start. This is outbound traffic (unaffected by inbound firewall rules). For air-gapped setups, pre-download models and mount via PVC.

## Testing IP Restriction

```bash
# Test from your IP (should work):
curl http://<IP>:8000/health

# Test from non-allowed IP (simulate via header):
curl -H "X-Forwarded-For: 1.2.3.4" http://<ROUTER-IP>:8080/health
# Expected: 403 Forbidden

# Verify Grafana is restricted:
curl http://<GRAFANA-IP>:3000/api/health
# Expected: 200 from your IP, connection refused or timeout from others
```
