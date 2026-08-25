# --- Build stage ---
FROM golang:1.26-alpine AS builder

RUN apk add --no-cache git

WORKDIR /src

# Cache dependencies
COPY server/go.mod server/go.sum ./server/
RUN cd server && go mod download

# Copy server source
COPY server/ ./server/

# Build binaries
ARG VERSION=dev
ARG COMMIT=unknown
ARG DATE=unknown
RUN cd server && CGO_ENABLED=0 go build -ldflags "-s -w -X main.version=${VERSION} -X main.commit=${COMMIT}" -o bin/server ./cmd/server
RUN cd server && CGO_ENABLED=0 go build -ldflags "-s -w -X main.version=${VERSION} -X main.commit=${COMMIT} -X main.date=${DATE}" -o bin/multica ./cmd/multica
RUN cd server && CGO_ENABLED=0 go build -ldflags "-s -w" -o bin/migrate ./cmd/migrate
RUN cd server && CGO_ENABLED=0 go build -ldflags "-s -w" -o bin/backfill_task_usage_hourly ./cmd/backfill_task_usage_hourly
RUN cd server && CGO_ENABLED=0 go build -ldflags "-s -w" -o bin/backfill_codex_usage_cache ./cmd/backfill_codex_usage_cache

# --- Runtime stage ---
FROM alpine:3.21

# The Railway backend also hosts the Multica daemon. Keep the runtime image
# self-contained so `multica daemon start` can discover and execute OpenCode
# after an operator connects with `railway ssh`.
ARG OPENCODE_VERSION=1.18.23
RUN apk add --no-cache \
    bash \
    ca-certificates \
    curl \
    git \
    libgcc \
    libstdc++ \
    nodejs \
    npm \
    openssh-client \
    tzdata \
    && npm install --global "opencode-ai@${OPENCODE_VERSION}" \
    && npm cache clean --force

WORKDIR /app

# Railway mounts the backend volume at /app/data. Persist the CLI daemon state,
# OpenCode credentials/configuration, task workspaces, and local uploads there.
ENV HOME=/app/data/home \
    MULTICA_DATA_ROOT=/app/data \
    MULTICA_WORKSPACES_ROOT=/app/data/workspaces \
    XDG_CONFIG_HOME=/app/data/home/.config \
    XDG_DATA_HOME=/app/data/home/.local/share \
    XDG_STATE_HOME=/app/data/home/.local/state \
    OPENCODE_CONFIG_DIR=/app/data/home/.config/opencode \
    OPENCODE_DISABLE_AUTOUPDATE=true \
    MULTICA_DAEMON_AUTO_START=true \
    MULTICA_DAEMON_AUTO_START_INTERVAL=30 \
    PATH=/app:/app/data/home/.local/bin:$PATH

COPY --from=builder /src/server/bin/server .
COPY --from=builder /src/server/bin/multica .
COPY --from=builder /src/server/bin/migrate .
COPY --from=builder /src/server/bin/backfill_task_usage_hourly .
COPY --from=builder /src/server/bin/backfill_codex_usage_cache .
COPY server/migrations/ ./migrations/
COPY LICENSE NOTICE ./
COPY docker/entrypoint.sh .
RUN sed -i 's/\r$//' entrypoint.sh && chmod +x entrypoint.sh && \
    ln -s /app/multica /usr/local/bin/multica

EXPOSE 8080

ENTRYPOINT ["./entrypoint.sh"]
