// iOS development loop: starts the standalone "Dev Direct" Codevisor server on
// this Mac (the same isolated instance scripts/dev.mjs runs alongside the macOS
// app) plus the cloud-joined "Dev Cloud" server, starts a development cloud,
// then builds and launches the iOS app in the visible Simulator. No macOS app
// is built or launched — the iOS app is a pure client of the dev servers.
import { createHash } from "node:crypto"
import { spawn } from "node:child_process"
import { cp, mkdir, readFile, realpath, rm } from "node:fs/promises"
import { basename, join, resolve } from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"

import { bootstrapDevelopment } from "./dev-bootstrap.mjs"
import {
  developmentLayout,
  ensureDevelopmentDirectories,
  iosDevelopmentBundleIdentifier,
  localDevelopmentEnvironment,
  remoteDevelopmentEnvironment
} from "./dev-layout.mjs"
import {
  buildIOSDevelopmentApp,
  launchIOSDevelopmentApp,
  terminateIOSDevelopmentApp
} from "./dev-ios-target.mjs"
import { claimDevelopmentRunner, releaseDevelopmentRunner } from "./dev-runtime.mjs"
import {
  colorFromHash,
  containsAnyPath,
  delay,
  describeExit,
  directoryIsEmpty,
  findAvailablePort,
  isPortAvailable,
  parsePort,
  pathExists,
  waitForExit,
  waitForHealth
} from "./dev-shared.mjs"

const repoRoot = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const worktreeName = basename(repoRoot)
const instanceHash = createHash("sha256").update(repoRoot).digest("hex").slice(0, 10)
const instanceName = `${worktreeName}-${instanceHash}`
const layout = developmentLayout(repoRoot)
// Shared with scripts/dev.mjs's dev servers so the simulator talks to the
// same machines (same data, same stable tokens) either way.
const remoteDataDirectory = layout.remote.data
const remoteName = `Dev Direct (${worktreeName})`
const cloudRemoteName = `Dev Cloud (${worktreeName})`
// Same hash → hue derivation as scripts/dev.mjs, so a worktree's iOS icon
// color matches its macOS icon color.
const worktreeHash = createHash("sha256").update(worktreeName).digest("hex")
const developmentIconColor = colorFromHash(worktreeHash)
const appDisplayName = `Codevisor (${worktreeName})`
const bundleIdentifier = iosDevelopmentBundleIdentifier(repoRoot)
const urlScheme = `codevisor-dev-${instanceHash}`
const simulatorName = process.env.CODEVISOR_IOS_SIMULATOR ?? "iPhone 17 Pro"

const preferredPort = 51_000 + (Number.parseInt(instanceHash.slice(0, 8), 16) % 10_000)
const requestedPort = parsePort(process.env.CODEVISOR_DEV_REMOTE_PORT, "CODEVISOR_DEV_REMOTE_PORT")
const remotePort = requestedPort ?? (await findAvailablePort(preferredPort + 1, 51_000, 10_000))
const cloudRemotePort = await findAvailablePort(remotePort + 1, 51_000, 10_000)
const serverURL = `http://127.0.0.1:${remotePort}`
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

const legacyRemoteDataDirectory = join(layout.tmpRoot, "codevisor-remote")
if (
  (await pathExists(join(legacyRemoteDataDirectory, "codevisor-server.sqlite"))) &&
  (await directoryIsEmpty(remoteDataDirectory)) &&
  !(await containsAnyPath(legacyRemoteDataDirectory, ["repos", "plugins", "worktrees"]))
) {
  console.log(`Moving dev remote state into ${remoteDataDirectory}`)
  await rm(remoteDataDirectory, { recursive: true, force: true })
  await mkdir(layout.remote.root, { recursive: true })
  await cp(legacyRemoteDataDirectory, remoteDataDirectory, { recursive: true })
  await rm(legacyRemoteDataDirectory, { recursive: true, force: true })
}

await ensureDevelopmentDirectories(layout)
const runnerManifest = {
  kind: "ios",
  pid: process.pid,
  repoRoot,
  startedAt: new Date().toISOString()
}
await claimDevelopmentRunner(layout.runtime.manifest, runnerManifest)
Object.assign(process.env, localDevelopmentEnvironment(layout, process.env))

console.log(`Codevisor iOS development instance: ${worktreeName}`)
console.log(`  direct:    ${serverURL}  (${remoteName})`)
console.log(`  viacloud:  ${cloudRemoteURL}  (${cloudRemoteName})`)
console.log(`  data:      ${remoteDataDirectory}`)
console.log(`  simulator: ${simulatorName}`)
console.log(`  app:       ${appDisplayName} (${bundleIdentifier})`)
console.log(`  icon:      ${developmentIconColor.hex}`)
console.log(`  cloud:     ${cloudURL}${externalCloudURL === undefined ? " (managed)" : ""}`)

await bootstrapDevelopment(repoRoot, { environment: process.env })
await run("bun", ["run", "--cwd", "apps/server", "build"])

// Match the macOS development runner: unless an external dev cloud was
// explicitly supplied, own a worktree-isolated Worker and hand its dev-user
// session to both the standalone server and the iOS app. This keeps the
// development-account sign-in button available without requiring a separate
// `wrangler dev` process.
let cloud
if (externalCloudURL === undefined) {
  await run("bun", ["run", "build:css"], join(repoRoot, "apps/cloud"))
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
    { cwd: join(repoRoot, "apps/cloud"), env: process.env, stdio: "inherit" }
  )
}

// Sign into the dev cloud first so the cloud test server boots
// cloud-connected and the app can offer the explicit development-account
// action.
const cloudSession = await resolveCloudSession(cloudURL, cloud)

// Dev Direct: the machine the simulator adds by token/deeplink. It gets NO
// cloud environment — a direct machine must stay direct.
const directRemoteEnvironment = {
  ...remoteDevelopmentEnvironment(layout, process.env),
  CODEVISOR_DEV_INSTANCE_ID: `${instanceName}-direct`
}
delete directRemoteEnvironment.CODEVISOR_DEV_CLOUD_URL
delete directRemoteEnvironment.CODEVISOR_DEV_CLOUD_TOKEN
const server = spawn(
  "node",
  [
    join(repoRoot, "apps/server/dist/main.js"),
    "serve",
    "--host",
    "0.0.0.0",
    "--port",
    String(remotePort),
    "--db",
    join(remoteDataDirectory, "codevisor-server.sqlite"),
    "--auth",
    "token",
    "--kind",
    "remote",
    "--name",
    remoteName,
    "--upgrade-status",
    join(remoteDataDirectory, "data-upgrade.json")
  ],
  {
    cwd: repoRoot,
    env: directRemoteEnvironment,
    stdio: "inherit"
  }
)

// Dev Cloud: a second standalone server that signs into the dev cloud and is
// reached through the relay — the hub's realistic "machine somewhere else".
const cloudRemoteServer = spawn(
  "node",
  [
    join(repoRoot, "apps/server/dist/main.js"),
    "serve",
    "--host",
    "0.0.0.0",
    "--port",
    String(cloudRemotePort),
    "--db",
    join(layout.remoteCloud.data, "codevisor-server.sqlite"),
    "--auth",
    "token",
    "--kind",
    "remote",
    "--name",
    cloudRemoteName,
    "--upgrade-status",
    join(layout.remoteCloud.data, "data-upgrade.json")
  ],
  {
    cwd: repoRoot,
    env: {
      ...remoteDevelopmentEnvironment(layout, process.env, layout.remoteCloud),
      CODEVISOR_DEV_INSTANCE_ID: `${instanceName}-cloud`,
      ...(cloudSession === undefined
        ? {}
        : {
            CODEVISOR_DEV_CLOUD_URL: cloudSession.url,
            CODEVISOR_DEV_CLOUD_TOKEN: cloudSession.token
          })
    },
    stdio: "inherit"
  }
)

let stopping = false
let iosTarget

const stop = async (exitCode = 0) => {
  if (stopping) return
  stopping = true
  terminateIOSDevelopmentApp(iosTarget)
  for (const [url, child] of [
    [serverURL, server],
    [cloudRemoteURL, cloudRemoteServer]
  ]) {
    try {
      await fetch(`${url}/v1/shutdown`, { method: "POST" })
    } catch {
      child.kill("SIGTERM")
    }
  }
  cloud?.kill("SIGTERM")
  await Promise.race([
    Promise.all([waitForExit(server), waitForExit(cloudRemoteServer)]),
    delay(2_000)
  ])
  for (const child of [server, cloudRemoteServer]) {
    if (child.exitCode === null) child.kill("SIGTERM")
  }
  await releaseDevelopmentRunner(layout.runtime.manifest, runnerManifest)
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
const serverExit = Promise.all([
  watchServerExit(server, "Codevisor dev direct server"),
  watchServerExit(cloudRemoteServer, "Codevisor dev cloud server")
])

try {
  iosTarget = await buildIOSDevelopmentApp({
    repoRoot,
    layout,
    simulatorName,
    appDisplayName,
    bundleIdentifier,
    urlScheme,
    developmentIconColor,
    environment: process.env
  })

  await waitForHealth(remotePort, server)
  await waitForHealth(cloudRemotePort, cloudRemoteServer)
  const token = await readConnectionToken()

  await launchIOSDevelopmentApp({
    repoRoot,
    target: iosTarget,
    environment: process.env,
    worktreeName,
    instanceName,
    developmentIconColor,
    remoteHost: "127.0.0.1",
    remotePort,
    remoteToken: token,
    remoteName,
    urlScheme,
    cloudURL: cloudSession?.url
  })
  console.log(
    `${cloudRemoteName} joins after dev-cloud sign-in; ${remoteName} is the token-added machine.`
  )
  console.log("Press Ctrl+C to stop the servers (the simulator stays open).")

  await serverExit
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  await stop(1)
}

async function readConnectionToken() {
  try {
    const response = await fetch(`${serverURL}/v1/auth/connection-token`)
    if (response.ok) return (await response.json()).token
  } catch {
    // Fall through: the address alone is enough to add the machine manually.
  }
  return ""
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
