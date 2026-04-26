/**
 * k6/config.js — Shared configuration for all test scenarios
 *
 * Usage:
 *   k6 run --env BASE_URL=http://<IP>:8000 smoke.js
 *   k6 run --env BASE_URL_CHICAGO=http://<IP>:8000 \
 *          --env BASE_URL_SEATTLE=http://<IP>:8000  failover.js
 *
 * Model name must match the MODEL_NAME in kubernetes/vllm/configmap.yaml
 */

export const MODEL = __ENV.MODEL || "mistralai/Mistral-7B-Instruct-v0.3";

export const BASE_URL          = __ENV.BASE_URL          || "http://REPLACE_WITH_VLLM_IP:8000";
export const BASE_URL_CHICAGO  = __ENV.BASE_URL_CHICAGO  || "http://REPLACE_WITH_CHICAGO_IP:8000";
export const BASE_URL_SEATTLE  = __ENV.BASE_URL_SEATTLE  || "http://REPLACE_WITH_SEATTLE_IP:8000";
export const ROUTER_URL        = __ENV.ROUTER_URL        || "http://REPLACE_WITH_ROUTER_IP:8080";

// Standard inference test prompts — short to keep latency predictable
export const TEST_PROMPTS = [
  "What is the capital of France? Answer in one word.",
  "What is 2 + 2? Answer with just the number.",
  "Name one primary color.",
  "What is the boiling point of water in Celsius? One number only.",
  "Who wrote Hamlet? Last name only.",
];

// Build an OpenAI-compatible chat completion request body
export function buildChatRequest(prompt) {
  return JSON.stringify({
    model: MODEL,
    messages: [{ role: "user", content: prompt }],
    max_tokens: 64,
    temperature: 0.1,
    stream: false,
  });
}

// Build a streaming request body (SSE)
export function buildStreamingRequest(prompt) {
  return JSON.stringify({
    model: MODEL,
    messages: [{ role: "user", content: prompt }],
    max_tokens: 128,
    temperature: 0.1,
    stream: true,
  });
}

// Standard request headers for vLLM
export const REQUEST_HEADERS = {
  "Content-Type": "application/json",
  "Accept": "application/json",
};

// Pick a random prompt from the list
export function randomPrompt() {
  return TEST_PROMPTS[Math.floor(Math.random() * TEST_PROMPTS.length)];
}

// Check thresholds shared across test files
export const COMMON_THRESHOLDS = {
  http_req_failed:   ["rate<0.05"],   // Error rate < 5%
  http_req_duration: ["p(95)<30000"], // 95th percentile < 30s (inference is slow)
};
