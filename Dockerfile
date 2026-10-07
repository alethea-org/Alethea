# Production image: a Mix release built and run on Debian.
#
# Follows the `mix phx.gen.release --docker` layout. The versions are pinned to
# the Elixir/OTP line CI tests against (.github/workflows/elixir.yml) and to a
# dated Debian snapshot, so a rebuild is reproducible.
#
#   - https://hub.docker.com/r/hexpm/elixir/tags?name=debian-trixie
#   - https://hub.docker.com/_/debian/tags?name=trixie-20260824-slim
#
# No secret and no DATABASE_URL is baked in: config/runtime.exs reads them from
# the environment when the release boots.

ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.5.0.5
ARG DEBIAN_VERSION=trixie-20260824-slim

ARG BUILDER_IMAGE="docker.io/hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="docker.io/debian:${DEBIAN_VERSION}"

# ============================================
# Stage 1: build the release
# ============================================
FROM ${BUILDER_IMAGE} AS builder

# No production dependency compiles native code today (the only NIF, lazy_html,
# is test-only). The toolchain stays so that adding one does not break the
# build; it never reaches the runner image.
RUN apt-get update \
  && apt-get install -y --no-install-recommends build-essential git \
  && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mix local.hex --force \
  && mix local.rebar --force

ENV MIX_ENV="prod"

# Dependencies first, so this layer is reused until mix.exs or mix.lock change.
COPY mix.exs mix.lock ./
RUN mix deps.get --only $MIX_ENV
RUN mkdir config

# Compile-time config only. Changing it recompiles the dependencies.
COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# priv carries the committed static assets (priv/static) and the migrations
# (priv/repo). There is no asset pipeline, so there is no asset build step.
COPY priv priv
COPY lib lib

RUN mix compile

# Runtime config is copied after compilation: changing it must not recompile.
COPY config/runtime.exs config/

COPY rel rel
RUN mix release

# ============================================
# Stage 2: run the release
# ============================================
FROM ${RUNNER_IMAGE} AS final

# ca-certificates is what lets the release verify TLS peers (the database and
# outbound HTTPS) against the system trust store.
RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 locales ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
  && locale-gen

ENV LANG="en_US.UTF-8"
ENV LANGUAGE="en_US:en"
ENV LC_ALL="en_US.UTF-8"

WORKDIR /app
RUN chown nobody /app

ENV MIX_ENV="prod"

COPY --from=builder --chown=nobody:root /app/_build/${MIX_ENV}/rel/alethea ./

USER nobody

EXPOSE 4000

# No image-level HEALTHCHECK: the slim runner has neither curl nor wget, and
# the platform probes GET /health and /health/ready over HTTP itself.

# bin/server sets PHX_SERVER=true; without it the endpoint does not listen.
CMD ["/app/bin/server"]
