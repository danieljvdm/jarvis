#!/usr/bin/env bash
# init.sh — runs on every container boot before the Node server starts.
# /data is the Railway persistent volume, so anything installed there survives redeploys.
set -euo pipefail

log() { echo "[init] $*"; }

# ── Homebrew ──────────────────────────────────────────────────────────────────
# Install to /data/homebrew on first boot. Subsequent boots skip this (fast).
if [ ! -x "/data/homebrew/bin/brew" ]; then
  log "Installing Homebrew to /data/homebrew (first boot, this takes a few minutes)..."
  mkdir -p /data/homebrew
  NONINTERACTIVE=1 HOMEBREW_PREFIX=/data/homebrew \
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  log "Homebrew installed."
else
  log "Homebrew already present at /data/homebrew — skipping install."
fi

# ── chezmoi dotfiles ──────────────────────────────────────────────────────────
# CHEZMOI_DOTFILES_REPO: set this Railway variable to your dotfiles repo,
# e.g. "danieljvdm/dotfiles" or a full HTTPS URL.
# Optional: set CHEZMOI_GITHUB_ACCESS_TOKEN if the repo is private.
CHEZMOI_SOURCE="/data/.local/share/chezmoi"

if [ -n "${CHEZMOI_DOTFILES_REPO:-}" ]; then
  if [ -n "${CHEZMOI_GITHUB_ACCESS_TOKEN:-}" ]; then
    export CHEZMOI_GITHUB_ACCESS_TOKEN
  fi

  if [ ! -d "$CHEZMOI_SOURCE/.git" ]; then
    log "Cloning dotfiles from ${CHEZMOI_DOTFILES_REPO}..."
    chezmoi init --source "$CHEZMOI_SOURCE" "${CHEZMOI_DOTFILES_REPO}" || {
      log "WARNING: chezmoi init failed — continuing without dotfiles"
    }
  fi

  log "Applying chezmoi dotfiles..."
  chezmoi apply --source "$CHEZMOI_SOURCE" 2>/dev/null || {
    log "WARNING: chezmoi apply failed — continuing"
  }
else
  log "CHEZMOI_DOTFILES_REPO not set — skipping dotfiles setup."
  log "Set it in Railway variables to enable dotfiles on boot."
fi
