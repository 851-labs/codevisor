import process from "node:process"
import { fileURLToPath } from "node:url"

import { runCommand } from "../packages/devtools/src/commands.ts"
import {
  cargoEnvironment,
  ensureNodeAddon,
  ensureRelayBinary,
  ensureSwiftFramework,
  netSourceStamp,
  readNetLock,
  relayBuildArguments
} from "../packages/devtools/src/net-artifact.ts"

const repoRoot = fileURLToPath(new URL("..", import.meta.url))
const [command, ...args] = process.argv.slice(2)
const commands = {
  stamp: async () => console.log(await netSourceStamp(repoRoot)),
  "ensure-node": async () => console.log(await ensureNodeAddon(repoRoot)),
  "ensure-relay": async () => console.log(await ensureRelayBinary(repoRoot)),
  "ensure-swift": async () => console.log(await ensureSwiftFramework(repoRoot)),
  "relay-build-args": async () =>
    console.log(relayBuildArguments(await readNetLock(repoRoot)).join("\n")),
  cargo: async () =>
    runCommand("cargo", args, { cwd: repoRoot, env: await cargoEnvironment(repoRoot) })
}

try {
  const run = Object.hasOwn(commands, command ?? "") ? commands[command] : undefined
  if (run === undefined) {
    throw new Error(
      "usage: net-artifact.mjs <stamp|ensure-node|ensure-relay|ensure-swift|relay-build-args|cargo ARGS…>"
    )
  }
  await run()
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  process.exitCode = 1
}
