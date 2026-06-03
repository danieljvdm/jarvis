import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

test("dashboard Basic Auth is opt-in", () => {
  const src = fs.readFileSync(new URL("../src/server.js", import.meta.url), "utf8");
  assert.match(src, /DASHBOARD_BASIC_AUTH_ENABLED/);
  assert.match(src, /if \(!DASHBOARD_BASIC_AUTH_ENABLED\) return next\(\);/);
});

test("setup Basic Auth is opt-in", () => {
  const src = fs.readFileSync(new URL("../src/server.js", import.meta.url), "utf8");
  assert.match(src, /SETUP_BASIC_AUTH_ENABLED/);
  assert.match(src, /if \(!SETUP_BASIC_AUTH_ENABLED\) return next\(\);/);
});

test("gateway auth defaults to trusted proxy mode", () => {
  const src = fs.readFileSync(new URL("../src/server.js", import.meta.url), "utf8");
  assert.match(src, /process\.env\.OPENCLAW_GATEWAY_AUTH_MODE\?\.trim\(\) \|\| "trusted-proxy"/);
  assert.match(src, /cf-access-authenticated-user-email/);
  assert.match(src, /gateway\.auth\.trustedProxy\.allowLoopback/);
  assert.match(src, /OPENCLAW_GATEWAY_AUTH_MODE === "token"/);
  assert.doesNotMatch(src, /config", "set", "gateway\.auth\.mode", "token"/);
  assert.doesNotMatch(src, /"--auth",\s*"token"/);
});
