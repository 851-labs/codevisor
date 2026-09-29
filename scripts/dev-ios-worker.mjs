import { spawn } from "node:child_process"
// iOS development loop: starts a development cloud and the same isolated Dev
// Cloud machine as scripts/dev.mjs (a Linux container by default), then
// builds and launches the iOS app in the visible Simulator. No macOS app is
// built or launched — iOS is a pure client that reaches machines only
// through the dev cloud account it signs into.
import { createHash } from "node:crypto"
import { readFile, realpath } from "node:fs/promises"
import { basename, join, resolve } from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"

import { parseDevelopmentRunnerArguments } from "./dev-arguments.mjs"
import { bootstrapDevelopment } from "./dev-bootstrap.mjs"
import { cloudWranglerEnvironment } from "./dev-cloud.mjs"
import {
  launchDevRemoteServer,
  prepareDevContainers,
  resolveContainerEngine
} from "./dev-containers.mjs"
import {
  buildIOSDevelopmentApp,
  launchIOSDevelopmentApp,
  terminateIOSDevelopmentApp
} from "./dev-ios-target.mjs"
import {
  developmentLayout,
  ensureDevelopmentDirectories,
  iosDevelopmentBundleIdentifier,
  localDevelopmentEnvironment,
  remoteDevelopmentEnvironment
} from "./dev-layout.mjs"
import {
  colorFromHash,
  delay,
  describeExit,
  findAvailablePort,
  isPortAvailable,
  parsePort,
  waitForExit,
  waitForHealth
} from "./dev-shared.mjs"
import { requireIOSSimulator } from "./ios-simulator-state.mjs"

const repoRoot = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const simulator = await requireIOSSimulator(repoRoot)
const { wantsContainers, containerEnginePreference } = parseDevelopmentRunnerArguments(
  process.argv.slice(2)
)
const worktreeName = basename(repoRoot)
const instanceHash = createHash("sha256").update(repoRoot).digest("hex").slice(0, 10)
const instanceName = `${worktreeName}-${instanceHash}`
const layout = developmentLayout(repoRoot)
// Shared with scripts/dev.mjs's Dev Cloud server so the simulator sees the
// same machine (same data, same cloud identity) either way.
const cloudRemoteDataDirectory = layout.remoteCloud.data
const cloudRemoteName = `Dev Cloud (${worktreeName})`
// Same hash → hue derivation as scripts/dev.mjs, so a worktree's iOS icon
// color matches its macOS icon color.
const worktreeHash = createHash("sha256").update(worktreeName).digest("hex")
const developmentIconColor = colorFromHash(worktreeHash)
const appDisplayName = `Codevisor (${worktreeName})`
const bundleIdentifier = iosDevelopmentBundleIdentifier(repoRoot)
const urlScheme = `codevisor-dev-${instanceHash}`

// Same preferred port as scripts/dev.mjs's Dev Cloud server (the local
// server's preferred port + 2).
const preferredPort = 51_000 + (Number.parseInt(instanceHash.slice(0, 8), 16) % 10_000)
const cloudRemotePort = await findAvailablePort(preferredPort + 2, 51_000, 10_000)
const cloudRemoteURL = `http://127.0.0.1:${cloudRemotePort}`
const configuredCloudURL = process.env.CODEVISOR_DEV_CLOUD_URL?.replace(/\/+$/, "")
const externalCloudURL = configuredCloudURL === "" ? undefined : configuredCloudURL
const preferredCloudPort = 41_000 + (Number.parseInt(instanceHash.slice(0, 8), 16) % 10_000)
const requestedCloudPort = parsePort(
  process.env.CODEVISOR_DEV_CLOUD_PORT,
  "CODEVISOR_DEV_CLOUD_PORT"
)
if (
  externalCloudURL === undefined &&
  requestedCloudPort !== undefined &&
  !(await isPortAvailable(requestedCloudPort))
) {
  throw new Error(
    `CODEVISOR_DEV_CLOUD_PORT ${requestedCloudPort} is already in use; ` +
      "stop its owner or choose a different explicit port."
  )
}
const cloudPort =
  externalCloudURL === undefined
    ? (requestedCloudPort ?? (await findAvailablePort(preferredCloudPort, 41_000, 10_000)))
    : undefined
const cloudURL = externalCloudURL ?? `http://localhost:${cloudPort}`
const cloudPersistPath = layout.wrangler

await ensureDevelopmentDirectories(layout)
Object.assign(process.env, localDevelopmentEnvironment(layout, process.env))

console.log(`Codevisor iOS development instance: ${worktreeName}`)
console.log(`  viacloud:  ${cloudRemoteURL}  (${cloudRemoteName})`)
console.log(`  data:      ${cloudRemoteDataDirectory}`)
console.log(`  simulator: ${simulator.name} (${simulator.udid})`)
console.log(`  app:       ${appDisplayName} (${bundleIdentifier})`)
console.log(`  icon:      ${developmentIconColor.hex}`)
console.log(`  cloud:     ${cloudURL}${externalCloudURL === undefined ? " (managed)" : ""}`)

await bootstrapDevelopment(repoRoot, { environment: process.env, ghosttyKit: true })
await run("bun", ["run", "--cwd", "apps/server", "build"])

// Match dev/dev:macos: a real Linux remote by default, same-host only when
// explicitly requested or when neither supported engine is available.
const containerEngine = wantsContainers
  ? await resolveContainerEngine(containerEnginePreference)
  : undefined
if (wantsContainers && containerEngine === undefined) {
  console.warn("No usable container engine; the dev remote runs as a same-host process.")
}
const containerContext =
  containerEngine === undefined
    ? undefined
    : await prepareDevContainers({
        repoRoot,
        containerRoot: join(layout.tmpRoot, "container"),
        engine: containerEngine,
        worktreeHash: instanceHash
      })

// Match the macOS development runner: unless an external dev cloud was
// explicitly supplied, own a worktree-isolated Worker, sign the Dev Cloud
// server into it, and point the iOS app at it. The dev cloud is the app's
// only route to a machine, so the development-account sign-in button must be
// available without requiring a separate `wrangler dev` process.
let cloud
if (externalCloudURL === undefined) {
  await run(
    "bun",
    [
      "x",
      "wrangler",
      "d1",
      "migrations",
      "apply",
      "codevisor-cloud",
      "--local",
      "--persist-to",
      cloudPersistPath
    ],
    join(repoRoot, "apps/cloud"),
    { ...process.env, CI: "1" }
  ).catch((error) => {
    console.error(`Cloud dev migrations failed (${error instanceof Error ? error.message : error})`)
  })
  const cloudDevVariables = await readCloudDevVariables()
  const cloudExtraVariables = Object.entries(cloudDevVariables)
    .filter(([key]) => !key.startsWith("CODEVISOR_DEV_"))
    .flatMap(([key, value]) => ["--var", `${key}:${value}`])
  cloud = spawn(
    "bun",
    [
      "x",
      "wrangler",
      "dev",
      ...(containerContext === undefined ? [] : ["--ip", "0.0.0.0"]),
      "--port",
      String(cloudPort),
      "--persist-to",
      cloudPersistPath,
      "--var",
      "DEV_AUTH:1",
      "--var",
      `PUBLIC_BASE_URL:${cloudURL}`,
      "--var",
      `INSTANCE_NAME:Codevisor Cloud (${worktreeName})`,
      ...cloudExtraVariables,
      "--show-interactive-dev-session=false"
    ],
    { cwd: join(repoRoot, "apps/cloud"), env: cloudWranglerEnvironment(), stdio: "inherit" }
  )
}

// Sign into the dev cloud first so the cloud test server boots
// cloud-connected and the app can offer the explicit development-account
// action.
const cloudSession = await resolveCloudSession(cloudURL, cloud)
if (cloudSession === undefined) {
  console.warn(
    "Without a dev cloud the simulator app cannot reach any machine; " +
      "check the cloud output above or CODEVISOR_DEV_CLOUD_URL."
  )
}

// Dev Cloud: a standalone server that signs into the dev cloud and is
// reached through it — the hub's realistic "machine somewhere else", and the
// machine the simulator app sees after signing into the dev account.
const cloudRemoteServer = await launchDevRemoteServer({
  containerContext,
  repoRoot,
  remoteRootHost: join(layout.tmpRoot, "remote-cloud"),
  serverRoots: layout.remoteCloud,
  port: cloudRemotePort,
  serverName: cloudRemoteName,
  directPath: "disabled",
  environment: {
    ...remoteDevelopmentEnvironment(layout, process.env),
    CODEVISOR_DEV_INSTANCE_ID: `${instanceName}-cloud`,
    ...(cloudSession === undefined
      ? {}
      : {
          CODEVISOR_DEV_CLOUD_URL: cloudSession.url,
          CODEVISOR_DEV_CLOUD_TOKEN: cloudSession.token
        })
  }
})

let stopping = false
let iosTarget

const stop = async (exitCode = 0) => {
  if (stopping) return
  stopping = true
  await terminateIOSDevelopmentApp(iosTarget)
  try {
    await fetch(`${cloudRemoteURL}/v1/shutdown`, {
      method: "POST",
      signal: AbortSignal.timeout(1_000)
    })
  } catch {
    cloudRemoteServer.kill("SIGTERM")
  }
  cloud?.kill("SIGTERM")
  await Promise.race([waitForExit(cloudRemoteServer), delay(2_000)])
  if (cloudRemoteServer.exitCode === null) cloudRemoteServer.kill("SIGTERM")
  process.exitCode = exitCode
}

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => void stop(0))
}

const watchServerExit = (child, label) =>
  waitForExit(child).then(async (result) => {
    if (!stopping) {
      console.error(`${label} exited unexpectedly (${describeExit(result)}).`)
      await stop(result.code ?? 1)
    }
  })
const serverExit = watchServerExit(cloudRemoteServer, "Codevisor dev cloud server")

try {
  iosTarget = await buildIOSDevelopmentApp({
    repoRoot,
    layout,
    appDisplayName,
    bundleIdentifier,
    urlScheme,
    developmentIconColor,
    environment: process.env
  })

  // First container boots may need to provision Linux dependencies.
  const remoteHealthAttempts = containerContext === undefined ? 120 : 2400
  await waitForHealth(cloudRemotePort, cloudRemoteServer, remoteHealthAttempts)

  await launchIOSDevelopmentApp({
    repoRoot,
    target: iosTarget,
    environment: process.env,
    worktreeName,
    instanceName,
    developmentIconColor,
    cloudURL: cloudSession?.url
  })
  console.log(`${cloudRemoteName} appears after signing into the dev cloud.`)
  console.log("Press Ctrl+C to stop the servers (the simulator stays open).")

  await serverExit
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  await stop(1)
}

function run(command, arguments_, cwd = repoRoot, environment = process.env) {
  console.log(`\n$ ${command} ${arguments_.join(" ")}`)
  const child = spawn(command, arguments_, { cwd, env: environment, stdio: "inherit" })
  return waitForExit(child).then((result) => {
    if (result.code === 0) return
    throw new Error(`${command} failed (${describeExit(result)})`)
  })
}

function capture(command, arguments_) {
  const child = spawn(command, arguments_, {
    cwd: repoRoot,
    env: process.env,
    stdio: ["ignore", "pipe", "inherit"]
  })
  let output = ""
  child.stdout.setEncoding("utf8")
  child.stdout.on("data", (chunk) => {
    output += chunk
  })
  return waitForExit(child).then((result) => {
    if (result.code === 0) return output
    throw new Error(`${command} failed (${describeExit(result)})`)
  })
}

// Signs into the selected dev cloud. A managed Worker gets a short readiness
// window; an explicitly supplied instance gets one bounded probe so a dead URL
// cannot stall the entire iOS runner.
async function resolveCloudSession(cloudUrl, ownedCloud) {
  const attempts = ownedCloud === undefined ? 1 : 120
  let lastError
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (
      ownedCloud !== undefined &&
      (ownedCloud.exitCode !== null || ownedCloud.signalCode !== null)
    ) {
      break
    }
    try {
      const response = await fetch(`${cloudUrl}/dev/login`, {
        method: "POST",
        signal: AbortSignal.timeout(1_000)
      })
      if (!response.ok) throw new Error(`dev login returned ${response.status}`)
      const { token } = await response.json()
      console.log(`Cloud dev instance: ${cloudUrl} (dev account session issued)`)
      return { url: cloudUrl, token }
    } catch (error) {
      lastError = error
      if (attempt + 1 < attempts) await delay(250)
    }
  }
  console.warn(
    `Cloud dev instance unavailable (${lastError instanceof Error ? lastError.message : lastError}); continuing without it.`
  )
  return undefined
}

// Locate apps/cloud/.dev.vars in this worktree or the main checkout so the
// managed iOS cloud offers the same configured providers as `bun run dev`.
async function readCloudDevVariables() {
  const candidates = [join(repoRoot, "apps/cloud/.dev.vars")]
  try {
    const commonDir = (await capture("git", ["rev-parse", "--git-common-dir"])).trim()
    const mainRoot = resolve(repoRoot, commonDir, "..")
    if (mainRoot !== repoRoot) candidates.push(join(mainRoot, "apps/cloud/.dev.vars"))
  } catch {
    // Not a git checkout (or git missing): worktree-local file only.
  }
  for (const candidate of candidates) {
    let content
    try {
      content = await readFile(candidate, "utf8")
    } catch {
      continue
    }
    const variables = {}
    for (const line of content.split("\n")) {
      const trimmed = line.trim()
      if (trimmed === "" || trimmed.startsWith("#")) continue
      const separator = trimmed.indexOf("=")
      if (separator === -1) continue
      variables[trimmed.slice(0, separator).trim()] = trimmed
        .slice(separator + 1)
        .trim()
        .replace(/^"(.*)"$/, "$1")
    }
    return variables
  }
  return {}
}
