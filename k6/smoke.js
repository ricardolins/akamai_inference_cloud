/**
 * k6/smoke.js — Smoke test
 *
 * Purpose: Verify the vLLM endpoint is alive and returns valid responses.
 * Low load, short duration. Run after every deployment.
 *
 * Run:
 *   k6 run --env BASE_URL=http://<IP>:8000 k6/smoke.js
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Trend, Counter } from "k6/metrics";
import { BASE_URL, buildChatRequest, REQUEST_HEADERS, COMMON_THRESHOLDS } from "./config.js";

// Custom metrics
const inferenceLatency  = new Trend("inference_latency_ms", true);
const tokensGenerated   = new Counter("tokens_generated_total");
const inferenceErrors   = new Counter("inference_errors_total");

export const options = {
  vus: 1,
  iterations: 5,
  thresholds: {
    ...COMMON_THRESHOLDS,
    http_req_duration: ["p(95)<60000"], // Relax for smoke (cold model)
    http_req_failed:   ["rate<0.01"],   // Zero errors expected in smoke
  },
};

export default function () {
  // ── Test 1: Health check ────────────────────────────────────────────────────
  const healthRes = http.get(`${BASE_URL}/health`, { timeout: "10s" });
  check(healthRes, {
    "health endpoint returns 200": (r) => r.status === 200,
    "health response is JSON":     (r) => r.headers["Content-Type"]?.includes("application/json"),
  });

  // ── Test 2: Model list ───────────────────────────────────────────────────────
  const modelsRes = http.get(`${BASE_URL}/v1/models`, {
    headers: REQUEST_HEADERS,
    timeout: "10s",
  });
  check(modelsRes, {
    "models endpoint returns 200": (r) => r.status === 200,
    "models list is not empty":    (r) => {
      try {
        const body = JSON.parse(r.body);
        return body.data && body.data.length > 0;
      } catch { return false; }
    },
  });

  // ── Test 3: Single inference request ────────────────────────────────────────
  const startTime = Date.now();
  const inferenceRes = http.post(
    `${BASE_URL}/v1/chat/completions`,
    buildChatRequest("What is the capital of France? Answer in one word."),
    { headers: REQUEST_HEADERS, timeout: "120s" }
  );
  const latency = Date.now() - startTime;
  inferenceLatency.add(latency);

  const inferenceOk = check(inferenceRes, {
    "inference returns 200":           (r) => r.status === 200,
    "inference response has choices":  (r) => {
      try {
        const body = JSON.parse(r.body);
        return body.choices && body.choices.length > 0;
      } catch { return false; }
    },
    "inference response has content":  (r) => {
      try {
        const body = JSON.parse(r.body);
        const content = body.choices?.[0]?.message?.content;
        return content && content.length > 0;
      } catch { return false; }
    },
    "inference has usage stats":       (r) => {
      try {
        const body = JSON.parse(r.body);
        return body.usage && body.usage.completion_tokens > 0;
      } catch { return false; }
    },
  });

  if (!inferenceOk) {
    inferenceErrors.add(1);
    console.error(`Inference failed [${inferenceRes.status}]: ${inferenceRes.body?.substring(0, 200)}`);
  } else {
    try {
      const body = JSON.parse(inferenceRes.body);
      tokensGenerated.add(body.usage?.completion_tokens || 0);
      console.log(`✓ Response: "${body.choices[0].message.content}" (${latency}ms)`);
    } catch { /* non-JSON response already caught above */ }
  }

  sleep(2);
}

export function handleSummary(data) {
  console.log("\n════════ SMOKE TEST SUMMARY ════════");
  console.log(`Iterations:    ${data.metrics.iterations?.values?.count}`);
  console.log(`Errors:        ${data.metrics.http_req_failed?.values?.passes}`);
  console.log(`Latency p50:   ${data.metrics.inference_latency_ms?.values?.["p(50)"]}ms`);
  console.log(`Latency p95:   ${data.metrics.inference_latency_ms?.values?.["p(95)"]}ms`);
  console.log(`Tokens total:  ${data.metrics.tokens_generated_total?.values?.count}`);
  console.log("════════════════════════════════════\n");
  return {};
}
