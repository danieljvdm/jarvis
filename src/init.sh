#!/usr/bin/env bash
# init.sh — runs on every container boot before the Node server starts.
# /data is the provider-mounted persistent volume, so runtime state survives redeploys.
set -euo pipefail

log() { echo "[init] $*"; }

# ── Tailscale ─────────────────────────────────────────────────────────────────
# Persist Tailscale state to /data so auth survives redeploys.
# Set TS_AUTHKEY in host secrets (reusable key, tagged tag:server).
TS_STATE_DIR="/data/tailscale"
TS_SOCK="/var/run/tailscale/tailscaled.sock"
mkdir -p "$TS_STATE_DIR" /var/run/tailscale
log "Starting tailscaled..."
tailscaled --state="${TS_STATE_DIR}/tailscaled.state" \
  --socket="${TS_SOCK}" \
  --tun=userspace-networking &
sleep 2

if tailscale status &>/dev/null; then
  log "Tailscale already authenticated."
else
  if [ -n "${TS_AUTHKEY:-}" ]; then
    log "Authenticating Tailscale with auth key..."
    tailscale up --authkey="${TS_AUTHKEY}" --hostname=jarvis
  else
    log "WARNING: Tailscale not authenticated and TS_AUTHKEY not set."
    log "SSH in and run: tailscale up"
  fi
fi

# Set up tailscale serve to proxy the gateway port over the tailnet.
# This runs every boot since the serve config doesn't persist (ephemeral filesystem).
if tailscale status &>/dev/null; then
  log "Setting up tailscale serve for port 18789..."
  tailscale serve --bg --yes 18789 || log "WARNING: tailscale serve failed (HTTPS may not be enabled on tailnet)"
fi

# ── openclaw config patches ───────────────────────────────────────────────────
# - gateway.trustedProxies = ["loopback"] for reverse proxies
# - gateway.tailscale.mode = "serve" for tailnet-only dashboard access
# - codex-lb providers for OpenClaw model traffic
OPENCLAW_STATE_DIR="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
OPENCLAW_WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-/data/workspace}"
OPENCLAW_CFG="${OPENCLAW_STATE_DIR}/openclaw.json"

if [ ! -f "$OPENCLAW_CFG" ] && command -v openclaw >/dev/null 2>&1; then
  log "OpenClaw config not found; running non-interactive onboarding with auth-choice=skip..."
  mkdir -p "$OPENCLAW_STATE_DIR" "$OPENCLAW_WORKSPACE_DIR"
  openclaw onboard \
    --non-interactive \
    --accept-risk \
    --json \
    --no-install-daemon \
    --skip-health \
    --skip-channels \
    --skip-skills \
    --skip-search \
    --workspace "$OPENCLAW_WORKSPACE_DIR" \
    --gateway-bind loopback \
    --gateway-port 18789 \
    --gateway-auth token \
    --gateway-token "${OPENCLAW_GATEWAY_TOKEN:-}" \
    --flow quickstart \
    --auth-choice skip \
    --suppress-gateway-token-output \
    || log "WARNING: OpenClaw onboarding failed; /setup can still be used manually."
fi

if [ -f "$OPENCLAW_CFG" ]; then
  export OPENCLAW_CFG
  python3 - << 'PYEOF'
import json
import os
path = os.environ["OPENCLAW_CFG"]
with open(path) as f:
    cfg = json.load(f)
changed = False
gw = cfg.setdefault("gateway", {})
if gw.get("bind") != "loopback":
    gw["bind"] = "loopback"
    changed = True
    print("[init] set gateway.bind = loopback")
if gw.get("trustedProxies") != ["loopback"]:
    gw["trustedProxies"] = ["loopback"]
    changed = True
    print("[init] set gateway.trustedProxies = [loopback]")
ts = gw.setdefault("tailscale", {})
if ts.get("mode") != "serve":
    ts["mode"] = "serve"
    changed = True
    print("[init] set gateway.tailscale.mode = serve")
ui = gw.setdefault("controlUi", {})
origins = ui.get("allowedOrigins", [])
for origin in [
    "https://jarvis.tail51d7a2.ts.net",
    "https://openclaw-broken-fire-2366.fly.dev",
]:
    if origin not in origins:
        origins.append(origin)
        changed = True
        print(f"[init] added {origin} to controlUi.allowedOrigins")
if changed:
    ui["allowedOrigins"] = origins

codex_lb_models = [
    {
        "id": "gpt-5.5",
        "name": "GPT-5.5",
        "reasoning": True,
        "input": ["text", "image"],
        "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
        "contextWindow": 272000,
        "contextTokens": 200000,
        "maxTokens": 128000,
    },
    {
        "id": "gpt-5.4",
        "name": "GPT-5.4",
        "reasoning": True,
        "input": ["text", "image"],
        "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
        "contextWindow": 272000,
        "contextTokens": 200000,
        "maxTokens": 128000,
    },
    {
        "id": "gpt-5.4-mini",
        "name": "GPT-5.4 Mini",
        "reasoning": True,
        "input": ["text", "image"],
        "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
        "contextWindow": 272000,
        "contextTokens": 200000,
        "maxTokens": 128000,
    },
]
codex_lb_provider = {
    "baseUrl": "http://127.0.0.1:2455/v1",
    "api": "openai-completions",
    "auth": "api-key",
    "apiKey": "dummy",
    "models": codex_lb_models,
}
models = cfg.setdefault("models", {})
if models.get("mode") != "merge":
    models["mode"] = "merge"
    changed = True
    print("[init] set models.mode = merge")
providers = models.setdefault("providers", {})
for provider_id in ("codex-lb", "openai-codex"):
    if providers.get(provider_id) != codex_lb_provider:
        providers[provider_id] = codex_lb_provider
        changed = True
        print(f"[init] set models.providers.{provider_id} = codex-lb")

defaults = cfg.setdefault("agents", {}).setdefault("defaults", {})
default_model = defaults.get("model")
if not isinstance(default_model, dict):
    default_model = {}
if default_model.get("primary") != "codex-lb/gpt-5.5":
    default_model["primary"] = "codex-lb/gpt-5.5"
    changed = True
    print("[init] set agents.defaults.model.primary = codex-lb/gpt-5.5")
fallback_models = ["codex-lb/gpt-5.4", "codex-lb/gpt-5.4-mini"]
if default_model.get("fallbacks") != fallback_models:
    default_model["fallbacks"] = fallback_models
    changed = True
    print("[init] set agents.defaults.model.fallbacks = codex-lb/gpt-5.4,codex-lb/gpt-5.4-mini")
defaults["model"] = default_model
agent_models = defaults.setdefault("models", {})
existing_gpt55 = agent_models.get("openai-codex/gpt-5.5")
if not isinstance(existing_gpt55, dict):
    existing_gpt55 = {"params": {"serviceTier": "fast"}}
if agent_models.get("codex-lb/gpt-5.5") != existing_gpt55:
    agent_models["codex-lb/gpt-5.5"] = existing_gpt55
    changed = True
    print("[init] added agents.defaults.models.codex-lb/gpt-5.5")
if agent_models.get("codex-lb/gpt-5.4") != {}:
    agent_models["codex-lb/gpt-5.4"] = {}
    changed = True
    print("[init] added agents.defaults.models.codex-lb/gpt-5.4")
if agent_models.get("codex-lb/gpt-5.4-mini") != {}:
    agent_models["codex-lb/gpt-5.4-mini"] = {}
    changed = True
    print("[init] added agents.defaults.models.codex-lb/gpt-5.4-mini")

# Expose QMD through MCP so Jarvis can search the Obsidian vault without shell
# access. The qmd CLI is installed later in this boot script; MCP starts it lazily.
mcp = cfg.setdefault("mcp", {})
servers = mcp.setdefault("servers", {})
qmd_server = {
    "command": "qmd",
    "args": ["mcp"],
    "env": {
        "HOME": "/data",
        "XDG_CACHE_HOME": "/data/.cache",
        "XDG_CONFIG_HOME": "/data/.config",
    },
}
if servers.get("qmd") != qmd_server:
    servers["qmd"] = qmd_server
    changed = True
    print("[init] set mcp.servers.qmd")

# codex-lb currently accepts small OpenClaw tool payloads, but returns upstream
# internal errors when OpenClaw exposes the full coding catalog, especially exec.
# Keep Jarvis on a small no-shell surface that still supports file, memory, and
# qmd-backed Obsidian search.
tools = cfg.setdefault("tools", {})
if tools.get("profile") != "minimal":
    tools["profile"] = "minimal"
    changed = True
    print("[init] set tools.profile = minimal")
if "allow" in tools:
    del tools["allow"]
    changed = True
    print("[init] removed tools.allow")
safe_tools = [
    "read",
    "write",
    "edit",
    "memory_search",
    "memory_get",
    "qmd__query",
    "qmd__get",
    "qmd__multi_get",
    "qmd__status",
]
if tools.get("alsoAllow") != safe_tools:
    tools["alsoAllow"] = safe_tools
    changed = True
    print("[init] set tools.alsoAllow for codex-lb-safe Obsidian catalog")
deny_tools = [
    "agents_list",
    "browser",
    "canvas",
    "cron",
    "dir_fetch",
    "dir_list",
    "exec",
    "file_fetch",
    "file_write",
    "gateway",
    "image",
    "image_generate",
    "message",
    "nodes",
    "pdf",
    "process",
    "sessions_history",
    "sessions_list",
    "sessions_send",
    "sessions_spawn",
    "sessions_yield",
    "subagents",
    "tts",
    "web_fetch",
    "web_search",
]
if tools.get("deny") != deny_tools:
    tools["deny"] = deny_tools
    changed = True
    print("[init] set tools.deny for codex-lb-safe catalog")
if tools.get("toolSearch") is not False:
    tools["toolSearch"] = False
    changed = True
    print("[init] set tools.toolSearch = false")
if changed:
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
        f.write("\n")
PYEOF
fi

# ── chezmoi dotfiles ──────────────────────────────────────────────────────────
# CHEZMOI_DOTFILES_REPO: set this host secret to your dotfiles repo,
# e.g. "danieljvdm/dotfiles".
# CHEZMOI_GITHUB_ACCESS_TOKEN: set if the repo is private.
CHEZMOI_SOURCE="/data/.local/share/chezmoi"

if [ -n "${CHEZMOI_DOTFILES_REPO:-}" ]; then
  # The host may preserve the chezmoi source across image/user changes, which can
  # make Git reject it as a dubious-ownership repo on the next boot. Trust it at
  # the system level because chezmoi owns /root/.gitconfig and may rewrite it.
  if command -v git >/dev/null 2>&1; then
    git config --system --get-all safe.directory 2>/dev/null | grep -Fxq "$CHEZMOI_SOURCE" ||
      git config --system --add safe.directory "$CHEZMOI_SOURCE" || true
  fi

  # Build clone URL — embed token if provided so git doesn't prompt for credentials
  if [ -n "${CHEZMOI_GITHUB_ACCESS_TOKEN:-}" ]; then
    CLONE_URL="https://${CHEZMOI_GITHUB_ACCESS_TOKEN}@github.com/${CHEZMOI_DOTFILES_REPO}.git"
  else
    CLONE_URL="https://github.com/${CHEZMOI_DOTFILES_REPO}.git"
  fi

  if [ ! -d "$CHEZMOI_SOURCE/.git" ]; then
    log "Cloning dotfiles from ${CHEZMOI_DOTFILES_REPO}..."
    chezmoi init --source "$CHEZMOI_SOURCE" "$CLONE_URL" || {
      log "WARNING: chezmoi init failed — continuing without dotfiles"
    }
  else
    log "Updating dotfiles from ${CHEZMOI_DOTFILES_REPO}..."
    git -C "$CHEZMOI_SOURCE" remote set-url origin "$CLONE_URL" || true
    git -C "$CHEZMOI_SOURCE" pull --ff-only || {
      log "WARNING: dotfiles update failed — applying existing source"
    }
  fi

  log "Applying chezmoi dotfiles..."
  chezmoi apply --force --source "$CHEZMOI_SOURCE" || {
    log "WARNING: chezmoi apply failed — continuing"
  }
else
  log "CHEZMOI_DOTFILES_REPO not set — skipping dotfiles setup."
  log "Set it in host secrets to enable dotfiles on boot."
fi

# ── codex-lb ─────────────────────────────────────────────────────────────────
# The shared chezmoi config points Codex/OpenCode at 127.0.0.1:2455. On macOS
# launchd starts codex-lb; in this container start.sh supervises it after init.
case "${CODEX_LB_ENABLED:-1}" in
  0|false|FALSE|no|NO)
    log "codex-lb disabled by CODEX_LB_ENABLED."
    ;;
  *)
    CODEX_LB_DATA_DIR="${CODEX_LB_DATA_DIR:-/data/.codex-lb}"
    CODEX_LB_HOST="${CODEX_LB_HOST:-127.0.0.1}"
    CODEX_LB_PORT="${CODEX_LB_PORT:-2455}"
    CODEX_LB_LOG="${CODEX_LB_LOG:-/data/.local/state/codex-lb.log}"
    CODEX_LB_HOME_LINK="${HOME}/.codex-lb"
    CODEX_LB_VAR_LINK="/var/lib/codex-lb"

    mkdir -p "$CODEX_LB_DATA_DIR" "$(dirname "$CODEX_LB_LOG")" "$HOME"

    if [ -L "$CODEX_LB_HOME_LINK" ]; then
      ln -sfn "$CODEX_LB_DATA_DIR" "$CODEX_LB_HOME_LINK"
    elif [ -d "$CODEX_LB_HOME_LINK" ]; then
      if [ -z "$(find "$CODEX_LB_HOME_LINK" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
        rmdir "$CODEX_LB_HOME_LINK"
        ln -s "$CODEX_LB_DATA_DIR" "$CODEX_LB_HOME_LINK"
      else
        log "WARNING: $CODEX_LB_HOME_LINK already exists and is not empty; codex-lb will use $CODEX_LB_DATA_DIR via HOME=/data."
      fi
    elif [ ! -e "$CODEX_LB_HOME_LINK" ]; then
      ln -s "$CODEX_LB_DATA_DIR" "$CODEX_LB_HOME_LINK"
    else
      log "WARNING: $CODEX_LB_HOME_LINK exists and is not a directory/symlink; codex-lb will use $CODEX_LB_DATA_DIR via HOME=/data."
    fi

    mkdir -p /var/lib
    if [ -L "$CODEX_LB_VAR_LINK" ]; then
      ln -sfn "$CODEX_LB_DATA_DIR" "$CODEX_LB_VAR_LINK"
    elif [ -d "$CODEX_LB_VAR_LINK" ]; then
      if [ -z "$(find "$CODEX_LB_VAR_LINK" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]; then
        rmdir "$CODEX_LB_VAR_LINK"
        ln -s "$CODEX_LB_DATA_DIR" "$CODEX_LB_VAR_LINK"
      else
        log "WARNING: $CODEX_LB_VAR_LINK already exists and is not empty; codex-lb may use that store instead of $CODEX_LB_DATA_DIR."
      fi
    elif [ ! -e "$CODEX_LB_VAR_LINK" ]; then
      ln -s "$CODEX_LB_DATA_DIR" "$CODEX_LB_VAR_LINK"
    else
      log "WARNING: $CODEX_LB_VAR_LINK exists and is not a directory/symlink; codex-lb may use that store instead of $CODEX_LB_DATA_DIR."
    fi

    if [ ! -f "$CODEX_LB_DATA_DIR/store.db" ]; then
      log "codex-lb has no seeded sessions yet; copy ~/.codex-lb/ from a logged-in Mac to ${CODEX_LB_DATA_DIR}, then restart."
    elif [ "${CODEX_LB_SUPERVISED:-0}" = "1" ]; then
      log "codex-lb state prepared; start.sh will supervise ${CODEX_LB_HOST}:${CODEX_LB_PORT}."
    elif command -v uvx >/dev/null 2>&1; then
      if pgrep -f "codex-lb.*--port ${CODEX_LB_PORT}" >/dev/null 2>&1; then
        log "codex-lb already running on port ${CODEX_LB_PORT}."
      else
        log "Starting codex-lb on ${CODEX_LB_HOST}:${CODEX_LB_PORT}..."
        (
          cd /data
          HOME=/data XDG_CONFIG_HOME=/data/.config XDG_CACHE_HOME=/data/.cache \
          uvx codex-lb --host "$CODEX_LB_HOST" --port "$CODEX_LB_PORT" \
            >> "$CODEX_LB_LOG" 2>&1
        ) &
      fi
    else
      log "WARNING: uvx is not installed; codex-lb was not started."
    fi
    ;;
esac

# ── Obsidian sync ─────────────────────────────────────────────────────────────
# ob stores credentials at $XDG_CONFIG_HOME/obsidian-headless/auth_token
# (set XDG_CONFIG_HOME=/data/.config in Dockerfile so this persists).
# Vault lives at /data/vaults. One-time setup (SSH in):
#   ob login
#   mkdir -p /data/vaults/my-vault && cd /data/vaults/my-vault
#   ob sync-setup --vault "My Vault"
OB_BIN="$(command -v ob 2>/dev/null || true)"
OB_AUTH="${XDG_CONFIG_HOME}/obsidian-headless/auth_token"
if [ -n "$OB_BIN" ] && [ -f "$OB_AUTH" ]; then
  for vault_dir in /data/vaults/*/; do
    [ -d "$vault_dir" ] || continue
    log "Starting Obsidian sync for $vault_dir..."
    (cd "$vault_dir" && "$OB_BIN" sync --continuous >> /data/vaults/sync.log 2>&1) &
  done
else
  log "Obsidian sync skipped (ob not installed or not logged in)."
fi

# ── QMD (semantic search over vault) ─────────────────────────────────────────
# qmd index + models persist to $XDG_CACHE_HOME/qmd/ (→ /data/.cache/qmd/).
# One-time setup after vault is present: already handled below (idempotent).
QMD_BIN="$(command -v qmd 2>/dev/null || true)"
if [ -z "$QMD_BIN" ]; then
  log "Installing qmd..."
  npm install -g @tobilu/qmd
  QMD_BIN="$(command -v qmd 2>/dev/null || true)"
fi

if [ -n "$QMD_BIN" ]; then
  # Register obsidian collection if not already present
  if ! "$QMD_BIN" status 2>/dev/null | grep -q "obsidian"; then
    log "Registering qmd obsidian collection..."
    "$QMD_BIN" collection add /data/vaults --name obsidian --mask "**/*.md" \
      || log "WARNING: qmd collection add failed"
  fi
  # Background embed (updates index after sync brings in new/changed notes)
  if [ -d /data/vaults ] && [ -n "$(ls -A /data/vaults 2>/dev/null)" ]; then
    log "Starting qmd background embed..."
    mkdir -p /data/.cache/qmd
    (nice -n 10 "$QMD_BIN" embed --collection obsidian >> /data/.cache/qmd/embed.log 2>&1) &
  fi
fi

# ── openclaw skills ───────────────────────────────────────────────────────────
# Skills in /app/src/skills are baked into the image; symlink into ~/.agents/skills/
# so openclaw can discover them. Existing symlinks are left as-is.
SKILLS_DIR="${HOME}/.agents/skills"
mkdir -p "$SKILLS_DIR"
for skill_src in /app/src/skills/*/; do
  skill_name="$(basename "$skill_src")"
  target="$SKILLS_DIR/$skill_name"
  if [ ! -e "$target" ]; then
    log "Linking skill: $skill_name"
    ln -s "/app/src/skills/${skill_name}" "$target"
  fi
done
