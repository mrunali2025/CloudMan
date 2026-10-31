# syntax=docker/dockerfile:1

# =============================================================
# CloudMan — multi-target Dockerfile
#
# Usage:
#   docker build --target web    -t cloudman/web .
#   docker build --target api    -t cloudman/api .
#   docker build --target worker -t cloudman/worker .
#
# Or run all services together with:
#   docker compose -f docker-compose.prod.yml up
# =============================================================

# ── Base image: Node + Bun ────────────────────────────────────
FROM node:22-bookworm-slim AS base
ENV BUN_INSTALL=/usr/local
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates unzip gnupg \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL https://bun.sh/install | bash \
    && test -x "$BUN_INSTALL/bin/bun" \
    && "$BUN_INSTALL/bin/bun" --version
ENV PATH="/usr/local/bin:$PATH"
WORKDIR /app

# ── Dependencies (shared) ─────────────────────────────────────
FROM base AS deps
COPY . .
RUN bun install --frozen-lockfile

# ── Web (Next.js) ─────────────────────────────────────────────
FROM deps AS web
ENV NODE_ENV=production
WORKDIR /app/apps/web
RUN SKIP_ENV_VALIDATION=1 bun run build
ENV PORT=3001
EXPOSE 3001
CMD ["bun", "run", "start", "--port", "3001"]

# ── API (Hono) ────────────────────────────────────────────────
FROM deps AS api
ENV NODE_ENV=production
ENV PORT=4000
EXPOSE 4000
WORKDIR /app/apps/api
CMD ["bun", "run", "start"]

# ── Worker (BullMQ + OpenTofu) ────────────────────────────────
FROM deps AS worker
ENV NODE_ENV=production
ARG TOFU_VERSION=1.12.6
RUN curl -fsSL \
      "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_amd64.zip" \
      -o /tmp/tofu.zip \
    && unzip -o /tmp/tofu.zip -d /usr/local/bin tofu \
    && chmod +x /usr/local/bin/tofu \
    && rm /tmp/tofu.zip \
    && tofu version
ENV CLOUDMAN_TOFU_AUTOINSTALL=0
ENV CLOUDMAN_WORKSPACE_ROOT=/var/cloudman/workspaces
WORKDIR /app/apps/worker
CMD ["bun", "run", "start"]