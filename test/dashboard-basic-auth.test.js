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
