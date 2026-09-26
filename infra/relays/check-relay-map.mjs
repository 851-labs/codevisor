// deploy-cloud.yml: the Worker's RELAY_MAP (apps/cloud/wrangler.jsonc) must
// list exactly the advertised relays in infra/relays/relays.json. Adding or
// removing a relay is two PRs (see docs/plans/codevisor-tunnel.md); this
// catches the second half being forgotten.
import { readFile } from "node:fs/promises"
import process from "node:process"

import { readRelays } from "./gen-fly.mjs"

export const expectedRelayMap = (relays) =>
  relays.filter((relay) => relay.advertise).map((relay) => ({ url: `https://${relay.hostname}` }))

const wrangler = await readFile(new URL("../../apps/cloud/wrangler.jsonc", import.meta.url), "utf8")
// JSONC: drop whole-line comments (the file uses no inline or block comments).
const config = JSON.parse(wrangler.replace(/^\s*\/\/.*$/gm, ""))
const actual = JSON.parse(config.vars?.RELAY_MAP ?? "[]")
const expected = expectedRelayMap((await readRelays()).relays)
if (JSON.stringify(actual) !== JSON.stringify(expected)) {
  console.error("apps/cloud/wrangler.jsonc RELAY_MAP does not match infra/relays/relays.json:")
  console.error(`  expected ${JSON.stringify(expected)}`)
  console.error(`  actual   ${JSON.stringify(actual)}`)
  process.exitCode = 1
}
