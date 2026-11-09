import { realpath } from "node:fs/promises"
import process from "node:process"
import { fileURLToPath } from "node:url"

import { runDevelopmentOwner } from "../packages/devtools/src/dev-owner.ts"
import {
  processIdentity,
  readProcessTable,
  stopProcesses,
  trackProcessTree
} from "../packages/processes/src/index.mjs"

const [kind, ...args] = process.argv.slice(2)
await runDevelopmentOwner(
  await realpath(fileURLToPath(new URL("..", import.meta.url))),
  kind,
  args,
  { identity: processIdentity, readProcessTable, stopProcesses, trackProcessTree }
)
