#!/usr/bin/env bash
# init.sh — runs on every container boot before the Node server starts.
# /data is the Railway persistent volume, so anything installed there survives redeploys.
set -euo pipefail

log() { echo "[init] $*"; }

# ── Homebrew ──────────────────────────────────────────────────────────────────
# Homebrew on Linux running as root always installs to /home/linuxbrew/.linuxbrew
# regardless of HOMEBREW_PREFIX. We work around this by symlinking /home/linuxbrew
# → /data/linuxbrew so brew's default path lands on the persistent volume.
BREW_DATA_DIR="/data/linuxbrew"
BREW_BIN="/home/linuxbrew/.linuxbrew/bin/brew"

mkdir -p "$BREW_DATA_DIR"
ln -sfn "$BREW_DATA_DIR" /home/linuxbrew

if [ ! -x "$BREW_BIN" ]; then
  log "Installing Homebrew (first boot, this takes a few minutes)..."
  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  log "Homebrew installed."
else
  log "Homebrew already present — skipping install."
fi

# ── brew-managed tools ────────────────────────────────────────────────────────
# Install on first boot; persisted to /data/linuxbrew across redeploys.
for pkg in neovim; do
  if ! "$BREW_BIN" list --formula "$pkg" &>/dev/null; then
    log "Installing $pkg via brew..."
    "$BREW_BIN" install "$pkg"
  else
    log "$pkg already installed via brew — skipping."
  fi
done

# ── Tailscale ─────────────────────────────────────────────────────────────────
# Persist Tailscale state to /data so auth survives redeploys.
# Set TS_AUTHKEY in Railway variables (reusable key, tagged tag:server).
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

# ── openclaw config patches ───────────────────────────────────────────────────
# - gateway.trustedProxies = ["loopback"] for Railway reverse proxy
# - gateway.tailscale.mode = "serve" for tailnet-only dashboard access
OPENCLAW_CFG="/data/.clawdbot/openclaw.json"
if [ -f "$OPENCLAW_CFG" ]; then
  python3 - << 'PYEOF'
import json
path = "/data/.clawdbot/openclaw.json"
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
if changed:
    with open(path, "w") as f:
        json.dump(cfg, f, indent=2)
PYEOF
fi

# ── chezmoi dotfiles ──────────────────────────────────────────────────────────
# CHEZMOI_DOTFILES_REPO: set this Railway variable to your dotfiles repo,
# e.g. "danieljvdm/dotfiles".
# CHEZMOI_GITHUB_ACCESS_TOKEN: set if the repo is private.
CHEZMOI_SOURCE="/data/.local/share/chezmoi"

if [ -n "${CHEZMOI_DOTFILES_REPO:-}" ]; then
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
  fi

  log "Applying chezmoi dotfiles..."
  chezmoi apply --source "$CHEZMOI_SOURCE" || {
    log "WARNING: chezmoi apply failed — continuing"
  }
else
  log "CHEZMOI_DOTFILES_REPO not set — skipping dotfiles setup."
  log "Set it in Railway variables to enable dotfiles on boot."
fi

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
    ("$QMD_BIN" embed --collection obsidian >> /data/.cache/qmd/embed.log 2>&1) &
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
