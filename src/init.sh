#!/usr/bin/env bash
# init.sh — runs on every container boot before the Node server starts.
# /data is the provider-mounted persistent volume, so runtime state survives redeploys.
set -euo pipefail

log() { echo "[init] $*"; }

INTERNAL_GATEWAY_PORT="${INTERNAL_GATEWAY_PORT:-18789}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-jarvis}"

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
    tailscale up --authkey="${TS_AUTHKEY}" --hostname="${TAILSCALE_HOSTNAME}"
  else
    log "WARNING: Tailscale not authenticated and TS_AUTHKEY not set."
    log "SSH in and run: tailscale up"
  fi
fi

# Set up tailscale serve to proxy the gateway port over the tailnet.
# This runs every boot since the serve config doesn't persist (ephemeral filesystem).
if tailscale status &>/dev/null; then
  log "Setting up tailscale serve for port ${INTERNAL_GATEWAY_PORT}..."
  tailscale serve --bg --yes "${INTERNAL_GATEWAY_PORT}" || log "WARNING: tailscale serve failed (HTTPS may not be enabled on tailnet)"
fi

# ── openclaw config patches ───────────────────────────────────────────────────
# - gateway.trustedProxies = ["127.0.0.1"] for the local wrapper reverse proxy
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
    --gateway-port "${INTERNAL_GATEWAY_PORT}" \
    --gateway-auth trusted-proxy \
    --flow quickstart \
    --auth-choice skip \
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
if gw.get("trustedProxies") != ["127.0.0.1"]:
    gw["trustedProxies"] = ["127.0.0.1"]
    changed = True
    print("[init] set gateway.trustedProxies = [127.0.0.1]")
ts = gw.setdefault("tailscale", {})
if ts.get("mode") != "serve":
    ts["mode"] = "serve"
    changed = True
    print("[init] set gateway.tailscale.mode = serve")
ui = gw.setdefault("controlUi", {})
public_hosts = [
    host.strip()
    for host in os.environ.get("OPENCLAW_PUBLIC_HOSTS", "").split(",")
    if host.strip()
]
origins = [f"https://{host}" for host in public_hosts]
if ui.get("allowedOrigins") != origins:
    ui["allowedOrigins"] = origins
    changed = True
    print("[init] set controlUi.allowedOrigins from OPENCLAW_PUBLIC_HOSTS")

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
# Keep Jarvis on a curated no-shell surface that supports file edits, memory,
# Obsidian/QMD search, web research, PDF extraction, and browser interaction.
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
    "web_search",
    "web_fetch",
    "browser",
    "pdf",
    "firecrawl_search",
    "firecrawl_scrape",
    "tavily_search",
    "tavily_extract",
]
if tools.get("alsoAllow") != safe_tools:
    tools["alsoAllow"] = safe_tools
    changed = True
    print("[init] set tools.alsoAllow for Jarvis research/browser catalog")
deny_tools = [
    "agents_list",
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
    "process",
    "sessions_history",
    "sessions_list",
    "sessions_send",
    "sessions_spawn",
    "sessions_yield",
    "subagents",
    "tts",
]
if tools.get("deny") != deny_tools:
    tools["deny"] = deny_tools
    changed = True
    print("[init] set tools.deny for Jarvis research/browser catalog")
web = tools.setdefault("web", {})
search = web.setdefault("search", {})
fetch = web.setdefault("fetch", {})
plugins = cfg.setdefault("plugins", {})
trusted_plugin_ids = [
    "active-memory",
    "admin-http-rpc",
    "alibaba",
    "anthropic",
    "arcee",
    "azure-speech",
    "bonjour",
    "brave",
    "browser",
    "byteplus",
    "canvas",
    "cerebras",
    "chutes",
    "clickclack",
    "cloudflare-ai-gateway",
    "codex-supervisor",
    "comfy",
    "copilot-proxy",
    "deepgram",
    "deepinfra",
    "deepseek",
    "device-pair",
    "document-extract",
    "duckduckgo",
    "elevenlabs",
    "exa",
    "fal",
    "file-transfer",
    "firecrawl",
    "fireworks",
    "github-copilot",
    "google",
    "gradium",
    "groq",
    "huggingface",
    "imessage",
    "inworld",
    "irc",
    "kilocode",
    "kimi",
    "litellm",
    "llm-task",
    "lmstudio",
    "mattermost",
    "memory-core",
    "memory-wiki",
    "microsoft",
    "microsoft-foundry",
    "migrate-claude",
    "migrate-hermes",
    "minimax",
    "mistral",
    "moonshot",
    "nvidia",
    "oc-path",
    "ollama",
    "open-prose",
    "openai",
    "opencode",
    "opencode-go",
    "openrouter",
    "perplexity",
    "phone-control",
    "policy",
    "qianfan",
    "qwen",
    "runway",
    "searxng",
    "senseaudio",
    "sglang",
    "signal",
    "skill-workshop",
    "stepfun",
    "synthetic",
    "talk-voice",
    "tavily",
    "telegram",
    "tencent",
    "thread-ownership",
    "together",
    "tts-local-cli",
    "venice",
    "vercel-ai-gateway",
    "vllm",
    "volcengine",
    "voyage",
    "vydra",
    "web-readability",
    "webhooks",
    "workboard",
    "xai",
    "xiaomi",
    "zai",
]
if plugins.get("allow") != trusted_plugin_ids:
    plugins["allow"] = trusted_plugin_ids
    changed = True
    print("[init] set plugins.allow to trusted OpenClaw plugin ids")
entries = plugins.setdefault("entries", {})

def ensure_plugin_enabled(plugin_id):
    entry = entries.setdefault(plugin_id, {})
    if entry.get("enabled") is not True:
        entry["enabled"] = True
        print(f"[init] enabled plugin {plugin_id}")
        return True
    return False

def env_value(name):
    return os.environ.get(name, "").strip()

def entry_config(plugin_id):
    return entries.setdefault(plugin_id, {}).setdefault("config", {})

def set_plugin_config(plugin_id, section_name, key, value, label):
    if not value:
        return False
    section = entry_config(plugin_id).setdefault(section_name, {})
    if section.get(key) == value:
        return False
    section[key] = value
    print(f"[init] set {label} from environment")
    return True

def has_plugin_config_value(plugin_id, section_name, key):
    section = entry_config(plugin_id).setdefault(section_name, {})
    value = section.get(key)
    if isinstance(value, str):
        return bool(value.strip())
    return value is not None

for plugin_id in ("browser", "document-extract", "duckduckgo", "web-readability"):
    if ensure_plugin_enabled(plugin_id):
        changed = True

brave_env_key = os.environ.get("BRAVE_SEARCH_API_KEY", "").strip()
if set_plugin_config("brave", "webSearch", "apiKey", brave_env_key, "Brave search API key"):
    changed = True
brave_entry = entries.setdefault("brave", {})
brave_has_key = has_plugin_config_value("brave", "webSearch", "apiKey")
if brave_has_key:
    if brave_entry.get("enabled") is not True:
        brave_entry["enabled"] = True
        changed = True
        print("[init] enabled plugin brave")

if set_plugin_config("exa", "webSearch", "apiKey", env_value("EXA_API_KEY"), "Exa API key"):
    changed = True
if set_plugin_config("exa", "webSearch", "baseUrl", env_value("EXA_BASE_URL"), "Exa base URL"):
    changed = True

firecrawl_key = env_value("FIRECRAWL_API_KEY")
firecrawl_base_url = env_value("FIRECRAWL_BASE_URL")
if set_plugin_config("firecrawl", "webSearch", "apiKey", firecrawl_key, "Firecrawl search API key"):
    changed = True
if set_plugin_config("firecrawl", "webFetch", "apiKey", firecrawl_key, "Firecrawl fetch API key"):
    changed = True
if set_plugin_config("firecrawl", "webSearch", "baseUrl", firecrawl_base_url, "Firecrawl search base URL"):
    changed = True
if set_plugin_config("firecrawl", "webFetch", "baseUrl", firecrawl_base_url, "Firecrawl fetch base URL"):
    changed = True

if set_plugin_config("tavily", "webSearch", "apiKey", env_value("TAVILY_API_KEY"), "Tavily API key"):
    changed = True
if set_plugin_config("tavily", "webSearch", "baseUrl", env_value("TAVILY_BASE_URL"), "Tavily base URL"):
    changed = True

perplexity_key = env_value("PERPLEXITY_API_KEY") or env_value("OPENROUTER_API_KEY")
if set_plugin_config("perplexity", "webSearch", "apiKey", perplexity_key, "Perplexity/OpenRouter API key"):
    changed = True
if set_plugin_config("perplexity", "webSearch", "baseUrl", env_value("PERPLEXITY_BASE_URL"), "Perplexity base URL"):
    changed = True
if set_plugin_config("perplexity", "webSearch", "model", env_value("PERPLEXITY_MODEL"), "Perplexity model"):
    changed = True

if set_plugin_config("searxng", "webSearch", "baseUrl", env_value("SEARXNG_BASE_URL"), "SearXNG base URL"):
    changed = True
if set_plugin_config("searxng", "webSearch", "categories", env_value("SEARXNG_CATEGORIES"), "SearXNG categories"):
    changed = True
if set_plugin_config("searxng", "webSearch", "language", env_value("SEARXNG_LANGUAGE"), "SearXNG language"):
    changed = True

provider_ready = {
    "brave": brave_has_key,
    "exa": has_plugin_config_value("exa", "webSearch", "apiKey"),
    "firecrawl": has_plugin_config_value("firecrawl", "webSearch", "apiKey"),
    "tavily": has_plugin_config_value("tavily", "webSearch", "apiKey"),
    "perplexity": has_plugin_config_value("perplexity", "webSearch", "apiKey"),
    "searxng": has_plugin_config_value("searxng", "webSearch", "baseUrl"),
    "duckduckgo": True,
}
for provider_id, ready in provider_ready.items():
    if ready and provider_id != "duckduckgo":
        if ensure_plugin_enabled(provider_id):
            changed = True

search_priority = ["brave", "exa", "tavily", "perplexity", "firecrawl", "searxng", "duckduckgo"]
requested_provider = env_value("OPENCLAW_WEB_SEARCH_PROVIDER").lower()
if requested_provider:
    if requested_provider in provider_ready and provider_ready[requested_provider]:
        selected_provider = requested_provider
    else:
        selected_provider = next(provider for provider in search_priority if provider_ready[provider])
        print(f"[init] WARNING: OPENCLAW_WEB_SEARCH_PROVIDER={requested_provider} is not configured; using {selected_provider}")
else:
    selected_provider = next(provider for provider in search_priority if provider_ready[provider])
if search.get("provider") != selected_provider:
    search["provider"] = selected_provider
    changed = True
    print(f"[init] set tools.web.search.provider = {selected_provider}")

firecrawl_fetch_ready = has_plugin_config_value("firecrawl", "webFetch", "apiKey")
if firecrawl_fetch_ready:
    if ensure_plugin_enabled("firecrawl"):
        changed = True
    if fetch.get("provider") != "firecrawl":
        fetch["provider"] = "firecrawl"
        changed = True
        print("[init] set tools.web.fetch.provider = firecrawl")
elif fetch.get("provider") == "firecrawl":
    del fetch["provider"]
    changed = True
    print("[init] removed tools.web.fetch.provider because Firecrawl is not configured")
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

# Install external OpenClaw plugins into /data so the image stays portable while
# still gaining provider-specific tools when a persisted config expects them.
OPENCLAW_BOOTSTRAP_PLUGINS="${OPENCLAW_BOOTSTRAP_PLUGINS:-@openclaw/brave-plugin}"
PLUGIN_STAMP_DIR="${OPENCLAW_STATE_DIR}/plugin-installs"
if [ -n "$OPENCLAW_BOOTSTRAP_PLUGINS" ] && command -v openclaw >/dev/null 2>&1; then
  mkdir -p "$PLUGIN_STAMP_DIR"
  for plugin_spec in $OPENCLAW_BOOTSTRAP_PLUGINS; do
    plugin_stamp="$(printf '%s' "$plugin_spec" | tr -c 'A-Za-z0-9_.@-' '_')"
    plugin_stamp_path="${PLUGIN_STAMP_DIR}/${plugin_stamp}.stamp"
    if [ -f "$plugin_stamp_path" ]; then
      log "OpenClaw plugin already bootstrapped: ${plugin_spec}"
      continue
    fi
    log "Installing OpenClaw plugin: ${plugin_spec}"
    if openclaw plugins install "$plugin_spec" --force; then
      date -u +"%Y-%m-%dT%H:%M:%SZ" > "$plugin_stamp_path"
    else
      log "WARNING: failed to install OpenClaw plugin ${plugin_spec}; continuing"
    fi
  done
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
