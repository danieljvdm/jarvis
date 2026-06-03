# Fly.io Adapter

Fly is the current host for Jarvis. It runs the same portable image and `/data`
contract described in [PORTABILITY.md](./PORTABILITY.md).

## App

The current Fly app name in `fly.toml` is:

```bash
openclaw-broken-fire-2366
```

## Create

```bash
fly launch --copy-config --name openclaw-broken-fire-2366 --no-deploy
fly volumes create jarvis_data --size 20 --region ewr
```

Set secrets:

```bash
fly secrets set \
  TS_AUTHKEY='...' \
  CHEZMOI_DOTFILES_REPO='danieljvdm/dotfiles' \
  CHEZMOI_GITHUB_ACCESS_TOKEN='...'
```

`fly.toml` carries the ordinary non-secret runtime env.

## Deploy

```bash
fly deploy
npm run smoke:fly
```

SSH:

```bash
fly ssh console
fly ssh console -C 'openclaw status'
fly ssh console -C 'openclaw logs --tail 80'
```

## Restore `/data`

Upload a tarball created from another host:

```bash
fly ssh sftp put /tmp/jarvis-data.tgz /tmp/jarvis-data.tgz
fly ssh console -C 'cd / && tar -xzf /tmp/jarvis-data.tgz && rm /tmp/jarvis-data.tgz'
fly apps restart openclaw-broken-fire-2366
```

Verify:

```bash
npm run smoke:fly
fly ssh console -C 'openclaw agent --session-key agent:main:fly-smoke --message "Reply exactly ok" --model codex-lb/gpt-5.4-mini --json'
```

## Notes

- `auto_stop_machines = "off"` and `min_machines_running = 1` keep polling
  channels alive.
- The Fly volume is region-local. Keep one primary Machine unless Jarvis grows
  explicit replication.
- Cloudflare Access protects `jarvis.danvdm.com`; the wrapper and OpenClaw use
  trusted-proxy auth behind it.
