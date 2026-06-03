# Jarvis Portability Contract

Jarvis should be movable between Railway, Fly.io, a VPS, or a local Docker host
without changing application code. Hosting adapters should satisfy this contract.

## Runtime Contract

- Run the image built from this repository.
- Provide a persistent volume mounted at `/data`.
- Set `PORT` to the public HTTP listener port, or route public traffic to the
  container's configured `PORT`.
- Preserve these paths on `/data`:
  - `/data/.openclaw` for OpenClaw state
  - `/data/workspace` for user workspace files
  - `/data/.codex-lb` for Codex account/session state
  - `/data/.local/share/chezmoi` for dotfiles source
  - `/data/.config` and `/data/.cache` for tool config/cache
- Provide outbound network access for Tailscale, GitHub,
  model providers, and OpenClaw plugins.
- Run `/app/src/start.sh` as the container command.

## Required Environment

- `SETUP_PASSWORD`: HTTP Basic auth password for `/setup` and `/openclaw`.
- `OPENCLAW_STATE_DIR=/data/.openclaw`
- `OPENCLAW_WORKSPACE_DIR=/data/workspace`
- `OPENCLAW_GIT_REF=v2026.5.27`, or the desired stable OpenClaw version.

## Jarvis-Specific Environment

- `CHEZMOI_DOTFILES_REPO`: dotfiles repo to apply on boot.
- `CHEZMOI_GITHUB_ACCESS_TOKEN`: token for private dotfiles repos.
- `TS_AUTHKEY`: reusable Tailscale auth key for tailnet access.
- `CODEX_LB_ENABLED=1`
- `CODEX_LB_DATA_DIR=/data/.codex-lb`
- `CODEX_LB_PORT=2455`
- `OPENCLAW_PLUGIN_STAGE_DIR=/data/.clawdbot/plugin-runtime-deps`

## Health Checks

The host should use `/setup/healthz` as its deployment health check. After a
deploy, run the smoke checker from this repo:

```bash
npm run smoke:railway
```

For Fly.io:

```bash
npm run smoke:fly
```

For a non-Railway host with SSH access:

```bash
npm run smoke:ssh -- root@example.com
```

The smoke checker verifies:

- OpenClaw CLI version matches the Dockerfile default.
- The wrapper health endpoint returns `ok=true`.
- codex-lb responds on `127.0.0.1:2455`.
- Codex uses `model_provider = "codex-lb"`.
- OpenCode points at `http://127.0.0.1:2455/v1`.

## Migration Notes

To move Jarvis, copy the contents of `/data` to the new host's persistent volume,
set equivalent environment variables, deploy the same image, then run the smoke
checker against the new host.

See [Fly.io Deployment](./FLY.md) for the Fly-specific app, volume, SSH, and
data migration commands.
