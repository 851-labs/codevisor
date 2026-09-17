import { execFile } from "node:child_process"
import { mkdtemp, rm, writeFile } from "node:fs/promises"
import { join } from "node:path"
import { promisify } from "node:util"

import { it, onTestFinished, expect } from "vitest"

import { openCodeAuthPlugin, piAuthExtension } from "./provider-auth-runtime.js"

it("routes native refresh hooks through the broker and never sends opaque grants upstream", async () => {
  const root = await mkdtemp(join(process.cwd(), ".provider-runtime-test-"))
  onTestFinished(() => rm(root, { recursive: true, force: true }))
  await writeFile(join(root, "pi.mjs"), piAuthExtension)
  await writeFile(join(root, "opencode.mjs"), openCodeAuthPlugin)
  await writeFile(
    join(root, "manifest.json"),
    JSON.stringify({
      url: "http://127.0.0.1:1/token",
      providers: {
        anthropic: { capability: "pi-cap", access: "old" },
        xai: { capability: "oc-cap", endpoint: "https://auth.x.ai/oauth2/token", access: "old" }
      }
    })
  )
  const test = `
import assert from "node:assert/strict";
import pi from "./pi.mjs";
import opencode from "./opencode.mjs";
const calls = [];
let status = 200;
globalThis.fetch = async (input, init) => {
  const request = new Request(input, init);
  calls.push({ url: request.url, body: await request.text(), auth: request.headers.get("authorization") });
  return Response.json({ credential: { type: "oauth", access: "fresh", refresh: "codevisor:pi-cap", expires: 9000000000000 }, idToken: "identity" }, { status });
};
const providers = [];
await pi({ registerProvider: provider => providers.push(provider) });
const anthropic = providers.find(p => p.id === "anthropic");
assert(anthropic);
assert.equal((await anthropic.auth.oauth.refresh({ access: "old" })).access, "fresh");
assert.deepEqual(JSON.parse(calls[0].body), { rejectedAccessToken: "old" });
assert.equal(calls[0].auth, "Bearer pi-cap");
status = 503;
await assert.rejects(anthropic.auth.oauth.refresh({ access: "old" }), /Reconnect/);
status = 200;
await opencode();
const refresh = (endpoint, body) => fetch(endpoint, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(body) });
const value = await (await refresh("https://auth.x.ai/oauth2/token", { grant_type: "refresh_token", refresh_token: "codevisor:oc-cap" })).json();
assert.equal(value.access_token, "fresh");
assert.equal(value.refresh_token, "codevisor:oc-cap");
assert.equal(value.id_token, "identity");
assert.equal(calls.at(-1).auth, "Bearer oc-cap");
assert.equal(calls.at(-1).body, "{}");
const before = calls.length;
await assert.rejects(refresh("https://unexpected.test/token", { grant_type: "refresh_token", refresh_token: "codevisor:oc-cap" }), /update/);
await assert.rejects(refresh("https://auth.x.ai/oauth2/token", { grant_type: "refresh_token", refresh_token: "codevisor:unknown" }), /update/);
assert.equal(calls.length, before);
await fetch("https://models.test/responses", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ prompt: "explain codevisor: accounts" }) });
assert.equal(calls.at(-1).url, "https://models.test/responses");
await refresh("https://other.test/token", { grant_type: "refresh_token", refresh_token: "plugin-owned" });
assert.equal(calls.at(-1).url, "https://other.test/token");
console.log("native hooks passed");
`
  await writeFile(join(root, "test.mjs"), test)
  const result = await promisify(execFile)(process.execPath, [join(root, "test.mjs")], {
    env: { PATH: process.env.PATH, CODEVISOR_PROVIDER_AUTH: join(root, "manifest.json") },
    timeout: 30_000
  })
  expect(result.stdout.trim()).toBe("native hooks passed")
})
