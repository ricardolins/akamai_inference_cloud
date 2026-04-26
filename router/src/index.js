/**
 * Fallback multi-region inference router (Node.js)
 * Mirrors the Fermyon Spin router logic for environments where Spin is unavailable.
 *
 * Features:
 *   - IP allowlist enforcement (returns 403 for unauthorized IPs)
 *   - Health-check-aware round-robin routing (Chicago / Seattle)
 *   - Automatic failover: if primary is down, routes to secondary
 *   - Adds x-region and x-fallback response headers
 *   - Streams vLLM SSE responses (for streaming inference)
 *   - /health and /ready endpoints
 *   - /status endpoint showing region health
 */

"use strict";

const http = require("http");
const https = require("https");
const { URL } = require("url");

// ── Configuration ─────────────────────────────────────────────────────────────

const CONFIG = {
  chicagoUrl: process.env.CHICAGO_VLLM_URL || "http://127.0.0.1:8000",
  seattleUrl: process.env.SEATTLE_VLLM_URL || "http://127.0.0.1:8001",
  allowedCidr: process.env.ALLOWED_ADMIN_CIDR || "127.0.0.1/32",
  healthCheckInterval: parseInt(process.env.HEALTH_CHECK_INTERVAL || "10000"),
  requestTimeout: parseInt(process.env.REQUEST_TIMEOUT || "120000"),
  port: parseInt(process.env.PORT || "8080"),
};

// ── IP Allowlist ──────────────────────────────────────────────────────────────

/**
 * Converts a CIDR string (e.g. "200.100.50.25/32") to a numeric range.
 * Supports only IPv4 /32 for simplicity (single IP restriction).
 */
function parseCidr(cidr) {
  const [ip, prefix] = cidr.split("/");
  const prefixLen = parseInt(prefix);
  const ipInt = ip.split(".").reduce((acc, octet) => (acc << 8) | parseInt(octet), 0) >>> 0;
  const mask = prefixLen === 0 ? 0 : (~0 << (32 - prefixLen)) >>> 0;
  return { network: ipInt & mask, mask, prefixLen };
}

function ipToInt(ip) {
  return ip.split(".").reduce((acc, octet) => (acc << 8) | parseInt(octet), 0) >>> 0;
}

function isIpAllowed(clientIp, cidr) {
  try {
    const { network, mask } = parseCidr(cidr);
    const clientInt = ipToInt(clientIp);
    return (clientInt & mask) === network;
  } catch {
    return false;
  }
}

function getClientIp(req) {
  // In Kubernetes with externalTrafficPolicy: Local, the real IP is in X-Forwarded-For
  const xff = req.headers["x-forwarded-for"];
  if (xff) return xff.split(",")[0].trim();
  const realIp = req.headers["x-real-ip"];
  if (realIp) return realIp.trim();
  return req.socket.remoteAddress || "0.0.0.0";
}

// ── Region Health State ───────────────────────────────────────────────────────

const health = {
  chicago: { healthy: true, lastCheck: null, latencyMs: null },
  seattle: { healthy: true, lastCheck: null, latencyMs: null },
};

let roundRobinIndex = 0;

async function checkHealth(name, baseUrl) {
  const start = Date.now();
  return new Promise((resolve) => {
    const url = new URL("/health", baseUrl);
    const mod = url.protocol === "https:" ? https : http;
    const req = mod.get(url.toString(), { timeout: 5000 }, (res) => {
      res.resume(); // drain body so socket closes cleanly and timeout event doesn't fire after success
      const ok = res.statusCode >= 200 && res.statusCode < 300;
      health[name] = { healthy: ok, lastCheck: new Date().toISOString(), latencyMs: Date.now() - start };
      resolve(ok);
    });
    req.on("error", () => {
      health[name] = { healthy: false, lastCheck: new Date().toISOString(), latencyMs: null };
      resolve(false);
    });
    req.on("timeout", () => {
      req.destroy();
      health[name] = { healthy: false, lastCheck: new Date().toISOString(), latencyMs: null };
      resolve(false);
    });
  });
}

function startHealthChecks() {
  const check = async () => {
    await Promise.all([
      checkHealth("chicago", CONFIG.chicagoUrl),
      checkHealth("seattle", CONFIG.seattleUrl),
    ]);
  };
  check();
  setInterval(check, CONFIG.healthCheckInterval);
}

// ── Region Selection ──────────────────────────────────────────────────────────

function selectRegion() {
  const chicagoOk = health.chicago.healthy;
  const seattleOk = health.seattle.healthy;

  if (!chicagoOk && !seattleOk) {
    return { region: null, url: null, fallback: false, error: "all_regions_down" };
  }

  if (!chicagoOk) {
    return { region: "seattle", url: CONFIG.seattleUrl, fallback: true };
  }

  if (!seattleOk) {
    return { region: "chicago", url: CONFIG.chicagoUrl, fallback: true };
  }

  // Both healthy: round-robin
  roundRobinIndex = (roundRobinIndex + 1) % 2;
  if (roundRobinIndex === 0) {
    return { region: "chicago", url: CONFIG.chicagoUrl, fallback: false };
  } else {
    return { region: "seattle", url: CONFIG.seattleUrl, fallback: false };
  }
}

// ── Proxy ─────────────────────────────────────────────────────────────────────

function proxyRequest(clientReq, clientRes, targetUrl, region, isFallback) {
  const target = new URL(clientReq.url, targetUrl);
  const mod = target.protocol === "https:" ? https : http;

  const options = {
    hostname: target.hostname,
    port: target.port || (target.protocol === "https:" ? 443 : 80),
    path: target.pathname + target.search,
    method: clientReq.method,
    headers: {
      ...clientReq.headers,
      host: target.host,
      "x-forwarded-by": "akai-inference-router",
    },
    timeout: CONFIG.requestTimeout,
  };

  const proxyReq = mod.request(options, (proxyRes) => {
    clientRes.writeHead(proxyRes.statusCode, {
      ...proxyRes.headers,
      "x-region": region,
      "x-fallback": String(isFallback),
      "x-router": "akai-inference-nodejs",
    });
    proxyRes.pipe(clientRes, { end: true });
  });

  proxyReq.on("error", (err) => {
    console.error(`[proxy error] ${region}: ${err.message}`);
    if (!clientRes.headersSent) {
      clientRes.writeHead(502, { "Content-Type": "application/json" });
    }
    clientRes.end(JSON.stringify({ error: "proxy_error", region, message: err.message }));
  });

  proxyReq.on("timeout", () => {
    proxyReq.destroy();
    if (!clientRes.headersSent) {
      clientRes.writeHead(504, { "Content-Type": "application/json" });
    }
    clientRes.end(JSON.stringify({ error: "timeout", region }));
  });

  clientReq.pipe(proxyReq, { end: true });
}

// ── HTTP Server ───────────────────────────────────────────────────────────────

const server = http.createServer((req, clientRes) => {
  const clientIp = getClientIp(req);
  const path = req.url.split("?")[0];

  // ── Built-in endpoints (no IP check) ─────────────────────────────────────
  if (path === "/health") {
    clientRes.writeHead(200, { "Content-Type": "application/json" });
    clientRes.end(JSON.stringify({ status: "ok", router: "nodejs" }));
    return;
  }

  if (path === "/ready") {
    const anyHealthy = health.chicago.healthy || health.seattle.healthy;
    clientRes.writeHead(anyHealthy ? 200 : 503, { "Content-Type": "application/json" });
    clientRes.end(JSON.stringify({ ready: anyHealthy, health }));
    return;
  }

  if (path === "/status") {
    clientRes.writeHead(200, { "Content-Type": "application/json" });
    clientRes.end(JSON.stringify({
      regions: health,
      config: { chicagoUrl: CONFIG.chicagoUrl, seattleUrl: CONFIG.seattleUrl },
      allowed_cidr: CONFIG.allowedCidr,
    }));
    return;
  }

  // ── IP Allowlist check ────────────────────────────────────────────────────
  if (!isIpAllowed(clientIp, CONFIG.allowedCidr)) {
    console.warn(`[403] Blocked request from ${clientIp} — not in ${CONFIG.allowedCidr}`);
    clientRes.writeHead(403, { "Content-Type": "application/json" });
    clientRes.end(JSON.stringify({
      error: "forbidden",
      message: "Access denied. Your IP is not in the allowed list.",
      your_ip: clientIp,
    }));
    return;
  }

  // ── Route to region ───────────────────────────────────────────────────────
  const { region, url, fallback, error } = selectRegion();

  if (!region) {
    clientRes.writeHead(503, { "Content-Type": "application/json" });
    clientRes.end(JSON.stringify({ error: "service_unavailable", detail: error, health }));
    return;
  }

  console.log(`[route] ${clientIp} → ${region}${fallback ? " (fallback)" : ""} ${req.method} ${req.url}`);
  proxyRequest(req, clientRes, url, region, fallback);
});

server.on("error", (err) => console.error("[server error]", err));

server.listen(CONFIG.port, "0.0.0.0", () => {
  console.log(`[akai-router] Listening on :${CONFIG.port}`);
  console.log(`[akai-router] Chicago: ${CONFIG.chicagoUrl}`);
  console.log(`[akai-router] Seattle: ${CONFIG.seattleUrl}`);
  console.log(`[akai-router] Allowed CIDR: ${CONFIG.allowedCidr}`);
  startHealthChecks();
});
