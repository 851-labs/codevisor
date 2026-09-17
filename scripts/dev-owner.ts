import { spawn } from "node:child_process"
import type { ChildProcess } from "node:child_process"
import { createHash } from "node:crypto"
import { mkdir, realpath, rm } from "node:fs/promises"
import { basename, dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

import {
  readProcessTable,
  processIdentity,
  stopProcesses,
  trackProcessTree
} from "../packages/processes/src/index.mjs"
import { parseDevelopmentRunnerArguments } from "./dev-arguments.ts"
import { sweepStaleContainers } from "./dev-containers.ts"
import { developmentLayout, iosDevelopmentBundleIdentifier } from "./dev-layout.ts"
import { claimDevelopmentRunner, releaseDevelopmentRunner } from "./dev-runtime.ts"
import type { DevelopmentRunnerManifest, StoredDevelopmentRunnerManifest } from "./dev-runtime.ts"
import type { ExitResult } from "./dev-shared.ts"
import { requireIOSSimulator, simctl, readJSON } from "./ios-simulator-state.ts"

const repoRoot = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const [kind, ...args] = process.argv.slice(2)
parseDevelopmentRunnerArguments(args, {
  allowedArguments: kind === "ios" ? [] : ["--no-ios", "--reuse-macos-build"]
})
const simulator =
  kind === "ios" || !args.includes("--no-ios") ? await requireIOSSimulator(repoRoot) : undefined
const layout = developmentLayout(repoRoot)
const claimPath = layout.runtime.manifest
const claim: DevelopmentRunnerManifest = {
  // The wrapper scripts always pass a kind; argv elements are typed optional
  // only because indexed access is unchecked.
  kind: kind as string,
  pid: process.ppid,
  ownerPid: process.pid,
  ownerStartedAt: (await processIdentity(process.pid))?.startedAt,
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
// `wake` resolves `stopped` with no value, so the runner can race it against
// the worker's exit result.
let wake: (value?: undefined) => void
const stopped = new Promise<undefined>((resolve) => {
  wake = resolve
})
const requestStop = () => {
  stopRequested = true
  wake()
}
for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(signal, requestStop)
process.stdin.on("end", requestStop)
process.stdin.on("error", requestStop)
process.stdin.resume()
let claimed = false
let child: ChildProcess
let tree: Awaited<ReturnType<typeof trackProcessTree>> | undefined
let monitor: NodeJS.Timeout | undefined
try {
  await mkdir(dirname(claimPath), { recursive: true })
  await claimDevelopmentRunner(claimPath, claim)
  claimed = true
  await cleanupExternalResources()
  if (!stopRequested) {
    child = spawn(
      process.execPath,
      [join(repoRoot, "scripts", kind === "ios" ? "dev-ios-worker.ts" : "dev-worker.ts"), ...args],
      {
        cwd: repoRoot,
        stdio: "inherit",
        detached: true
      }
    )
    const exited = new Promise<ExitResult>((resolve, reject) => {
      child.once("exit", (code, signal) => resolve({ code, signal }))
      child.once("error", reject)
    })
    exited.catch(requestStop)
    // spawn only leaves pid unset when the spawn itself failed, and that
    // path rejects `exited` above, which stops the runner.
    tree = await trackProcessTree(child.pid as number)
    monitor = setInterval(() => {
      void readJSON<StoredDevelopmentRunnerManifest>(claimPath)
        .then((current) => {
          if (current?.ownerPid !== process.pid) requestStop()
        })
        .catch(requestStop)
    }, 1_000)
    const result = await Promise.race([stopped, exited])
    process.exitCode = stopRequested ? 0 : (result?.code ?? 1)
  }
} catch (error) {
  // Everything awaited above rejects with an Error; the catch binding is
  // `unknown` regardless.
  console.error((error as Error).message)
  process.exitCode = 1
} finally {
  clearInterval(monitor)
  if (claimed) {
    // Stop startup/build work before externally launched resources, so a
    // late install or launch cannot recreate them during teardown.
    const failures: unknown[] = []
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
    for (const error of failures)
      // Both collected rejections are Errors; the bindings above are `unknown`.
      console.error(`Development cleanup failed: ${(error as Error).message}`)
    if (failures.length) process.exitCode = 1
  }
  process.stdin.destroy()
}

async function cleanupExternalResources(): Promise<void> {
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
