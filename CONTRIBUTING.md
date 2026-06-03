# Contributing

Jarvis is a portable OpenClaw image. Keep changes aligned with the `/data`
runtime contract and avoid adding provider-specific behavior to application code.

Before opening a change, run:

```bash
npm test
npm run smoke:ssh -- root@example.com
```

For Fly-specific changes, also run:

```bash
npm run smoke:fly
```

When debugging deployment issues, include:

- Host logs around startup
- `/healthz`
- `/setup/api/debug`
- Public hostname and identity-proxy header configuration, without secrets
