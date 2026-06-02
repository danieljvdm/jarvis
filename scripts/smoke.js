#!/usr/bin/env node

import fs from "node:fs";
import { spawnSync } from "node:child_process";

const usage = `Usage:
  node scripts/smoke.js [--local]
  node scripts/smoke.js --railway
  node scripts/smoke.js --ssh <host>

Options:
  --expected-version <version>  Require OpenClaw version, default from Dockerfile ARG.
  --health-url <url>           Wrapper health URL, default http://127.0.0.1:\${PORT:-8080}/setup/healthz.
  --codex-lb-url <url>         codex-lb models URL, default http://127.0.0.1:2455/v1/models.
  --skip-codex-lb              Skip codex-lb and Codex/OpenCode config checks.
  --skip-opencode              Skip OpenCode config check.
  --help                       Show this message.
`;

function parseArgs(argv) {
  const opts = {
    mode: "local",
    skipCodexLb: false,
    skipOpencode: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--help" || arg === "-h") {
      opts.help = true;
    } else if (arg === "--local") {
      opts.mode = "local";
    } else if (arg === "--railway") {
      opts.mode = "railway";
    } else if (arg === "--ssh") {
      opts.mode = "ssh";
      opts.sshHost = argv[++i];
    } else if (arg === "--expected-version") {
      opts.expectedVersion = argv[++i];
    } else if (arg === "--health-url") {
      opts.healthUrl = argv[++i];
    } else if (arg === "--codex-lb-url") {
      opts.codexLbUrl = argv[++i];
    } else if (arg === "--skip-codex-lb") {
      opts.skipCodexLb = true;
    } else if (arg === "--skip-opencode") {
      opts.skipOpencode = true;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (opts.mode === "ssh" && !opts.sshHost) {
    throw new Error("--ssh requires a host, e.g. --ssh root@example.com");
  }
  return opts;
}

function dockerfileOpenClawVersion() {
  try {
    const dockerfile = fs.readFileSync(new URL("../Dockerfile", import.meta.url), "utf8");
    const match = dockerfile.match(/ARG\s+OPENCLAW_GIT_REF=v?([^\s]+)/);
    return match?.[1];
  } catch {
    return undefined;
  }
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}

function remoteScript(opts) {
  const expectedVersion = opts.expectedVersion ?? dockerfileOpenClawVersion() ?? "";
  const healthUrlAssignment = opts.healthUrl
    ? `HEALTH_URL=${shellQuote(opts.healthUrl)}`
    : 'HEALTH_URL="http://127.0.0.1:${PORT:-8080}/setup/healthz"';
  const codexLbUrlAssignment = opts.codexLbUrl
    ? `CODEX_LB_URL=${shellQuote(opts.codexLbUrl)}`
    : 'CODEX_LB_URL="http://127.0.0.1:${CODEX_LB_PORT:-2455}/v1/models"';
  const checkCodexLb = opts.skipCodexLb ? "0" : "1";
  const checkOpencode = opts.skipOpencode ? "0" : "1";

  return String.raw`set -u

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

EXPECTED_VERSION=${shellQuote(expectedVersion)}
${healthUrlAssignment}
${codexLbUrlAssignment}
CHECK_CODEX_LB=${shellQuote(checkCodexLb)}
CHECK_OPENCODE=${shellQuote(checkOpencode)}

OPENCLAW_VERSION_OUTPUT="$(openclaw --version 2>&1)" || fail "openclaw --version failed: $OPENCLAW_VERSION_OUTPUT"
case "$OPENCLAW_VERSION_OUTPUT" in
  *"$EXPECTED_VERSION"*) pass "openclaw version $OPENCLAW_VERSION_OUTPUT" ;;
  *) fail "expected OpenClaw $EXPECTED_VERSION, got $OPENCLAW_VERSION_OUTPUT" ;;
esac

HEALTH_OUTPUT="$(curl -fsS "$HEALTH_URL" 2>&1)" || fail "health check failed: $HEALTH_OUTPUT"
case "$HEALTH_OUTPUT" in
  *'"ok":true'*) pass "wrapper health $HEALTH_URL" ;;
  *) fail "health did not report ok=true: $HEALTH_OUTPUT" ;;
esac

if [ "$CHECK_CODEX_LB" = "1" ]; then
  CODEX_LB_OUTPUT="$(curl -fsS "$CODEX_LB_URL" 2>&1)" || fail "codex-lb models failed: $CODEX_LB_OUTPUT"
  case "$CODEX_LB_OUTPUT" in
    *'"object":"list"'*|*'"data":['*) pass "codex-lb models $CODEX_LB_URL" ;;
    *) fail "codex-lb models response looked wrong: $CODEX_LB_OUTPUT" ;;
  esac

  OPENCLAW_MODEL_CONFIG="$(openclaw config get agents.defaults.model --json 2>/dev/null)" || fail "OpenClaw model config unavailable"
  case "$OPENCLAW_MODEL_CONFIG" in
    *'"primary":"codex-lb/gpt-5.5"'*|*'"primary": "codex-lb/gpt-5.5"'*) ;;
    *) fail "OpenClaw primary model is not codex-lb/gpt-5.5: $OPENCLAW_MODEL_CONFIG" ;;
  esac
  case "$OPENCLAW_MODEL_CONFIG" in
    *'"codex-lb/gpt-5.4"'*'"codex-lb/gpt-5.4-mini"'*) pass "OpenClaw model fallbacks configured" ;;
    *) fail "OpenClaw model fallbacks missing codex-lb gpt-5.4/gpt-5.4-mini: $OPENCLAW_MODEL_CONFIG" ;;
  esac

  CODEX_CONFIG="/root/.codex/config.toml"
  [ -f "$CODEX_CONFIG" ] || CODEX_CONFIG="$HOME/.codex/config.toml"
  if [ -f "$CODEX_CONFIG" ] && grep -q 'model_provider = "codex-lb"' "$CODEX_CONFIG"; then
    pass "Codex model_provider uses codex-lb"
  else
    fail "Codex config does not set model_provider = \"codex-lb\""
  fi
fi

if [ "$CHECK_OPENCODE" = "1" ]; then
  OPENCODE_CONFIG="/root/.config/opencode/opencode.json"
  [ -f "$OPENCODE_CONFIG" ] || OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
  if [ -f "$OPENCODE_CONFIG" ] && grep -q 'http://127.0.0.1:2455/v1' "$OPENCODE_CONFIG"; then
    pass "OpenCode points at codex-lb"
  else
    fail "OpenCode config does not point at codex-lb"
  fi
fi
`;
}

function run(opts) {
  const script = remoteScript(opts);
  if (opts.mode === "local") {
    return spawnSync("bash", ["-lc", script], { stdio: "inherit" });
  }
  if (opts.mode === "railway") {
    return spawnSync("railway", ["ssh", script], { stdio: "inherit" });
  }
  if (opts.mode === "ssh") {
    return spawnSync("ssh", [opts.sshHost, script], { stdio: "inherit" });
  }
  throw new Error(`Unsupported mode: ${opts.mode}`);
}

try {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    process.stdout.write(usage);
    process.exit(0);
  }

  const result = run(opts);
  if (result.error) throw result.error;
  process.exit(result.status ?? 1);
} catch (err) {
  console.error(err instanceof Error ? err.message : String(err));
  console.error();
  console.error(usage);
  process.exit(1);
}
