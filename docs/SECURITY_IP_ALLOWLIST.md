# Security — IP Allowlist

## Principle

**Zero 0.0.0.0/0 exposure by default.** Every service is restricted to `allowed_admin_cidr`.

The one documented exception is vLLM port 8000 in Chicago, intentionally opened to
`0.0.0.0/0` to let the Zuplo AI Gateway (which has no fixed egress IP) reach it for
the foodedge chat demo — see [Layer 5 — vLLM API Key](#layer-5--vllm-api-key-application-level)
for how that's still protected, and [Opening a Port for a No-Fixed-IP
Caller](#opening-a-port-for-a-no-fixed-ip-caller-eg-zuplo) for how to revert it.

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

### Layer 5 — vLLM API Key (application-level)

IP allowlisting assumes the caller has a stable, known source IP. That breaks down for
callers running on distributed edge platforms (Akamai Functions, Cloudflare Workers,
Zuplo's AI Gateway, ...) — they don't publish a small fixed egress CIDR, so there's no
IP to allow. For those callers, vLLM authenticates the *request* instead of the *network
path*, via vLLM's built-in `--api-key` flag (Bearer token, checked before the request
reaches the model).

**Setup (per region):**

```bash
# 1. Generate a random key and store it as a Kubernetes Secret (never commit it)
VLLM_KEY=$(openssl rand -hex 32)
kubectl create secret generic vllm-auth --from-literal=api-key="${VLLM_KEY}" \
  -n inference --context=<chicago|seattle>
```

`kubernetes/vllm/deployment.yaml` reads it into `VLLM_API_KEY` via `secretKeyRef` and
passes it as `--api-key "$(VLLM_API_KEY)"` to the vLLM entrypoint. Both regions share
the same secret value so the same key works against either LoadBalancer.

**Verify:**

```bash
# Without the key → 401
curl -i http://<VLLM-LB-IP>:8000/v1/models

# With the key → 200
curl -i -H "Authorization: Bearer <VLLM_KEY>" http://<VLLM-LB-IP>:8000/v1/models
```

**Using it from an edge gateway (e.g. Zuplo AI Gateway):** point the provider's base
URL at the NodeBalancer's public hostname, not its bare IP — Cloudflare Workers (and
by extension Zuplo, which runs on Workers) refuse outbound `fetch()` calls to raw IP
literals (`error code: 1003`). Linode gives every NodeBalancer a resolvable hostname
for free:

```bash
curl -H "Authorization: Bearer $LINODE_TOKEN" \
  https://api.linode.com/v4/nodebalancers/<id> | jq -r .hostname
# → 172-237-133-120.ip.linodeusercontent.com
```

Use `http://<that-hostname>:8000/v1` as the base URL and the raw key (no `Bearer `
prefix — the gateway adds that) as the API key field.

This layer does not replace Layers 1–2 — keep the network restricted to
`allowed_admin_cidr` whenever the caller *does* have a stable IP. Only relax the
network layer (see below) when the caller genuinely can't be identified by IP, and
rely on the API key as the real gate at that point.

### Opening a Port for a No-Fixed-IP Caller (e.g. Zuplo)

Only do this once the target service has its own application-level auth (Layer 5,
above) — otherwise this *is* the 0.0.0.0/0 exposure the rest of this doc warns against.

```bash
# 1. Kubernetes Service — widen loadBalancerSourceRanges for that region only
kubectl patch svc vllm -n inference --context=<region> \
  -p '{"spec":{"loadBalancerSourceRanges":["0.0.0.0/0"]}}'

# 2. Cloud Firewall — widen just the one inbound rule for that region's firewall,
#    via the Linode API (PUT replaces the whole rule set, so fetch-modify-PUT):
curl -s -H "Authorization: Bearer $LINODE_TOKEN" \
  https://api.linode.com/v4/networking/firewalls/<firewall-id>/rules > rules.json
# edit the "allow-public-vllm" rule's addresses.ipv4 to ["0.0.0.0/0"] in rules.json
curl -X PUT -H "Authorization: Bearer $LINODE_TOKEN" -H "Content-Type: application/json" \
  -d @rules.json https://api.linode.com/v4/networking/firewalls/<firewall-id>/rules
```

**To revert** (restore admin-only access once the caller is no longer needed):

```bash
kubectl patch svc vllm -n inference --context=<region> \
  -p '{"spec":{"loadBalancerSourceRanges":["'"${ADMIN_CIDR}"'"]}}'
# then repeat the fetch-modify-PUT above with addresses.ipv4 = ["<ADMIN_CIDR>"]
```

This is a deliberate one-off (`kubectl patch` + direct Linode API call), not a
Terraform change — `terraform/firewall.tf` and `kubernetes/vllm/service.yaml` stay
admin-only, so a routine `terraform apply` / `make deploy-all` won't accidentally
make this permanent, and won't silently revert it either — it has to be done by hand
on both sides.

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
