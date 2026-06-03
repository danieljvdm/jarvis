# Portability Contract

Jarvis should move between Fly.io, a VPS, a local Docker host, or another
container platform without application-code changes.

## Host Requirements

- Run the Docker image built from this repo.
- Mount durable storage at `/data`.
- Route public HTTP traffic to `PORT`, default `8080`.
- Keep at least one process running for polling channels.
- Provide outbound network access for Tailscale, GitHub, model providers, and OpenClaw plugins.
- Put the public host behind Cloudflare Access, Tailscale, or another trusted auth wall.

## Persistent Data

Copying `/data` is the migration boundary. Preserve:

- `/data/.openclaw`
- `/data/workspace`
- `/data/.codex-lb`
- `/data/.local/share/chezmoi`
- `/data/.config`
- `/data/.cache`
- `/data/vaults` when Obsidian sync/search is used

## Environment

Required:

```bash
PORT=8080
OPENCLAW_STATE_DIR=/data/.openclaw
OPENCLAW_WORKSPACE_DIR=/data/workspace
OPENCLAW_PLUGIN_STAGE_DIR=/data/.openclaw/plugin-runtime-deps
OPENCLAW_PUBLIC_HOSTS=jarvis.example.com
```

Trusted proxy identity header:

```bash
OPENCLAW_TRUSTED_PROXY_USER_HEADER=cf-access-authenticated-user-email
```

Optional Jarvis services:

```bash
TS_AUTHKEY=...
TAILSCALE_HOSTNAME=jarvis
CHEZMOI_DOTFILES_REPO=danieljvdm/dotfiles
CHEZMOI_GITHUB_ACCESS_TOKEN=...
CODEX_LB_ENABLED=1
CODEX_LB_DATA_DIR=/data/.codex-lb
CODEX_LB_HOST=127.0.0.1
CODEX_LB_PORT=2455
BRAVE_SEARCH_API_KEY=...
OPENCLAW_BOOTSTRAP_PLUGINS=@openclaw/brave-plugin
```

Jarvis enables a curated no-shell research/browser catalog by default:
OpenClaw web search/fetch, browser interaction, PDF extraction, memory, file
edit tools, and QMD/Obsidian search. Shell/process tools remain denied.

## Health Checks

Use `/setup/healthz` for platform boot checks. Use `/healthz` for richer
diagnostics after config exists.

After deploying:

```bash
npm run smoke:ssh -- root@example.com
```

For Fly:

```bash
npm run smoke:fly
```

## Migration

1. Stop the old host.
2. Copy `/data` to the new host's persistent volume.
3. Set equivalent environment variables and public DNS/auth.
4. Start the image on the new host.
5. Run the smoke checker.
6. Send a Telegram message and verify the inbound log appears on the new host.

Only one running host should poll Telegram for a given bot token.
