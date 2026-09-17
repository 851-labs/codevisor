import { fileURLToPath } from "node:url"

import { parseSimulatorArguments } from "./ios-simulator-state.mjs"
import { runOwnedTask } from "./owned-task.mjs"

// The resource owner has its own process group and watches this pipe. If Codex
// or an operator SIGKILLs the launcher, EOF still lets the owner delete its device.
const options = parseSimulatorArguments(process.argv.slice(2))
if (options.help) {
  console.log(
    'Usage: bun run ios-simulator [--device="iPhone 17 Pro"] [--runtime=27.0]\n\nStarts only this worktree\'s simulator and opens its Xcode project. Leave this task running while using dev:ios or dev. Stopping it deletes its simulator and closes the Xcode window it opened; an already-open window is left alone. Requires macOS Accessibility access.'
  )
} else {
  runOwnedTask(
    fileURLToPath(new URL("./ios-simulator-owner.mjs", import.meta.url)),
    process.argv.slice(2)
  )
}
