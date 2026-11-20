import { realpath } from "node:fs/promises"
import { fileURLToPath } from "node:url"

import { prepareDevelopmentSimulator } from "../packages/devtools/src/dev-ios-simulator.ts"
import { simulatorLauncher } from "../packages/devtools/src/ios-simulator-launcher.ts"
import { runOwnedTask } from "../packages/devtools/src/owned-task.ts"
import { processIdentity } from "../packages/processes/src/index.mjs"

const args = process.argv.slice(2)
const repoRoot = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const simulator = simulatorLauncher(repoRoot, processIdentity, [])

if (await prepareDevelopmentSimulator(repoRoot, args, simulator)) {
  await runOwnedTask(fileURLToPath(new URL("./dev-owner.mjs", import.meta.url)), args)
} else {
  process.exitCode = 1
}
