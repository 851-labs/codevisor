// CI planning step for deploy-relays.yml: emits GitHub step outputs —
// `relays` (JSON id list, all or --only <id>) and `image` (SHA-tagged).
import process from "node:process"

import { readRelays } from "./gen-fly.mjs"

const onlyIndex = process.argv.indexOf("--only")
const only = onlyIndex === -1 ? "" : (process.argv[onlyIndex + 1] ?? "")
const { image, relays } = await readRelays()
const selected = relays.filter((relay) => only === "" || relay.id === only).map((relay) => relay.id)
if (selected.length === 0) throw new Error(`no relay matches --only ${only}`)
const sha = process.env.GITHUB_SHA ?? "local"
console.log(`relays=${JSON.stringify(selected)}`)
console.log(`image=${image}:${sha}`)
