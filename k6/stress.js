/**
 * k6/stress.js — Stress test
 *
 * Purpose: Find the breaking point of vLLM on RTX 4000 Ada.
 * Ramps beyond GPU capacity to measure OOM behavior, queue growth, and recovery.
 *
 * WARNING: This WILL cause request failures and OOM conditions.
 * Monitor GPU memory in Grafana during the test.
 * Run after smoke + load tests succeed.
 *
 * Run:
 *   k6 run --env BASE_URL=http://<IP>:8000 k6/stress.js
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Trend, Counter, Rate } from "k6/metrics";
import { BASE_URL, buildChatRequest, REQUEST_HEADERS, randomPrompt } from "./config.js";

const inferenceLatency = new Trend("stress_latency_ms", true);
const errorRate        = new Rate("stress_error_rate");
const oomErrors        = new Counter("oom_errors_total");
const timeoutErrors    = new Counter("timeout_errors_total");

export const options = {
  stages: [
    { duration: "1m",  target: 1  },  // Baseline
    { duration: "2m",  target: 4  },  // Above saturation
    { duration: "3m",  target: 8  },  // Heavy stress
    { duration: "2m",  target: 12 },  // Breaking point
    { duration: "2m",  target: 4  },  // Recovery test
    { duration: "2m",  target: 1  },  // Full recovery
    { duration: "1m",  target: 0  },
  ],
  thresholds: {
    // Stress test — we accept higher error rates but want to measure, not fail
    "stress_error_rate": ["rate<0.50"],    // Up to 50% errors expected
    "stress_latency_ms": ["p(95)<120000"], // 2 min max under stress
  },
};

export default function () {
  const prompt = randomPrompt();
  const start  = Date.now();

  const res = http.post(
    `${BASE_URL}/v1/chat/completions`,
    buildChatRequest(prompt),
    {
      headers: REQUEST_HEADERS,
      timeout: "120s",
      tags: { test_type: "stress" },
    }
  );

  const latency = Date.now() - start;
  inferenceLatency.add(latency);

  if (res.status === 0) {
    // Network timeout
    timeoutErrors.add(1);
    errorRate.add(1);
  } else if (res.status === 503 || res.status === 429) {
    // vLLM queue full or CUDA OOM
    if (res.body?.includes("CUDA out of memory") || res.body?.includes("OOM")) {
      oomErrors.add(1);
      console.warn(`[OOM] GPU out of memory at VU ${__VU}`);
    }
    errorRate.add(1);
  } else if (res.status === 200) {
    errorRate.add(0);
    check(res, {
      "valid response body": (r) => {
        try { return JSON.parse(r.body).choices?.length > 0; } catch { return false; }
      },
    });
  } else {
    errorRate.add(1);
    console.error(`[STRESS] Unexpected status ${res.status}`);
  }

  // No sleep — maximize pressure
  sleep(0.5);
}

export function handleSummary(data) {
  const m = data.metrics;
  console.log("\n════════ STRESS TEST SUMMARY ════════");
  console.log(`Total requests: ${m.http_reqs?.values?.count}`);
  console.log(`Error rate:     ${(m.stress_error_rate?.values?.rate * 100).toFixed(2)}%`);
  console.log(`OOM errors:     ${m.oom_errors_total?.values?.count}`);
  console.log(`Timeouts:       ${m.timeout_errors_total?.values?.count}`);
  console.log(`Latency p50:    ${m.stress_latency_ms?.values?.["p(50)"]?.toFixed(0)}ms`);
  console.log(`Latency p95:    ${m.stress_latency_ms?.values?.["p(95)"]?.toFixed(0)}ms`);
  console.log(`Latency max:    ${m.stress_latency_ms?.values?.["max"]?.toFixed(0)}ms`);
  console.log("\nCheck Grafana for:");
  console.log("  - VRAM peak usage (should be < 20GB)");
  console.log("  - GPU temperature (should be < 85°C)");
  console.log("  - Recovery: latency should return to baseline");
  console.log("══════════════════════════════════════\n");
  return {};
}
