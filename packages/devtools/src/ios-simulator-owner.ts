import { execFile } from "node:child_process"
import { randomUUID } from "node:crypto"
import { mkdir, realpath } from "node:fs/promises"
import { dirname, join } from "node:path"
import { promisify } from "node:util"

import { claimDevelopmentRunner, releaseDevelopmentRunner } from "./dev-runtime.ts"
import { pathExists } from "./files.ts"
import {
  deleteOwnedSimulator,
  type IdentityLookup,
  parseSimulatorArguments,
  readJSON,
  reapOrphanedSimulators,
  selectSimulatorConfiguration,
  simctl,
  type SimulatorDeviceType,
  type SimulatorManifest,
  simulatorManifestPath,
  simulatorName,
  simulatorOwnerPath,
  type SimulatorRuntime,
  writeJSON
} from "./ios-simulator-state.ts"
import { ensureXcodeDerivedDataSettings } from "./xcode-derived-data.ts"
import { openXcodeWindow, type XcodeWindow } from "./xcode-window.ts"

const exec = promisify(execFile)
const stopSignals: ReadonlyArray<NodeJS.Signals> = ["SIGINT", "SIGTERM", "SIGHUP"]
const iosProject = "apps/ios/Codevisor.xcodeproj"
const simulatorAppTimeoutMilliseconds = 30_000

export async function runIOSSimulatorOwner(
  repoRoot: string,
  args: ReadonlyArray<string>,
  identity: IdentityLookup
): Promise<number> {
  const manifestPath = simulatorManifestPath(repoRoot)
  const claimPath = `${manifestPath}.runner`
  const owner = await identity(process.pid)
  if (!owner) throw new Error("Unable to identify simulator owner")

  const claim = {
    pid: process.pid,
    repoRoot,
    kind: "ios-simulator",
    ...(owner.startedAt === undefined
      ? {}
      : { startedAt: owner.startedAt, ownerStartedAt: owner.startedAt })
  }
  const { promise: stopped, resolve: wake } = Promise.withResolvers<void>()
  const startup = new AbortController()
  let stopping = false
  let exitCode = 0
  const requestStop = (): void => {
    stopping = true
    startup.abort()
    wake()
  }
  const check = (): void => {
    if (stopping) throw new Error("Simulator startup stopped")
  }
  for (const signal of stopSignals) process.on(signal, requestStop)
  process.stdin.on("end", requestStop)
  process.stdin.on("error", requestStop)
  process.stdin.resume()

  let manifest: SimulatorManifest | undefined
  let xcodeWindow: XcodeWindow | undefined
  let marked = false
  let claimed = false
  try {
    await mkdir(dirname(manifestPath), { recursive: true })
    await claimDevelopmentRunner(claimPath, claim, identity)
    claimed = true
    await reapOrphanedSimulators({ identity })
    check()

    const [types, runtimes] = await Promise.all([
      simctl(["list", "devicetypes", "--json"]),
      simctl(["list", "runtimes", "--json"])
    ])
    const config = selectSimulatorConfiguration(
      parseSimulatorArguments(args),
      listed<SimulatorDeviceType>(types, "devicetypes"),
      listed<SimulatorRuntime>(runtimes, "runtimes")
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
    await writeJSON(simulatorOwnerPath(udid), manifest)
    marked = true
    await writeJSON(manifestPath, manifest)
    check()

    console.log(`Starting ${name}: ${udid} (${config.runtime})`)
    const developer = (await exec("xcode-select", ["-p"])).stdout.trim()
    await ensureXcodeDerivedDataSettings(repoRoot)
    xcodeWindow = openXcodeWindow(
      join(repoRoot, iosProject),
      await realpath(join(developer, "../.."))
    )
    const xcodeWindowSummary = reportXcodeWindow(xcodeWindow, () => stopping)
    await simctl(["bootstatus", udid, "-b"], { signal: startup.signal })
    check()

    await showSimulator(developer, udid).catch((error: unknown) => {
      console.warn(`The simulator is running but its window was not shown: ${lastLineOf(error)}`)
    })
    check()
    manifest = { ...manifest, ready: true }
    await writeJSON(manifestPath, manifest)
    console.log(
      `Simulator ready: ${name}\n  Device: ${udid}\n  Project: ${join(repoRoot, iosProject)}\n  State: ${manifestPath}\n  Xcode: ${xcodeWindowSummary()}\nStart the app separately with bun run dev:ios or bun run dev. Leave this task running; stopping it deletes this simulator and closes any Xcode window it owns.`
    )
    const lease = manifest.lease
    const monitor = setInterval(() => {
      void readJSON(manifestPath)
        .then((current) => {
          if (!isLeased(current, lease)) requestStop()
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
      console.error(messageOf(error))
      exitCode = 1
    }
  } finally {
    await xcodeWindow?.close().catch((error: unknown) => {
      console.warn(`The Xcode project window was left as it is: ${messageOf(error)}`)
    })
    if (manifest !== undefined) {
      try {
        if (marked) await deleteOwnedSimulator(manifest)
        else await simctl(["delete", manifest.udid])
        console.log(`Deleted simulator ${manifest.udid}`)
      } catch (error) {
        console.error(
          `Simulator cleanup failed: ${messageOf(error)}. The next ios-simulator launch will retry.`
        )
        exitCode = 1
      }
    }
    if (claimed) await releaseDevelopmentRunner(claimPath, claim)
    for (const signal of stopSignals) process.off(signal, requestStop)
    process.stdin.destroy()
  }
  return exitCode
}

function reportXcodeWindow(window: XcodeWindow, isStopping: () => boolean): () => string {
  let summary = "project window still opening; the simulator does not wait for it"
  void window.opened.then(
    ({ owned }) => {
      summary = owned ? "project window open" : "project window was already open and stays open"
      console.log(
        owned
          ? "Opened an owned Xcode project window."
          : "Reusing an existing Xcode project window; it will stay open."
      )
    },
    (error: unknown) => {
      if (isStopping()) return

      summary = `no project window; open it with xed ${iosProject} if you need Xcode`
      console.warn(
        `Xcode project window skipped: ${messageOf(error)} The simulator does not need it; open it with xed ${iosProject} if you need Xcode.`
      )
    }
  )
  return () => summary
}

async function showSimulator(developer: string, udid: string): Promise<void> {
  for (const app of [
    join(developer, "Applications/Simulator.app"),
    join(developer, "../Applications/DeviceHub.app")
  ]) {
    if (!(await pathExists(app))) continue

    await exec("open", [app, "--args", "-CurrentDeviceUDID", udid], {
      timeout: simulatorAppTimeoutMilliseconds
    })
    return
  }
}

function listed<T>(json: string, key: string): Array<T> {
  const value: unknown = JSON.parse(json)
  const entries =
    value !== null && typeof value === "object" && key in value
      ? Reflect.get(value, key)
      : undefined
  if (!Array.isArray(entries)) throw new Error(`simctl list returned no ${key}`)

  return entries
}

function isLeased(current: unknown, lease: string | undefined): boolean {
  return (
    current !== null && typeof current === "object" && "lease" in current && current.lease === lease
  )
}

function lastLineOf(error: unknown): string {
  return messageOf(error).trim().split("\n").at(-1) ?? ""
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
