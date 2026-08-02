# ---- build stage -----------------------------------------------------------
FROM hexpm/elixir:1.16.2-erlang-26.2.5.9-debian-bookworm-20260610-slim AS build

ENV MIX_ENV=prod
WORKDIR /app

RUN apt-get update -y && \
    apt-get install -y build-essential git curl && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN mix local.hex --force && mix local.rebar --force

# Dependency layer first for cache friendliness.
COPY mix.exs mix.lock ./
COPY apps/flux/mix.exs apps/flux/
COPY apps/flux_engine/mix.exs apps/flux_engine/
COPY apps/flux_plugin_runtime/mix.exs apps/flux_plugin_runtime/
COPY apps/flux_rag/mix.exs apps/flux_rag/
COPY apps/flux_web/mix.exs apps/flux_web/
COPY packages/flux_plugin packages/flux_plugin
COPY config config
# Dependencies are vendored from the build context (mix.lock governs
# them): hex.pm fetches from inside the build hit a hard 120s stall on
# large tarballs under Docker Desktop/WSL2 networking.
COPY deps deps
RUN mix deps.compile

COPY apps apps
# The in-app docs viewer compiles the guides into the release.
COPY docs/guides docs/guides
RUN mix compile

# Tailwind/esbuild binaries download on first use.
RUN cd apps/flux_web && mix assets.deploy

RUN mix release flux

# ---- runtime stage ----------------------------------------------------------
FROM debian:bookworm-20260610-slim AS app

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses6 locales ca-certificates && \
    apt-get clean && rm -f /var/lib/apt/lists/*_* && \
    sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN useradd --create-home flux
USER flux

COPY --from=build --chown=flux:flux /app/_build/prod/rel/flux ./

ENV PHX_SERVER=true
EXPOSE 4000

# Migrations run before boot; seeds are idempotent.
CMD ["sh", "-c", "bin/flux eval 'Flux.Release.migrate()' && bin/flux start"]
