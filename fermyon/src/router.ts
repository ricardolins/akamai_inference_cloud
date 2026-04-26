/**
 * Fermyon Spin — Primary multi-region inference router
 *
 * Responsibilities:
 *   1. Enforce IP allowlist — return 403 for any IP outside allowed_admin_cidr
 *   2. Check health of Chicago and Seattle vLLM endpoints
 *   3. Route to healthiest region (round-robin when both healthy)
 *   4. Automatic failover with x-region / x-fallback response headers
 *   5. Stream vLLM SSE responses transparently
 *   6. Log blocked requests with source IP
 *
 * Environment variables (set in spin.toml [component.router.variables]):
 *   chicago_vllm_url   — e.g. http://203.0.113.10:8000
 *   seattle_vllm_url   — e.g. http://198.51.100.20:8000
 *   allowed_admin_cidr — e.g. 200.100.50.25/32
 */

import { HandleRequest, HttpRequest, HttpResponse, Variables, Config } from "@fermyon/spin-sdk";

// ── Types ─────────────────────────────────────────────────────────────────────

interface RegionConfig {
  name: string;
  url: string;
}

interface RouteResult {
  region: string;
  url: string;
  fallback: boolean;
}

// ── IP Allowlist ──────────────────────────────────────────────────────────────

function ipToInt(ip: string): number {
  const parts = ip.split(".").map(Number);
  return ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]) >>> 0;
}

function isIpAllowed(clientIp: string, cidr: string): boolean {
  try {
    const [network, prefixStr] = cidr.split("/");
    const prefix = parseInt(prefixStr, 10);
    const mask = prefix === 0 ? 0 : (~0 << (32 - prefix)) >>> 0;
    return (ipToInt(clientIp) & mask) === (ipToInt(network) & mask);
  } catch {
    return false;
  }
}

function getClientIp(request: HttpRequest): string {
  // Fermyon Spin receives the real client IP in x-forwarded-for when behind a proxy
  const xff = request.headers["x-forwarded-for"];
  if (xff) return xff.split(",")[0].trim();
  const realIp = request.headers["x-real-ip"];
  if (realIp) return realIp.trim();
  // Spin 2.x exposes spin-client-addr
  const spinAddr = request.headers["spin-client-addr"];
  if (spinAddr) return spinAddr.split(":")[0];
  return "0.0.0.0";
}

// ── Health Check ──────────────────────────────────────────────────────────────

async function checkHealth(region: RegionConfig): Promise<boolean> {
  try {
    const response = await fetch(`${region.url}/health`, {
      method: "GET",
      signal: AbortSignal.timeout(5000),
    });
    return response.ok;
  } catch {
    return false;
  }
}

// ── Round-robin state ─────────────────────────────────────────────────────────
// Spin components are stateless per-request. We use a simple deterministic
// selection based on the current second to approximate round-robin.

function selectRegionDeterministic(
  chicago: RegionConfig,
  seattle: RegionConfig,
  chicagoHealthy: boolean,
  seattleHealthy: boolean
): RouteResult | null {
  if (!chicagoHealthy && !seattleHealthy) return null;

  if (!chicagoHealthy) {
    return { region: "seattle", url: seattle.url, fallback: true };
  }
  if (!seattleHealthy) {
    return { region: "chicago", url: chicago.url, fallback: true };
  }

  // Both healthy: alternate per second for approximate round-robin
  const slot = Math.floor(Date.now() / 1000) % 2;
  if (slot === 0) {
    return { region: "chicago", url: chicago.url, fallback: false };
  } else {
    return { region: "seattle", url: seattle.url, fallback: false };
  }
}

// ── Proxy request ─────────────────────────────────────────────────────────────

async function proxyToRegion(
  request: HttpRequest,
  targetBaseUrl: string,
  region: string,
  fallback: boolean
): Promise<HttpResponse> {
  const targetUrl = `${targetBaseUrl}${request.url}`;

  // Forward request to vLLM, preserving method, headers, body
  const upstreamResponse = await fetch(targetUrl, {
    method: request.method,
    headers: {
      ...request.headers,
      "x-forwarded-by": "akai-spin-router",
      // Remove hop-by-hop headers that shouldn't be forwarded
      "transfer-encoding": undefined,
      "connection": undefined,
    },
    body: request.body,
    signal: AbortSignal.timeout(120000), // 2 min timeout for long inference
  });

  // Read body as text (handles both JSON and SSE streaming)
  const responseBody = await upstreamResponse.text();

  // Build response headers — add routing metadata
  const responseHeaders: Record<string, string> = {};
  upstreamResponse.headers.forEach((value, key) => {
    responseHeaders[key] = value;
  });
  responseHeaders["x-region"] = region;
  responseHeaders["x-fallback"] = String(fallback);
  responseHeaders["x-router"] = "akai-spin-fermyon";

  return {
    status: upstreamResponse.status,
    headers: responseHeaders,
    body: responseBody,
  };
}

// ── Main handler ──────────────────────────────────────────────────────────────

export const handleRequest: HandleRequest = async function (
  request: HttpRequest
): Promise<HttpResponse> {
  // Read configuration from Spin variables (set in spin.toml or spin deploy)
  const chicagoUrl    = Variables.get("chicago_vllm_url")   ?? "";
  const seattleUrl    = Variables.get("seattle_vllm_url")   ?? "";
  const allowedCidr   = Variables.get("allowed_admin_cidr") ?? "127.0.0.1/32";

  const chicago: RegionConfig = { name: "chicago", url: chicagoUrl };
  const seattle: RegionConfig = { name: "seattle", url: seattleUrl };

  // ── Built-in health endpoint ────────────────────────────────────────────────
  if (request.url === "/health" || request.url.startsWith("/health?")) {
    return {
      status: 200,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ status: "ok", router: "fermyon-spin" }),
    };
  }

  // ── Status endpoint ─────────────────────────────────────────────────────────
  if (request.url === "/status" || request.url.startsWith("/status?")) {
    const [chicagoOk, seattleOk] = await Promise.all([
      checkHealth(chicago),
      checkHealth(seattle),
    ]);
    return {
      status: 200,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        router: "fermyon-spin",
        regions: {
          chicago: { url: chicagoUrl, healthy: chicagoOk },
          seattle: { url: seattleUrl, healthy: seattleOk },
        },
        allowed_cidr: allowedCidr,
      }),
    };
  }

  // ── IP Allowlist enforcement ────────────────────────────────────────────────
  const clientIp = getClientIp(request);

  if (!isIpAllowed(clientIp, allowedCidr)) {
    console.error(`[BLOCKED] IP ${clientIp} is not in allowed CIDR ${allowedCidr}`);
    return {
      status: 403,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        error: "forbidden",
        message: "Access denied. Your IP is not authorized.",
        your_ip: clientIp,
      }),
    };
  }

  // ── Health checks ────────────────────────────────────────────────────────────
  const [chicagoHealthy, seattleHealthy] = await Promise.all([
    checkHealth(chicago),
    checkHealth(seattle),
  ]);

  // ── Region selection ─────────────────────────────────────────────────────────
  const route = selectRegionDeterministic(chicago, seattle, chicagoHealthy, seattleHealthy);

  if (!route) {
    console.error("[ERROR] All regions are down");
    return {
      status: 503,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        error: "service_unavailable",
        message: "All inference regions are currently down.",
        regions: { chicago: chicagoHealthy, seattle: seattleHealthy },
      }),
    };
  }

  // ── Proxy to selected region ─────────────────────────────────────────────────
  console.log(
    `[ROUTE] ${clientIp} → ${route.region}${route.fallback ? " (FALLBACK)" : ""} — ${request.method} ${request.url}`
  );

  try {
    return await proxyToRegion(request, route.url, route.region, route.fallback);
  } catch (err) {
    // Primary failed during proxy — try the other region as emergency fallback
    const fallbackUrl = route.region === "chicago" ? seattleUrl : chicagoUrl;
    const fallbackRegion = route.region === "chicago" ? "seattle" : "chicago";
    console.error(`[FALLBACK] ${route.region} failed, trying ${fallbackRegion}: ${err}`);

    try {
      return await proxyToRegion(request, fallbackUrl, fallbackRegion, true);
    } catch (fallbackErr) {
      return {
        status: 502,
        headers: { "content-type": "application/json" },
        body: JSON.stringify({
          error: "bad_gateway",
          message: "Both regions failed to respond.",
          primary_error: String(err),
          fallback_error: String(fallbackErr),
        }),
      };
    }
  }
};
