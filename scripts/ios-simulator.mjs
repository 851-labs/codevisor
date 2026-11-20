import { realpath } from "node:fs/promises"
import { fileURLToPath } from "node:url"

import {
  startIOSSimulator,
  stopIOSSimulator
} from "../packages/devtools/src/ios-simulator-launcher.ts"
import { parseSimulatorArguments } from "../packages/devtools/src/ios-simulator-state.ts"
import { startDetachedTask } from "../packages/devtools/src/owned-task.ts"
import { processIdentity } from "../packages/processes/src/index.mjs"

const args = process.argv.slice(2)
const options = parseSimulatorArguments(args)
const repoRoot = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const ownerScript = fileURLToPath(new URL("./ios-simulator-owner.mjs", import.meta.url))
const dependencies = {
  identity: processIdentity,
  startOwner: (logPath) => startDetachedTask(ownerScript, args, logPath)
}

if (options.help) {
  console.log(
    "Usage: bun run ios-simulator [--device=\"iPhone 17 Pro\"] [--runtime=27.0]\n       bun run ios-simulator --stop\n\nStarts this worktree's simulator in the background, opens its Xcode project, and returns once the simulator is ready. The simulator keeps running after this command exits. Running it again while it is up prints the running device. --stop deletes the simulator and closes the Xcode window it opened; an already-open window is left alone. Archiving the worktree (deleting its tmp/) also deletes the simulator. The simulator is ready without the Xcode window, which opens when Xcode answers and needs macOS Accessibility access. The owner's log is tmp/runtime/ios-simulator.log."
  )
} else if (options.stop) {
  process.exitCode = await stopIOSSimulator(repoRoot, dependencies)
} else {
  process.exitCode = await startIOSSimulator(repoRoot, options, dependencies)
}
