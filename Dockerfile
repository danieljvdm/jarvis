# Install OpenClaw from the published npm release package. Building the source
# tree in Railway can hang in tsdown; the npm package ships compiled dist files.
FROM node:22-bookworm AS openclaw-package
WORKDIR /openclaw

# Keep the legacy build arg name because Railway already has it configured.
ARG OPENCLAW_GIT_REF=v2026.5.27
RUN set -eux; \
  OPENCLAW_VERSION="${OPENCLAW_GIT_REF#v}"; \
  npm pack "openclaw@${OPENCLAW_VERSION}" --pack-destination /tmp; \
  tar -xzf "/tmp/openclaw-${OPENCLAW_VERSION}.tgz" -C /openclaw --strip-components=1; \
  npm install --omit=dev; \
  npm cache clean --force; \
  node dist/entry.js --version


# Runtime image
FROM node:22-bookworm
ENV NODE_ENV=production

# System packages:
#   - tini: PID 1 / signal handling
#   - build-essential, file, procps: native package build/runtime diagnostics
#   - tmux, ripgrep, fzf: dev tools (baked in so they're always available)
#   - gnupg, curl: needed for 1Password CLI apt repo setup
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    tini \
    python3 \
    python3-venv \
    build-essential \
    file \
    procps \
    git \
    curl \
    wget \
    unzip \
    gnupg \
    tmux \
    ripgrep \
    fzf \
    neovim \
    zsh \
  && curl -sS https://downloads.1password.com/linux/keys/1password.asc \
    | gpg --dearmor --output /usr/share/keyrings/1password-archive-keyring.gpg \
  && echo "deb [signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/$(dpkg --print-architecture) stable main" \
    | tee /etc/apt/sources.list.d/1password.list \
  && curl -fsSL https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg \
    | tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null \
  && echo "deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian bookworm main" \
    | tee /etc/apt/sources.list.d/tailscale.list \
  && apt-get update \
  && apt-get install -y --no-install-recommends 1password-cli tailscale \
  && rm -rf /var/lib/apt/lists/* \
  && chsh -s /bin/zsh

ENV SHELL=/bin/zsh

# chezmoi — for dotfiles management
RUN sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /usr/local/bin

# uv/uvx — used to run codex-lb in the Railway container.
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# pnpm — used by openclaw update and skill installs
RUN corepack enable && corepack prepare pnpm@10.23.0 --activate

# qmd — semantic search CLI/MCP for the Obsidian vault. Install it in the image
# so first boot can start the HTTP wrapper before Fly's health check window ends.
RUN npm install -g @tobilu/qmd && npm cache clean --force

# User-installed tools and config persist to /data.
#
# npm/pnpm globals  -> /data/npm, /data/pnpm
# chezmoi source    -> /data/.local/share/chezmoi  (cloned at runtime on first boot)
ENV XDG_CONFIG_HOME=/data/.config
ENV XDG_CACHE_HOME=/data/.cache
ENV NPM_CONFIG_PREFIX=/data/npm
ENV NPM_CONFIG_CACHE=/data/npm-cache
ENV PNPM_HOME=/data/pnpm
ENV PNPM_STORE_DIR=/data/pnpm-store
ENV PATH="/data/npm/bin:/data/pnpm:${PATH}"

WORKDIR /app

# Wrapper deps
COPY package.json ./
RUN npm install --omit=dev && npm cache clean --force

# Copy packaged openclaw
COPY --from=openclaw-package /openclaw /openclaw

# Provide an openclaw executable
RUN printf '%s\n' '#!/usr/bin/env bash' 'exec node /openclaw/dist/entry.js "$@"' > /usr/local/bin/openclaw \
  && chmod +x /usr/local/bin/openclaw

COPY src ./src
RUN chmod +x /app/src/init.sh /app/src/start.sh /app/src/codex-lb-supervisor.sh

EXPOSE 8080

ENTRYPOINT ["tini", "--"]
CMD ["/app/src/start.sh"]
