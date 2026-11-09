import { realpath } from "node:fs/promises"
import process from "node:process"
import { fileURLToPath } from "node:url"

import { runIOSSimulatorOwner } from "../packages/devtools/src/ios-simulator-owner.ts"
import { processIdentity } from "../packages/processes/src/index.mjs"

const repoRoot = await realpath(fileURLToPath(new URL("..", import.meta.url)))
process.exitCode = await runIOSSimulatorOwner(repoRoot, process.argv.slice(2), processIdentity)
