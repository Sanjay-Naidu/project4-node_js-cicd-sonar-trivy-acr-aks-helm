# syntax=docker/dockerfile:1.7
#
# Multi-stage build for orders-api.
#
# Design notes:
#   * Production dependencies are resolved in an isolated stage so npm, the
#     build cache and dev dependencies never reach the published image.
#   * Application files stay owned by root and the process runs as `node`,
#     so the container cannot rewrite its own code. Combined with the chart's
#     readOnlyRootFilesystem this leaves no writable path except /tmp.
#   * Base images are pinned by digest-able tag + version arg so a rebuild is
#     reproducible and Trivy findings map to a known base.

ARG NODE_VERSION=22.12.0
ARG ALPINE_VERSION=3.21

# ---------------------------------------------------------------------------
# Stage 1: production dependency resolution
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-alpine${ALPINE_VERSION} AS deps

WORKDIR /build

# Only the manifests are copied, so this layer is cached until dependencies
# actually change rather than on every source edit.
COPY package.json package-lock.json ./

# --ignore-scripts blocks arbitrary lifecycle code from transitive packages,
# which is the cheapest defence against a compromised dependency.
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --ignore-scripts

# ---------------------------------------------------------------------------
# Stage 2: runtime
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION}-alpine${ALPINE_VERSION} AS runtime

ARG APP_VERSION=0.0.0-dev
ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="orders-api" \
      org.opencontainers.image.description="Production-shaped Node.js REST API for the AKS DevSecOps pipeline" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="docker.io/library/node:${NODE_VERSION}-alpine${ALPINE_VERSION}"

ENV NODE_ENV=production \
    PORT=3000 \
    APP_VERSION=${APP_VERSION} \
    GIT_SHA=${GIT_SHA} \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NODE_OPTIONS="--max-http-header-size=16384"

# apk upgrade pulls the latest patched packages for the base layer, which is
# what closes most of the CVEs Trivy would otherwise report against the image.
# tini reaps zombies and forwards signals - without it a PID 1 Node process
# leaves defunct children behind on restart.
# hadolint ignore=DL3018
RUN apk upgrade --no-cache && \
    apk add --no-cache tini && \
    rm -rf /var/cache/apk/*

WORKDIR /app

# Copied as root-owned: the unprivileged runtime user gets read+execute only.
COPY --from=deps --chown=root:root /build/node_modules ./node_modules
COPY --chown=root:root src ./src
COPY --chown=root:root package.json ./

# `node` (uid 10001 is not available on this base; the stock uid 1000 `node`
# user is used and asserted by the chart's runAsUser).
USER node

EXPOSE 3000

# Redundant under Kubernetes (the kubelet probes win) but makes `docker run`
# and Compose behave correctly for local verification.
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3000)+'/healthz/ready').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "src/index.js"]
