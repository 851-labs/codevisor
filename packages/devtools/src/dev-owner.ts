import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { mkdir, rm } from "node:fs/promises"
import { basename, dirname, join } from "node:path"

import { waitForExit } from "./child-processes.ts"
import { parseDevelopmentRunnerArguments } from "./dev-arguments.ts"
import { sweepStaleContainers } from "./dev-containers.ts"
import { developmentLayout, iosDevelopmentBundleIdentifier } from "./dev-layout.ts"
import { claimDevelopmentRunner, releaseDevelopmentRunner } from "./dev-runtime.ts"
import {
  type IdentityLookup,
  readJSON,
  requireIOSSimulator,
  simctl,
  type SimulatorManifest
} from "./ios-simulator-state.ts"

export interface ProcessEntry {
  readonly pid: number
  readonly command: string
}

export interface DevOwnerProcesses {
  readonly identity: IdentityLookup
  readonly readProcessTable: () => Promise<ReadonlyArray<ProcessEntry>>
  readonly stopProcesses: (
    processes: ReadonlyArray<ProcessEntry>,
    options: { graceMs: number }
  ) => Promise<unknown>
  readonly trackProcessTree: (
    pid: number
  ) => Promise<{ readonly stop: (options: { graceMs: number }) => Promise<unknown> }>
}

export async function runDevelopmentOwner(
  repoRoot: string,
  kind: string | undefined,
  args: ReadonlyArray<string>,
  processes: DevOwnerProcesses
): Promise<void> {
  const { identity, readProcessTable, stopProcesses, trackProcessTree } = processes
  parseDevelopmentRunnerArguments(args, {
    allowedArguments: kind === "ios" ? [] : ["--no-ios", "--reuse-macos-build"]
  })
  let simulator: SimulatorManifest | undefined
  if (kind === "ios" || !args.includes("--no-ios"))
    simulator = await requireIOSSimulator(repoRoot, { identity: identity })
  const layout = developmentLayout(repoRoot)
  const claimPath = layout.runtime.manifest
  const ownerStartedAt = (await identity(process.pid))?.startedAt
  const claim = {
    kind,
    pid: process.ppid,
    ownerPid: process.pid,
    ...(ownerStartedAt === undefined ? {} : { ownerStartedAt }),
    repoRoot,
    startedAt: new Date().toISOString()
  }
  const hash = createHash("sha256").update(repoRoot).digest("hex").slice(0, 10)
  const appName = `Codevisor (${basename(repoRoot)})`
  const appExecutable = join(
    layout.build.macos.derivedData,
    "Build/Products/Debug",
    `${appName}.app`,
    "Contents/MacOS",
    appName
  )
  let stopRequested = false
  const { promise: stopped, resolve: wake } = Promise.withResolvers<void>()
  const requestStop = (): void => {
    stopRequested = true
    wake()
  }
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(signal, requestStop)
  process.stdin.on("end", requestStop)
  process.stdin.on("error", requestStop)
  process.stdin.resume()
  let claimed = false
  let tree: { readonly stop: (options: { graceMs: number }) => Promise<unknown> } | undefined
  let monitor: NodeJS.Timeout | undefined
  try {
    await mkdir(dirname(claimPath), { recursive: true })
    await claimDevelopmentRunner(claimPath, claim, identity)
    claimed = true
    await cleanupExternalResources()
    if (!stopRequested) {
      const worker = spawn(
        process.execPath,
        [
          join(repoRoot, "scripts", kind === "ios" ? "dev-ios-worker.mjs" : "dev-worker.mjs"),
          ...args
        ],
        { cwd: repoRoot, stdio: "inherit", detached: true }
      )
      const exited = waitForExit(worker)
      exited.catch(requestStop)
      if (worker.pid === undefined) throw new Error("The development worker did not start")
      tree = await trackProcessTree(worker.pid)
      monitor = setInterval(() => {
        void readJSON(claimPath)
          .then((current) => {
            if (!ownedBy(current, process.pid)) requestStop()
          })
          .catch(requestStop)
      }, 1_000)
      const result = await Promise.race([stopped.then(() => undefined), exited])
      process.exitCode = stopRequested ? 0 : (result?.code ?? 1)
    }
  } catch (error) {
    console.error(messageOf(error))
    process.exitCode = 1
  } finally {
    clearInterval(monitor)
    if (claimed) {
      const failures: Array<unknown> = []
      try {
        await tree?.stop({ graceMs: 4_000 })
      } catch (error) {
        failures.push(error)
      }
      try {
        await cleanupExternalResources()
      } catch (error) {
        failures.push(error)
      }
      await releaseDevelopmentRunner(claimPath, claim)
      for (const error of failures) console.error(`Development cleanup failed: ${messageOf(error)}`)
      if (failures.length > 0) process.exitCode = 1
    }
    process.stdin.destroy()
  }

  async function cleanupExternalResources() {
    const cleanup = [
      ...(kind === "ios"
        ? []
        : [
            (async () => {
              const apps = (await readProcessTable()).filter(
                (entry) => entry.command === appExecutable
              )
              await stopProcesses(apps, { graceMs: 2_000 })
            })()
          ]),
      ...(simulator
        ? [
            simctl(["terminate", simulator.udid, iosDevelopmentBundleIdentifier(repoRoot)], {
              timeout: 5_000
            }).catch(() => {})
          ]
        : []),
      sweepStaleContainers("apple", hash),
      sweepStaleContainers("docker", hash),
      rm(join(repoRoot, "apps/ios/Codevisor/Resources/AppIconDevGenerated.icon"), {
        recursive: true,
        force: true
      })
    ]
    const results = await Promise.allSettled(cleanup)
    const failures = results
      .filter((result) => result.status === "rejected")
      .map((result) => result.reason)
    if (failures.length)
      throw new AggregateError(failures, "External development resources could not be cleaned up")
  }
}

function ownedBy(manifest: unknown, pid: number): boolean {
  return (
    manifest !== null &&
    typeof manifest === "object" &&
    "ownerPid" in manifest &&
    manifest.ownerPid === pid
  )
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}
