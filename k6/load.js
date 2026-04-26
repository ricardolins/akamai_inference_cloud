/**
 * k6/load.js — Load test
 *
 * Purpose: Measure GPU throughput, latency, and error rate under sustained load.
 * Ramps up to a realistic concurrency level and holds for 5 minutes.
 *
 * Run:
 *   k6 run --env BASE_URL=http://<IP>:8000 k6/load.js
 *
 * Expected results on RTX 4000 Ada with Mistral-7B:
 *   - ~2-4 concurrent requests saturate the GPU
 *   - TTFT p50 ~2-5s, p95 ~10-15s under load
 *   - Throughput ~25-40 tokens/sec per request
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Trend, Counter, Rate } from "k6/metrics";
import { BASE_URL, buildChatRequest, REQUEST_HEADERS, randomPrompt, COMMON_THRESHOLDS } from "./config.js";

const inferenceLatency = new Trend("inference_latency_ms", true);
const tokensGenerated  = new Counter("tokens_generated_total");
const errorRate        = new Rate("inference_error_rate");
const queuedRequests   = new Counter("queued_requests_total");

export const options = {
  stages: [
    { duration: "1m",  target: 1 },  // Warm up — 1 concurrent user
    { duration: "2m",  target: 2 },  // Ramp to 2 (near GPU saturation for 7B model)
    { duration: "5m",  target: 2 },  // Hold at 2
    { duration: "1m",  target: 4 },  // Brief spike to 4
    { duration: "2m",  target: 2 },  // Back to steady state
    { duration: "1m",  target: 0 },  // Ramp down
  ],
  thresholds: {
    ...COMMON_THRESHOLDS,
    "inference_latency_ms": ["p(50)<15000", "p(95)<45000"],
    "inference_error_rate":  ["rate<0.05"],
    "http_req_failed":       ["rate<0.05"],
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
      timeout: "180s",
      tags: { test_type: "load" },
    }
  );

  const latency = Date.now() - start;
  inferenceLatency.add(latency);

  const ok = check(res, {
    "status 200":         (r) => r.status === 200,
    "has choices":        (r) => {
      try { return JSON.parse(r.body).choices?.length > 0; } catch { return false; }
    },
    "latency under 60s":  () => latency < 60000,
  });

  if (!ok) {
    errorRate.add(1);
    // Detect queue full (429 = too many requests)
    if (res.status === 429) queuedRequests.add(1);
    console.error(`[FAIL] ${res.status} latency=${latency}ms body=${res.body?.substring(0, 100)}`);
  } else {
    errorRate.add(0);
    try {
      const body = JSON.parse(res.body);
      tokensGenerated.add(body.usage?.completion_tokens || 0);
    } catch { /* ignore */ }
  }

  // Realistic think time between requests (simulates batched workload)
  sleep(Math.random() * 3 + 1);
}

export function handleSummary(data) {
  const m = data.metrics;
  console.log("\n════════ LOAD TEST SUMMARY ════════");
  console.log(`Duration:        12 minutes`);
  console.log(`Total requests:  ${m.http_reqs?.values?.count}`);
  console.log(`Error rate:      ${(m.http_req_failed?.values?.rate * 100).toFixed(2)}%`);
  console.log(`Latency p50:     ${m.inference_latency_ms?.values?.["p(50)"]?.toFixed(0)}ms`);
  console.log(`Latency p95:     ${m.inference_latency_ms?.values?.["p(95)"]?.toFixed(0)}ms`);
  console.log(`Latency p99:     ${m.inference_latency_ms?.values?.["p(99)"]?.toFixed(0)}ms`);
  console.log(`Tokens total:    ${m.tokens_generated_total?.values?.count}`);
  console.log(`Throughput:      ${(m.tokens_generated_total?.values?.count / 720).toFixed(1)} tokens/sec avg`);
  console.log("═══════════════════════════════════\n");
  return {};
}
