// Plain script — no import/export. spin-js-engine (quickjs) runs this as a script,
// so top-level functions are global and __internal__ is injected by the runtime.

// ── Config ────────────────────────────────────────────────────────────────────

function cfgGet(key) {
  try {
    return __internal__.spin_sdk.config.get(key);
  } catch (_) {
    return null;
  }
}

// ── IP Allowlist ──────────────────────────────────────────────────────────────

function ipToInt(ip) {
  return ip.split(".").reduce(function(acc, o) { return ((acc << 8) | parseInt(o)) >>> 0; }, 0) >>> 0;
}

function isIpAllowed(clientIp, cidr) {
  try {
    var parts  = cidr.split("/");
    var prefix = parseInt(parts[1], 10);
    var mask   = prefix === 0 ? 0 : (~0 << (32 - prefix)) >>> 0;
    return (ipToInt(clientIp) & mask) === (ipToInt(parts[0]) & mask);
  } catch (_) {
    return false;
  }
}

function getClientIp(request) {
  var h = request.headers;
  if (h["x-forwarded-for"]) return h["x-forwarded-for"].split(",")[0].trim();
  if (h["x-real-ip"])       return h["x-real-ip"].trim();
  if (h["spin-client-addr"]) return h["spin-client-addr"].split(":")[0];
  return "0.0.0.0";
}

// ── Health Check ──────────────────────────────────────────────────────────────

async function checkHealth(url) {
  try {
    var res = await fetch(url + "/health");
    return res.ok;
  } catch (_) {
    return false;
  }
}

// ── Region Selection ──────────────────────────────────────────────────────────

function selectRegion(chicagoUrl, seattleUrl, chicagoOk, seattleOk) {
  if (!chicagoOk && !seattleOk) return null;
  if (!chicagoOk) return { region: "seattle", url: seattleUrl, fallback: true };
  if (!seattleOk) return { region: "chicago", url: chicagoUrl, fallback: true };
  var slot = Math.floor(Date.now() / 1000) % 2;
  return slot === 0
    ? { region: "chicago", url: chicagoUrl, fallback: false }
    : { region: "seattle", url: seattleUrl, fallback: false };
}

// ── Proxy ─────────────────────────────────────────────────────────────────────

async function proxyRequest(request, targetBaseUrl, region, fallback) {
  // request.uri is the full URL in hosted environments; extract path+query only
  var parsedUri = new URL(request.uri, "http://localhost");
  var targetUrl = targetBaseUrl + parsedUri.pathname + parsedUri.search;

  var upstreamRes = await fetch(targetUrl, {
    method:  request.method,
    headers: Object.assign({}, request.headers, { "x-forwarded-by": "akai-spin-fermyon" }),
    body:    (request.method === "GET" || request.method === "HEAD") ? undefined : request.body,
  });

  // spin-js-engine headers have entries() not forEach()
  var responseHeaders = {};
  var entries = upstreamRes.headers.entries();
  for (var i = 0; i < entries.length; i++) {
    responseHeaders[entries[i][0]] = entries[i][1];
  }
  responseHeaders["x-region"]   = region;
  responseHeaders["x-fallback"]  = String(fallback);
  responseHeaders["x-router"]   = "akai-spin-fermyon";

  // spin-js-engine fetch returns body via arrayBuffer(), not text()
  var buf  = await upstreamRes.arrayBuffer();
  var body = new TextDecoder().decode(buf);

  return {
    status:  upstreamRes.status,
    headers: responseHeaders,
    body:    body,
  };
}

// ── Main Handler + Engine Registration ───────────────────────────────────────

async function handleRequest(request) {
  var chicagoUrl  = cfgGet("chicago_vllm_url")  || "";
  var seattleUrl  = cfgGet("seattle_vllm_url")  || "";
  var allowedCidr = cfgGet("allowed_admin_cidr") || "127.0.0.1/32";

  var path = new URL(request.uri, "http://localhost").pathname;

  if (path === "/health") {
    return {
      status:  200,
      headers: { "content-type": "application/json" },
      body:    JSON.stringify({ status: "ok", router: "fermyon-spin" }),
    };
  }

  if (path === "/status") {
    var r = await Promise.all([checkHealth(chicagoUrl), checkHealth(seattleUrl)]);
    return {
      status:  200,
      headers: { "content-type": "application/json" },
      body:    JSON.stringify({
        router: "fermyon-spin",
        regions: {
          chicago: { url: chicagoUrl, healthy: r[0] },
          seattle: { url: seattleUrl, healthy: r[1] },
        },
        allowed_cidr: allowedCidr,
      }),
    };
  }

  // IP check
  var clientIp = getClientIp(request);
  if (!isIpAllowed(clientIp, allowedCidr)) {
    return {
      status:  403,
      headers: { "content-type": "application/json" },
      body:    JSON.stringify({ error: "forbidden", your_ip: clientIp }),
    };
  }

  // Health + routing
  var health = await Promise.all([checkHealth(chicagoUrl), checkHealth(seattleUrl)]);
  var route = selectRegion(chicagoUrl, seattleUrl, health[0], health[1]);

  if (!route) {
    return {
      status:  503,
      headers: { "content-type": "application/json" },
      body:    JSON.stringify({
        error: "service_unavailable",
        regions: { chicago: health[0], seattle: health[1] },
      }),
    };
  }

  try {
    return await proxyRequest(request, route.url, route.region, route.fallback);
  } catch (err) {
    var fbUrl    = route.region === "chicago" ? seattleUrl : chicagoUrl;
    var fbRegion = route.region === "chicago" ? "seattle"  : "chicago";
    try {
      return await proxyRequest(request, fbUrl, fbRegion, true);
    } catch (fbErr) {
      return {
        status:  502,
        headers: { "content-type": "application/json" },
        body:    JSON.stringify({ error: "bad_gateway", primary: String(err), fallback: String(fbErr) }),
      };
    }
  }
}

// spin-js-engine looks for spin.handleRequest or spin.handler in the global scope
var spin = { handleRequest: handleRequest };
