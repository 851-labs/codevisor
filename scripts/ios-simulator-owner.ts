import { execFile } from "node:child_process"
import { randomUUID } from "node:crypto"
import { mkdir, realpath, access } from "node:fs/promises"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { promisify } from "node:util"

import { processIdentity } from "../packages/processes/src/index.mjs"
import { claimDevelopmentRunner, releaseDevelopmentRunner } from "./dev-runtime.ts"
import type { DevelopmentRunnerManifest } from "./dev-runtime.ts"
import {
  parseSimulatorArguments,
  selectSimulatorConfiguration,
  simulatorName,
  simulatorManifestPath,
  simulatorOwnerPath,
  readJSON,
  writeJSON,
  simctl,
  deleteOwnedSimulator,
  reapOrphanedSimulators
} from "./ios-simulator-state.ts"
import type { SimulatorManifest } from "./ios-simulator-state.ts"
import { openOwnedXcodeWindow } from "./xcode-window.ts"
import type { OwnedXcodeWindow } from "./xcode-window.ts"

const exec = promisify(execFile)
const repoRoot = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const manifestPath = simulatorManifestPath(repoRoot)
const claimPath = `${manifestPath}.runner`
const owner = await processIdentity(process.pid)
if (!owner) throw new Error("Unable to identify simulator owner")
const claim: DevelopmentRunnerManifest = {
  pid: process.pid,
  repoRoot,
  kind: "ios-simulator",
  startedAt: owner.startedAt,
  ownerStartedAt: owner.startedAt
}
let manifest: SimulatorManifest | undefined
// The JXA helper reports `owned` alongside `ready`, and openOwnedXcodeWindow
// spreads that status into its result; OwnedXcodeWindow does not declare the
// flag yet, so this records it locally.
let xcodeWindow: (OwnedXcodeWindow & { owned?: boolean }) | undefined
let marked = false
let stopping = false
let wake: () => void
const stopped = new Promise<void>((resolve) => {
  wake = resolve
})
const startup = new AbortController()
const requestStop = () => {
  stopping = true
  startup.abort()
  wake()
}
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(signal, requestStop)
process.stdin.on("end", requestStop)
process.stdin.on("error", requestStop)
process.stdin.resume()
const check = () => {
  if (stopping) throw new Error("Simulator startup stopped")
}
let claimed = false
try {
  await mkdir(dirname(manifestPath), { recursive: true })
  await claimDevelopmentRunner(claimPath, claim)
  claimed = true
  await reapOrphanedSimulators()
  check()
  const options = parseSimulatorArguments(process.argv.slice(2))
  const [types, runtimes] = await Promise.all([
    simctl(["list", "devicetypes", "--json"]),
    simctl(["list", "runtimes", "--json"])
  ])
  const config = selectSimulatorConfiguration(
    options,
    JSON.parse(types).devicetypes,
    JSON.parse(runtimes).runtimes
  )
  check()
  const name = simulatorName(repoRoot)
  const udid = await simctl(["create", name, config.deviceType, config.runtimeIdentifier])
  manifest = {
    format: "codevisor-ios-simulator-v1",
    ...config,
    repoRoot,
    name,
    udid,
    lease: randomUUID(),
    owner,
    ready: false
  }
  // Record ownership before any cancellable startup work.
  await writeJSON(simulatorOwnerPath(udid), manifest)
  marked = true
  await writeJSON(manifestPath, manifest)
  check()
  console.log(`Starting ${name}: ${udid} (${config.runtime})`)
  await simctl(["bootstatus", udid, "-b"], { signal: startup.signal })
  check()
  const { stdout } = await exec("xcode-select", ["-p"])
  const developer = stdout.trim()
  xcodeWindow = await openOwnedXcodeWindow(
    join(repoRoot, "apps/ios/Codevisor.xcodeproj"),
    await realpath(join(developer, "../.."))
  )
  xcodeWindow.exited.then(requestStop, (error: Error) => {
    console.error(error.message)
    process.exitCode = 1
    requestStop()
  })
  console.log(
    xcodeWindow.owned
      ? "Opened an owned Xcode project window."
      : "Reusing an existing Xcode project window; it will stay open."
  )
  check()
  const apps = [
    join(developer, "Applications/Simulator.app"),
    join(developer, "../Applications/DeviceHub.app")
  ]
  for (const app of apps) {
    if (
      !(await access(app).then(
        () => true,
        () => false
      ))
    )
      continue
    await exec("open", [app, "--args", "-CurrentDeviceUDID", udid])
    break
  }
  check()
  manifest.ready = true
  await writeJSON(manifestPath, manifest)
  console.log(
    `Simulator ready: ${name}\n  Device: ${udid}\n  Project: ${repoRoot}/apps/ios/Codevisor.xcodeproj\n  State: ${manifestPath}\nStart the app separately with bun run dev:ios or bun run dev. Leave this task running; stopping it deletes this simulator and closes any Xcode window it owns.`
  )
  // File removal also ends ownership, including manual worktree deletion.
  const monitor = setInterval(() => {
    void readJSON<SimulatorManifest>(manifestPath)
      .then((current) => {
        // The monitor is only created after `manifest` is written above.
        if (current?.lease !== manifest!.lease) requestStop()
      })
      .catch(requestStop)
  }, 1_000)
  try {
    await stopped
  } finally {
    clearInterval(monitor)
  }
} catch (error) {
  if (!stopping) {
    // Everything awaited above rejects with an Error; the catch binding is
    // `unknown` regardless.
    console.error((error as Error).message)
    process.exitCode = 1
  }
} finally {
  try {
    await xcodeWindow?.close()
  } catch (error) {
    console.error(`Xcode window cleanup failed: ${(error as Error).message}`)
    process.exitCode = 1
  }
  if (manifest) {
    try {
      if (marked) await deleteOwnedSimulator(manifest)
      else await simctl(["delete", manifest.udid])
      console.log(`Deleted simulator ${manifest.udid}`)
    } catch (error) {
      console.error(
        `Simulator cleanup failed: ${(error as Error).message}. The next ios-simulator launch will retry.`
      )
      process.exitCode = 1
    }
  }
  if (claimed) await releaseDevelopmentRunner(claimPath, claim)
  process.stdin.destroy()
}
