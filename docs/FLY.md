# Fly.io Deployment

Fly is the preferred portable host for Jarvis when we want normal operational
access. It keeps the same container and `/data` contract as Railway, but gives
us `fly ssh console`, `fly ssh sftp`, and volume-backed Machines.

## Prereqs

Install and authenticate `fly`:

```bash
brew install flyctl
fly auth login
```

The app name in `fly.toml` is `openclaw-broken-fire-2366`.

## Create the App

```bash
fly launch --copy-config --name openclaw-broken-fire-2366 --no-deploy
fly volumes create jarvis_data --size 20 --region ewr
```

Set secrets. Use the same values as Railway where possible:

```bash
fly secrets set \
  SETUP_PASSWORD='...' \
  OPENCLAW_GATEWAY_TOKEN='...' \
  TS_AUTHKEY='...' \
  CHEZMOI_DOTFILES_REPO='danieljvdm/dotfiles' \
  CHEZMOI_GITHUB_ACCESS_TOKEN='...'
```

Optional, if you want to pin these outside `fly.toml`:

```bash
fly secrets set CODEX_LB_ENABLED=1 CODEX_LB_DATA_DIR=/data/.codex-lb
```

## Deploy

```bash
fly deploy
npm run smoke:fly
```

SSH into the running Machine:

```bash
fly ssh console
fly ssh console -C 'openclaw status'
fly ssh console -C 'openclaw logs --tail 80'
```

## Migrate `/data` From Railway

When Railway auth is available, export the live volume:

```bash
railway ssh 'cd / && tar -czf /tmp/jarvis-data.tgz data'
railway ssh 'cat /tmp/jarvis-data.tgz' > /tmp/jarvis-data.tgz
```

Upload it to Fly:

```bash
fly ssh sftp put /tmp/jarvis-data.tgz /tmp/jarvis-data.tgz
fly ssh console -C 'cd / && tar -xzf /tmp/jarvis-data.tgz && rm /tmp/jarvis-data.tgz'
fly apps restart openclaw-broken-fire-2366
```

Then verify:

```bash
npm run smoke:fly
fly ssh console -C 'openclaw agent --session-key agent:main:fly-smoke --message "Reply exactly ok" --model codex-lb/gpt-5.4-mini --json'
```

## Notes

- `fly.toml` keeps `auto_stop_machines = false` and `min_machines_running = 1`
  because Jarvis needs polling channels and sync daemons alive even when nobody
  is visiting the web UI.
- The persistent volume is mounted at `/data`, matching Railway.
- Fly volume storage is local to a region/Machine. Keep one primary Machine for
  Jarvis unless we later add explicit replication.
- The Codex account/session store lives at `/data/.codex-lb`; migrate it before
  expecting `codex-lb` to answer model requests.
