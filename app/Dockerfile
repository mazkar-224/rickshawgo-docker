# syntax=docker/dockerfile:1
#
# RickshawGo API - production image
#   - multi-stage: dependencies are installed in a throwaway stage, only the result is copied
#   - only production dependencies, installed exactly from package-lock.json (npm ci)
#   - runs as the unprivileged "node" user (uid 1000); the code is owned by root, so the app can't change it
#   - built-in HEALTHCHECK (plain Node, no curl/wget needed)

ARG NODE_VERSION=24

# ---- stage 1: install production dependencies -------------------------------------------
FROM node:${NODE_VERSION}-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund \
 && npm cache clean --force

# ---- stage 2: the runtime image ----------------------------------------------------------
FROM node:${NODE_VERSION}-alpine AS runtime

LABEL org.opencontainers.image.title="rickshawgo-api" \
      org.opencontainers.image.description="RickshawGo live API (Node.js / Express), DevOps bootcamp assignment 4" \
      org.opencontainers.image.source="https://github.com/mazkar-224/rickshawgo-docker" \
      org.opencontainers.image.licenses="MIT"

ENV NODE_ENV=production \
    HOST=0.0.0.0 \
    PORT=3000

# the running app never needs a package manager: removing npm/yarn takes them (and their
# frequently CVE-flagged bundled dependencies) out of the running container's attack surface
RUN rm -rf /usr/local/lib/node_modules /usr/local/bin/npm /usr/local/bin/npx \
           /usr/local/bin/corepack /opt/yarn* /usr/local/bin/yarn /usr/local/bin/yarnpkg

WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package.json server.js healthcheck.js ./

# drop root: the official image ships an unprivileged "node" user; numeric uid:gid so that
# runtimes (and Kubernetes runAsNonRoot) can verify it is not root without reading /etc/passwd
USER 1000:1000

EXPOSE 3000

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD ["node", "healthcheck.js"]

# exec form: node gets the signals itself (and handles SIGTERM gracefully, see server.js)
CMD ["node", "server.js"]
