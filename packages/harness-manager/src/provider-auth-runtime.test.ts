import { execFile } from "node:child_process"
import { mkdtemp, rm, writeFile } from "node:fs/promises"
import { join } from "node:path"
import { promisify } from "node:util"

import { it, onTestFinished, expect } from "vitest"

import { piAuthExtension } from "./provider-auth-runtime.js"

it("routes Pi's native refresh hook through the broker", async () => {
  const root = await mkdtemp(join(process.cwd(), ".provider-runtime-test-"))
  onTestFinished(() => rm(root, { recursive: true, force: true }))
  await writeFile(join(root, "pi.mjs"), piAuthExtension)
  await writeFile(
    join(root, "manifest.json"),
    JSON.stringify({
      url: "http://127.0.0.1:1/token",
      providers: {
        anthropic: { capability: "pi-cap", access: "old" }
      }
    })
  )
  const test = `
import assert from "node:assert/strict";
import pi from "./pi.mjs";
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
console.log("native hooks passed");
`
  await writeFile(join(root, "test.mjs"), test)
  const result = await promisify(execFile)(process.execPath, [join(root, "test.mjs")], {
    env: { PATH: process.env.PATH, CODEVISOR_PROVIDER_AUTH: join(root, "manifest.json") },
    timeout: 30_000
  })
  expect(result.stdout.trim()).toBe("native hooks passed")
})
