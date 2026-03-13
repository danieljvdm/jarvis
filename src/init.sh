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
