import { spawn } from "node:child_process"
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
import { parseDevelopmentRunnerArguments } from "./dev-arguments.mjs"
import { sweepStaleContainers } from "./dev-containers.mjs"
import { developmentLayout, iosDevelopmentBundleIdentifier } from "./dev-layout.mjs"
import { claimDevelopmentRunner, releaseDevelopmentRunner } from "./dev-runtime.mjs"
import { requireIOSSimulator, simctl, readJSON } from "./ios-simulator-state.mjs"

const repoRoot = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const [kind, ...args] = process.argv.slice(2)
parseDevelopmentRunnerArguments(args, {
  allowedArguments: kind === "ios" ? [] : ["--no-ios", "--reuse-macos-build"]
})
const simulator =
  kind === "ios" || !args.includes("--no-ios") ? await requireIOSSimulator(repoRoot) : undefined
const layout = developmentLayout(repoRoot)
const claimPath = layout.runtime.manifest
const claim = {
  kind,
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
let wake
const stopped = new Promise((resolve) => {
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
let child
let tree
let monitor
try {
  await mkdir(dirname(claimPath), { recursive: true })
  await claimDevelopmentRunner(claimPath, claim)
  claimed = true
  await cleanupExternalResources()
  if (!stopRequested) {
    child = spawn(
      process.execPath,
      [
        join(repoRoot, "scripts", kind === "ios" ? "dev-ios-worker.mjs" : "dev-worker.mjs"),
        ...args
      ],
      {
        cwd: repoRoot,
        stdio: "inherit",
        detached: true
      }
    )
    const exited = new Promise((resolve, reject) => {
      child.once("exit", (code, signal) => resolve({ code, signal }))
      child.once("error", reject)
    })
    exited.catch(requestStop)
    tree = await trackProcessTree(child.pid)
    monitor = setInterval(() => {
      void readJSON(claimPath)
        .then((current) => {
          if (current?.ownerPid !== process.pid) requestStop()
        })
        .catch(requestStop)
    }, 1_000)
    const result = await Promise.race([stopped, exited])
    process.exitCode = stopRequested ? 0 : (result?.code ?? 1)
  }
} catch (error) {
  console.error(error.message)
  process.exitCode = 1
} finally {
  clearInterval(monitor)
  if (claimed) {
    // Stop startup/build work before externally launched resources, so a
    // late install or launch cannot recreate them during teardown.
    const failures = []
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
    for (const error of failures) console.error(`Development cleanup failed: ${error.message}`)
    if (failures.length) process.exitCode = 1
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
