import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

test("wrapper uses trusted-proxy auth only", () => {
  const src = fs.readFileSync(new URL("../src/server.js", import.meta.url), "utf8");
  assert.match(src, /const OPENCLAW_GATEWAY_AUTH_MODE = "trusted-proxy"/);
  assert.match(src, /cf-access-authenticated-user-email/);
  assert.match(src, /gateway\.auth\.trustedProxy\.allowLoopback/);
  assert.doesNotMatch(src, /SETUP_BASIC_AUTH_ENABLED/);
  assert.doesNotMatch(src, /DASHBOARD_BASIC_AUTH_ENABLED/);
  assert.doesNotMatch(src, /SETUP_PASSWORD/);
  assert.doesNotMatch(src, /"--auth",\s*"token"/);
  assert.doesNotMatch(src, /OPENCLAW_GATEWAY_AUTH_MODE === "token"/);
});
