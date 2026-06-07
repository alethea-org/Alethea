# ============================================
# Stage 1: Builder
# ============================================
FROM elixir:1.17-alpine AS builder

# Install build dependencies
RUN apk add --no-cache \
    build-base \
    git \
    nodejs \
    npm \
    inotify-tools

# Create app directory
WORKDIR /app

# Copy mix files first for better caching
COPY mix.exs mix.lock ./
COPY config ./config

# Install dependencies (cached if mix.exs/mix.lock unchanged)
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix deps.get

# Copy the rest of the application
COPY lib ./lib
COPY priv ./priv
COPY assets ./assets

# Build the application
RUN mix assets.deploy && \
    MIX_ENV=prod mix release

# ============================================
# Stage 2: Runtime
# ============================================
FROM alpine:3.19 AS runtime

# Install runtime dependencies
RUN apk add --no-cache \
    bash \
    libstdc++ \
    libgcc \
    libcrypto3 \
    libssl3 \
    ca-certificates \
    openssl

# Create app user
RUN addgroup -g 1000 app && \
    adduser -u 1000 -G app -s /bin/sh -D app

WORKDIR /app

# Copy the release from builder stage
COPY --from=builder /app/_build/prod/rel/alethea ./

# Copy the executable and libraries
COPY --from=builder --chown=app:app /app/_build/prod/rel/alethea/bin/* ./bin/
COPY --from=builder --chown=app:app /app/_build/prod/rel/alethea/lib ./lib

# Create necessary directories
RUN mkdir -p /app/tmp /app/logs && \
    chown -R app:app /app

USER app

# Expose port
EXPOSE 4000

# Set environment defaults
ENV MIX_ENV=prod
ENV PORT=4000

# Health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:4000/health || exit 1

# Run the application
CMD ["bin/alethea", "start"]