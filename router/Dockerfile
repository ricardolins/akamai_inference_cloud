# =============================================================================
# Dockerfile — Fallback inference router (Node.js)
# Used when Fermyon Spin is unavailable. Same routing logic, runs in Kubernetes.
# =============================================================================

FROM node:20-alpine AS base
WORKDIR /app
COPY package.json ./
COPY src/ ./src/

FROM node:20-alpine
LABEL org.opencontainers.image.title="akai-inference-router-fallback"
LABEL org.opencontainers.image.description="Node.js fallback router for Akamai Inference Cloud"

WORKDIR /app
RUN addgroup -S router && adduser -S router -G router
COPY --from=base --chown=router:router /app /app

USER router
EXPOSE 8080

HEALTHCHECK --interval=15s --timeout=5s --start-period=5s --retries=3 \
  CMD wget -qO- http://localhost:8080/health || exit 1

CMD ["node", "src/index.js"]
