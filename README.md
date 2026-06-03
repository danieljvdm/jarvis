# Jarvis OpenClaw Image

Jarvis packages OpenClaw, codex-lb, Tailscale, chezmoi-managed dotfiles, and a
small setup/proxy wrapper into one portable Docker image.

The image is provider-agnostic. Run it anywhere that can keep a persistent
`/data` volume and route HTTP traffic to the container. The public host should
sit behind Cloudflare Access, Tailscale, or another trusted identity-aware proxy.

## What Runs

- OpenClaw Gateway and Control UI, served through the wrapper at `/` and `/openclaw`
- Setup/debug UI at `/setup`
- codex-lb on `127.0.0.1:2455`
- Tailscale userspace networking and optional Tailscale Serve
- Optional chezmoi dotfiles sync on boot
- Obsidian/QMD search support when configured
- Web research through OpenClaw web search/fetch, Brave/DuckDuckGo/Exa/Tavily/
  Perplexity/Firecrawl/SearXNG providers, readability extraction, PDF
  extraction, and browser interaction tools

## Runtime Contract

- Mount persistent storage at `/data`.
- Set `PORT` if the platform does not route to `8080`.
- Route external HTTP traffic to the container port.
- Protect the public host outside the app with Cloudflare Access, Tailscale, or equivalent.
- Set `OPENCLAW_PUBLIC_HOSTS` to the comma-separated hostnames allowed to reach the wrapper.

Persistent paths:

- `/data/.openclaw` - OpenClaw state
- `/data/workspace` - operator workspace and optional `bootstrap.sh`
- `/data/.codex-lb` - codex-lb account/session state
- `/data/.local/share/chezmoi` - dotfiles source
- `/data/.config` and `/data/.cache` - tool config and cache

## Required Environment

```bash
PORT=8080
OPENCLAW_STATE_DIR=/data/.openclaw
OPENCLAW_WORKSPACE_DIR=/data/workspace
OPENCLAW_PLUGIN_STAGE_DIR=/data/.openclaw/plugin-runtime-deps
OPENCLAW_PUBLIC_HOSTS=jarvis.example.com,jarvis.tailnet-name.ts.net
```

OpenClaw gateway auth is intentionally fixed to `trusted-proxy`. The wrapper
keeps the gateway bound to loopback, sets `gateway.trustedProxies` to
`127.0.0.1`, and forwards the identity header configured by
`OPENCLAW_TRUSTED_PROXY_USER_HEADER`:

```bash
OPENCLAW_TRUSTED_PROXY_USER_HEADER=cf-access-authenticated-user-email
```

## Optional Environment

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
OPENCLAW_WEB_SEARCH_PROVIDER=brave
EXA_API_KEY=...
EXA_BASE_URL=...
FIRECRAWL_API_KEY=...
FIRECRAWL_BASE_URL=...
TAVILY_API_KEY=...
TAVILY_BASE_URL=...
PERPLEXITY_API_KEY=...
PERPLEXITY_BASE_URL=...
PERPLEXITY_MODEL=...
OPENROUTER_API_KEY=...
SEARXNG_BASE_URL=...
SEARXNG_CATEGORIES=general,news
SEARXNG_LANGUAGE=en
OPENCLAW_BOOTSTRAP_PLUGINS=@openclaw/brave-plugin
```

Search provider selection defaults to the best configured provider in this
order: Brave, Exa, Tavily, Perplexity, Firecrawl, SearXNG, then DuckDuckGo.
Set `OPENCLAW_WEB_SEARCH_PROVIDER` to pick a specific configured provider.
When `FIRECRAWL_API_KEY` is present, Jarvis also uses Firecrawl as the
`web_fetch` fallback and exposes Firecrawl/Tavily direct tools through the
curated no-shell tool catalog.

## First Setup

1. Deploy the image with a `/data` volume and external auth wall.
2. Visit `https://<host>/setup`.
3. Complete OpenClaw setup and add chat channels such as Telegram.
4. Visit `https://<host>/openclaw`.

If the config already exists, the wrapper starts OpenClaw automatically at boot
so polling channels stay alive even when the dashboard is closed.

## codex-lb Session Seed

Seed from a Mac that already has working codex-lb accounts:

```bash
sqlite3 ~/.codex-lb/store.db 'PRAGMA wal_checkpoint(TRUNCATE);'
tar -C ~/.codex-lb -czf /tmp/codex-lb.tgz .
scp /tmp/codex-lb.tgz root@example.com:/tmp/codex-lb.tgz
ssh root@example.com 'mkdir -p /data/.codex-lb && tar -xzf /tmp/codex-lb.tgz -C /data/.codex-lb'
```

Restart Jarvis after the copy. codex-lb logs go to
`/data/.local/state/codex-lb.log`.

## Checks

```bash
npm test
npm run smoke:fly
npm run smoke:ssh -- root@example.com
```

The smoke checker validates OpenClaw, wrapper health, codex-lb, Codex config,
OpenCode config, QMD MCP config, and Jarvis's curated research/browser tool
catalog.

## Local Run

```bash
docker build -t jarvis-openclaw .

docker run --rm -p 8080:8080 \
  -e PORT=8080 \
  -e OPENCLAW_PUBLIC_HOSTS=localhost \
  -e OPENCLAW_STATE_DIR=/data/.openclaw \
  -e OPENCLAW_WORKSPACE_DIR=/data/workspace \
  -v "$(pwd)/.tmpdata:/data" \
  jarvis-openclaw
```

Open `http://localhost:8080/setup`.

## Backups

The setup UI can export and import a tarball of the configured state/workspace
under `/data`. For provider moves, copying `/data` to the new persistent volume
is the deployment boundary.

See [docs/PORTABILITY.md](docs/PORTABILITY.md) for the host contract and
[docs/FLY.md](docs/FLY.md) for the current Fly deployment adapter.
