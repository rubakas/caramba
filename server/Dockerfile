# syntax=docker/dockerfile:1
# check=error=true
#
# Multi-arch Caramba server image.
#
# Build context is the REPO ROOT (not server/) so the web-build stage
# can see the pnpm workspace it depends on. Always invoke as:
#
#   docker buildx build -f server/Dockerfile <repo-root>
#
# server/bin/build does this automatically.

ARG RUBY_VERSION=4.0.2
ARG NODE_VERSION=22

# ── React SPA build (platform-agnostic) ─────────────────────────────────
# Runs once on the BUILDPLATFORM so we don't pay QEMU emulation per target
# arch — JS bundles are platform-neutral. Output lands at /repo/web/dist/.
FROM --platform=$BUILDPLATFORM node:${NODE_VERSION}-alpine AS web-build
WORKDIR /repo
# Pin pnpm to the same major as the host (matches the lockfileVersion 9.0
# that the repo currently uses). pnpm 11+ treats unapproved build scripts
# (esbuild, @sentry/cli) as fatal; pnpm 10 only warns.
RUN corepack enable && corepack prepare pnpm@10.33.0 --activate

# Copy workspace metadata first so pnpm install gets cached separately
# from source changes.
COPY pnpm-workspace.yaml pnpm-lock.yaml package.json ./
COPY web/package.json web/
COPY ui/package.json ui/
COPY player/package.json player/
COPY desktop/package.json desktop/
COPY android-tv/package.json android-tv/
COPY tests/package.json tests/

# Install only web's workspace closure: web/ + ui/ + player/. android-tv/,
# desktop/, and tests/ (Playwright, Electron, Capacitor CLI) are not needed
# for a server-side SPA bundle. @capacitor/* is referenced from VideoPlayer.jsx
# but externalized in web/vite.config.js so rolldown leaves it as a literal
# import — never resolved at build time.
#
# --ignore-scripts skips any remaining postinstalls (e.g. @sentry/cli).
# esbuild's per-platform binary still lands via optionalDependencies,
# which aren't scripts.
# --frozen-lockfile keeps the image deterministic.
RUN pnpm install --frozen-lockfile --ignore-scripts --filter "@caramba/web..."

# Source for the packages web actually consumes.
COPY web web
COPY ui ui
COPY player player

RUN pnpm --filter @caramba/web exec vite build

# ── Ruby base (target-arch) ─────────────────────────────────────────────
FROM docker.io/library/ruby:${RUBY_VERSION}-slim AS base
ARG TARGETARCH

LABEL org.opencontainers.image.source="https://github.com/rubakas/caramba"
LABEL org.opencontainers.image.description="Caramba media server (Rails + jellyfin-rails) for UGREEN NAS / generic Linux."
LABEL org.opencontainers.image.licenses="MIT"

WORKDIR /rails

# Runtime packages.
#
# Cross-arch baseline (amd64 + arm64):
#   curl, libjemalloc2, libvips, sqlite3 — Rails baseline.
#   libva2, libva-drm2, libva-x11-2     — VAAPI runtime.
#   mesa-va-drivers                     — generic AMD/Mesa VAAPI fallback.
#   vainfo                              — debug helper inside the container.
#
# amd64 only — Intel Quick Sync stack. Lives in non-free, so we enable it
# first. Skipped on arm64 because the Intel packages are x86-only and
# arm64 deployments (Raspberry Pi etc.) don't have an Intel iGPU anyway:
#   intel-media-va-driver-non-free — iHD driver (Gen8+, incl. Alder/Raptor Lake)
#   i965-va-driver                 — legacy fallback for older Intel iGPUs
#
# Note: intel-opencl-icd is not packaged in Debian Trixie. OpenCL-based HDR
# tonemapping is therefore unavailable inside this image, but jellyfin-rails
# uses VAAPI tonemap by default on QSV anyway, so it's not blocking.
RUN set -eux; \
    if [ "$TARGETARCH" = "amd64" ]; then \
      sed -i 's/main$/main contrib non-free non-free-firmware/' /etc/apt/sources.list.d/debian.sources 2>/dev/null || \
      sed -i 's/main$/main contrib non-free non-free-firmware/' /etc/apt/sources.list; \
    fi; \
    apt-get update -qq; \
    apt-get install --no-install-recommends -y \
      curl ca-certificates xz-utils \
      libjemalloc2 libvips sqlite3 \
      libva2 libva-drm2 libva-x11-2 \
      mesa-va-drivers \
      vainfo; \
    if [ "$TARGETARCH" = "amd64" ]; then \
      apt-get install --no-install-recommends -y \
        intel-media-va-driver-non-free \
        i965-va-driver; \
    fi; \
    ln -s /usr/lib/$(uname -m)-linux-gnu/libjemalloc.so.2 /usr/local/lib/libjemalloc.so; \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development" \
    LD_PRELOAD="/usr/local/lib/libjemalloc.so"

# ── jellyfin-ffmpeg (target-arch) ───────────────────────────────────────
# Download the portable jellyfin-ffmpeg build that matches the target arch
# of THIS image (not the build host). When using buildx with --platform,
# Docker sets TARGETARCH automatically (amd64 | arm64). The version and
# layout mirror server/bin/setup-ffmpeg so the Rails initializer at
# config/initializers/jellyfin.rb finds it at vendor/ffmpeg/<dir>/ffmpeg.
FROM base AS ffmpeg
ARG TARGETARCH
ARG JELLYFIN_FFMPEG_VERSION=7.1.3-6
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) asset="linux64-gpl";     dir="linux-x64" ;; \
      arm64) asset="linuxarm64-gpl";  dir="linux-arm64" ;; \
      *) echo "Unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    url="https://github.com/jellyfin/jellyfin-ffmpeg/releases/download/v${JELLYFIN_FFMPEG_VERSION}/jellyfin-ffmpeg_${JELLYFIN_FFMPEG_VERSION}_portable_${asset}.tar.xz"; \
    mkdir -p "/ffmpeg/${dir}"; \
    echo "Downloading ${url}"; \
    curl -fsSL "${url}" -o /tmp/ffmpeg.tar.xz; \
    tar -xJf /tmp/ffmpeg.tar.xz -C "/ffmpeg/${dir}"; \
    rm /tmp/ffmpeg.tar.xz; \
    inner=$(ls "/ffmpeg/${dir}"); \
    if [ "$(echo "$inner" | wc -l)" = "1" ] && [ -d "/ffmpeg/${dir}/${inner}" ]; then \
      mv "/ffmpeg/${dir}/${inner}"/* "/ffmpeg/${dir}/"; \
      rmdir "/ffmpeg/${dir}/${inner}"; \
    fi; \
    test -x "/ffmpeg/${dir}/ffmpeg"; \
    test -x "/ffmpeg/${dir}/ffprobe"; \
    "/ffmpeg/${dir}/ffmpeg" -version

# ── Gem build stage ─────────────────────────────────────────────────────
FROM base AS build

RUN apt-get update -qq && \
    apt-get install --no-install-recommends -y build-essential git libyaml-dev pkg-config && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# Copy the whole vendor tree (jellyfin-rails engine + bundled JS + …) so
# bundler can resolve path:-style gems. Paths are relative to the repo
# root, not server/.
COPY server/vendor/ ./vendor/
COPY server/Gemfile server/Gemfile.lock ./

RUN bundle install && \
    rm -rf ~/.bundle/ "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git && \
    bundle exec bootsnap precompile -j 1 --gemfile

COPY server/ ./

RUN bundle exec bootsnap precompile -j 1 app/ lib/
RUN SECRET_KEY_BASE_DUMMY=1 ./bin/rails assets:precompile

# ── Final image ─────────────────────────────────────────────────────────
FROM base

# Non-root user. The render/video GIDs vary per host kernel, so the user is
# joined to the in-container `render` group at runtime via `group_add` in
# docker-compose.yml (UGREEN NAS uses GID 989 for /dev/dri/renderD128).
RUN groupadd --system --gid 1000 rails && \
    useradd rails --uid 1000 --gid 1000 --create-home --shell /bin/bash && \
    usermod -aG video,render rails 2>/dev/null || true

COPY --chown=rails:rails --from=build "${BUNDLE_PATH}" "${BUNDLE_PATH}"
COPY --chown=rails:rails --from=build /rails /rails
# Built React SPA from the Node stage — drops index.html, favicon.png, and
# assets/ alongside Rails' own error pages (400.html, 404.html, etc.).
COPY --chown=rails:rails --from=web-build /repo/web/dist/ /rails/public/
# Platform-matched jellyfin-ffmpeg.
COPY --chown=rails:rails --from=ffmpeg /ffmpeg /rails/vendor/ffmpeg

USER 1000:1000

ENTRYPOINT ["/rails/bin/docker-entrypoint"]

# Puma listens on PORT (defaults to 3000 from server/config/puma.rb). No
# Thruster reverse proxy — it's not in the Gemfile, and Rails 8 + Puma is
# enough for an API + small SPA. RAILS_SERVE_STATIC_FILES=1 lets Rails
# serve the built React assets from public/.
ENV PORT=3000 \
    RAILS_SERVE_STATIC_FILES=1
EXPOSE 3000
CMD ["./bin/rails", "server"]
