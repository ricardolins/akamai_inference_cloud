/**
 * k6/failover.js — Multi-region failover test
 *
 * Purpose: Validate that the router (Fermyon or Node.js) automatically
 * redirects traffic to the healthy region when one region goes down.
 *
 * Test sequence:
 *   Phase 1 — Both regions up: verify load is distributed
 *   Phase 2 — Simulate Chicago down: verify all traffic goes to Seattle
 *   Phase 3 — Chicago restored: verify traffic resumes normal distribution
 *
 * NOTE: Phase 2 requires manually stopping vLLM in Chicago or using the
 *       test-routing.sh script to temporarily block the service.
 *       The script prompts you for each phase.
 *
 * Run:
 *   k6 run \
 *     --env BASE_URL_CHICAGO=http://<CHICAGO-IP>:8000 \
 *     --env BASE_URL_SEATTLE=http://<SEATTLE-IP>:8000 \
 *     --env ROUTER_URL=http://<ROUTER-IP>:8080 \
 *     k6/failover.js
 */

import http from "k6/http";
import { check, sleep, group } from "k6";
import { Counter, Rate, Trend } from "k6/metrics";
import {
  BASE_URL_CHICAGO, BASE_URL_SEATTLE, ROUTER_URL,
  buildChatRequest, REQUEST_HEADERS, randomPrompt
} from "./config.js";

const chicagoRequests = new Counter("chicago_requests_total");
const seattleRequests = new Counter("seattle_requests_total");
const fallbackHits    = new Counter("fallback_hits_total");
const errorRate       = new Rate("failover_error_rate");
const routerLatency   = new Trend("router_latency_ms", true);

export const options = {
  scenarios: {
    // Phase 1: Both regions healthy — hit router
    both_regions_up: {
      executor: "constant-vus",
      vus: 2,
      duration: "3m",
      startTime: "0s",
      tags: { phase: "both_up" },
    },
    // Phase 2: Chicago down — router should auto-failover to Seattle
    chicago_down: {
      executor: "constant-vus",
      vus: 2,
      duration: "3m",
      startTime: "3m",
      tags: { phase: "chicago_down" },
      env: { SIMULATE_FAILOVER: "true" },
    },
    // Phase 3: Recovery — both regions healthy again
    recovery: {
      executor: "constant-vus",
      vus: 2,
      duration: "3m",
      startTime: "6m",
      tags: { phase: "recovery" },
    },
  },
  thresholds: {
    "failover_error_rate": ["rate<0.10"],    // Max 10% errors during failover
    "router_latency_ms":   ["p(95)<45000"],
    "http_req_failed":     ["rate<0.10"],
  },
};

// ── Direct region health check ─────────────────────────────────────────────

function checkRegionDirect(url, region) {
  const res = http.get(`${url}/health`, { timeout: "5s", tags: { region } });
  return res.status === 200;
}

// ── Route via router and record which region served the request ────────────

function routeViaRouter(prompt) {
  const start = Date.now();
  const res = http.post(
    `${ROUTER_URL}/v1/chat/completions`,
    buildChatRequest(prompt),
    {
      headers: REQUEST_HEADERS,
      timeout: "120s",
    }
  );
  routerLatency.add(Date.now() - start);

  const region = res.headers["X-Region"] || res.headers["x-region"] || "unknown";
  const isFallback = res.headers["X-Fallback"] === "true" || res.headers["x-fallback"] === "true";

  if (region.includes("chicago")) chicagoRequests.add(1);
  if (region.includes("seattle")) seattleRequests.add(1);
  if (isFallback) fallbackHits.add(1);

  return { res, region, isFallback };
}

// ── Main test function ─────────────────────────────────────────────────────

export default function () {
  const phase = __ENV.SIMULATE_FAILOVER === "true" ? "chicago_down" : "normal";
  const prompt = randomPrompt();

  if (phase === "chicago_down") {
    // During failover phase: verify Seattle is serving all requests
    group("failover — chicago down", () => {
      const { res, region, isFallback } = routeViaRouter(prompt);

      const ok = check(res, {
        "router returns 200 during failover":     (r) => r.status === 200,
        "request served by seattle (not chicago)": () => region === "seattle",
        "fallback flag is set":                    () => isFallback === true,
        "response has valid inference":            (r) => {
          try { return JSON.parse(r.body).choices?.length > 0; } catch { return false; }
        },
      });

      if (!ok) {
        errorRate.add(1);
        console.error(`[FAILOVER FAIL] region=${region} status=${res.status}`);
      } else {
        errorRate.add(0);
        console.log(`[FAILOVER OK] routed to ${region} (fallback=${isFallback})`);
      }
    });
  } else {
    // Normal operation: both regions should share traffic
    group("normal routing — both regions", () => {
      // Also directly test each region
      const chicagoOk = checkRegionDirect(BASE_URL_CHICAGO, "chicago");
      const seattleOk = checkRegionDirect(BASE_URL_SEATTLE, "seattle");

      check({ chicagoOk, seattleOk }, {
        "chicago is healthy": ({ chicagoOk }) => chicagoOk,
        "seattle is healthy": ({ seattleOk }) => seattleOk,
      });

      const { res, region } = routeViaRouter(prompt);

      const ok = check(res, {
        "router returns 200":           (r) => r.status === 200,
        "region header is present":     () => region !== "unknown",
        "valid inference response":     (r) => {
          try { return JSON.parse(r.body).choices?.length > 0; } catch { return false; }
        },
      });

      errorRate.add(ok ? 0 : 1);
      if (!ok) console.error(`[NORMAL FAIL] region=${region} status=${res.status}`);
    });
  }

  sleep(2);
}

export function handleSummary(data) {
  const m = data.metrics;
  const total = (m.chicago_requests_total?.values?.count || 0) + (m.seattle_requests_total?.values?.count || 0);

  console.log("\n════════ FAILOVER TEST SUMMARY ════════");
  console.log(`Total routed requests: ${total}`);
  console.log(`  Chicago:             ${m.chicago_requests_total?.values?.count || 0}`);
  console.log(`  Seattle:             ${m.seattle_requests_total?.values?.count || 0}`);
  console.log(`  Fallback activations:${m.fallback_hits_total?.values?.count || 0}`);
  console.log(`Error rate:            ${((m.failover_error_rate?.values?.rate || 0) * 100).toFixed(2)}%`);
  console.log(`Router latency p50:    ${m.router_latency_ms?.values?.["p(50)"]?.toFixed(0)}ms`);
  console.log(`Router latency p95:    ${m.router_latency_ms?.values?.["p(95)"]?.toFixed(0)}ms`);
  console.log("\nExpected for passing failover:");
  console.log("  Phase 2 (chicago_down): 100% of requests → seattle + fallback=true");
  console.log("  Phase 3 (recovery):     traffic resumes distribution between regions");
  console.log("═══════════════════════════════════════\n");
  return {};
}
