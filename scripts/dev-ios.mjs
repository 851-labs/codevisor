// iOS development loop: starts the standalone "Dev Remote" Codevisor server on
// this Mac (the same isolated instance scripts/dev.mjs runs alongside the macOS
// app), starts a development cloud, then builds and launches the iOS app in the
// visible Simulator. No macOS app is built or launched — the iOS app is a pure
// client of the dev remote.
import { createHash } from "node:crypto"
import { spawn } from "node:child_process"
import { access, cp, mkdir, readdir, readFile, realpath, rm } from "node:fs/promises"
import { createServer } from "node:net"
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

const repoRoot = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const worktreeName = basename(repoRoot)
const instanceHash = createHash("sha256").update(repoRoot).digest("hex").slice(0, 10)
const instanceName = `${worktreeName}-${instanceHash}`
const layout = developmentLayout(repoRoot)
// Shared with scripts/dev.mjs's dev remote so the simulator talks to the same
// "Dev Remote" machine (same data, same stable token) either way.
const remoteDataDirectory = layout.remote.data
const remoteName = `Dev Remote (${worktreeName})`
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
const serverURL = `http://127.0.0.1:${remotePort}`
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
console.log(`  server:    ${serverURL}  (${remoteName})`)
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

// Sign into the dev cloud first so the standalone server boots cloud-connected
// and the app can offer the explicit development-account action.
const cloudSession = await resolveCloudSession(cloudURL, cloud)

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
    env: {
      ...remoteDevelopmentEnvironment(layout, process.env),
      CODEVISOR_DEV_INSTANCE_ID: `${instanceName}-remote`,
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
  try {
    await fetch(`${serverURL}/v1/shutdown`, { method: "POST" })
  } catch {
    server.kill("SIGTERM")
  }
  cloud?.kill("SIGTERM")
  await Promise.race([waitForExit(server), delay(2_000)])
  if (server.exitCode === null) server.kill("SIGTERM")
  await releaseDevelopmentRunner(layout.runtime.manifest, runnerManifest)
  process.exitCode = exitCode
}

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => void stop(0))
}

const serverExit = waitForExit(server).then(async (result) => {
  if (!stopping) {
    console.error(`Codevisor dev remote server exited unexpectedly (${describeExit(result)}).`)
    await stop(result.code ?? 1)
  }
})

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
    cloudSession
  })
  console.log("Press Ctrl+C to stop the server (the simulator stays open).")

  await serverExit
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  await stop(1)
}

function colorFromHash(hash) {
  const hue = Number.parseInt(hash.slice(0, 8), 16) % 360
  const saturation = 0.68
  const lightness = 0.5
  const chroma = (1 - Math.abs(2 * lightness - 1)) * saturation
  const section = hue / 60
  const x = chroma * (1 - Math.abs((section % 2) - 1))
  const [red, green, blue] =
    section < 1
      ? [chroma, x, 0]
      : section < 2
        ? [x, chroma, 0]
        : section < 3
          ? [0, chroma, x]
          : section < 4
            ? [0, x, chroma]
            : section < 5
              ? [x, 0, chroma]
              : [chroma, 0, x]
  const match = lightness - chroma / 2
  const channels = [red + match, green + match, blue + match]
  const bytes = channels.map((channel) => Math.round(channel * 255))
  return {
    hex: `#${bytes.map((byte) => byte.toString(16).padStart(2, "0")).join("")}`,
    composer: `extended-srgb:${channels.map((channel) => channel.toFixed(5)).join(",")},1.00000`
  }
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

function parsePort(value, name) {
  if (value === undefined) return undefined
  const parsed = Number(value)
  if (!Number.isInteger(parsed) || parsed < 1_024 || parsed > 65_535) {
    throw new Error(`${name} must be an integer from 1024 through 65535; received ${value}`)
  }
  return parsed
}

async function findAvailablePort(preferred, base, range) {
  for (let offset = 0; offset < range; offset += 1) {
    const candidate = base + ((preferred - base + offset) % range)
    if (await isPortAvailable(candidate)) return candidate
  }
  throw new Error(
    `No available Codevisor development port was found in ${base}-${base + range - 1}`
  )
}

function isPortAvailable(port) {
  return new Promise((resolve) => {
    const probe = createServer()
    probe.unref()
    probe.once("error", () => resolve(false))
    probe.listen(port, "0.0.0.0", () => probe.close(() => resolve(true)))
  })
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

async function pathExists(path) {
  try {
    await access(path)
    return true
  } catch {
    return false
  }
}

async function directoryIsEmpty(path) {
  try {
    return (await readdir(path)).length === 0
  } catch (error) {
    if (error?.code === "ENOENT") return true
    throw error
  }
}

async function containsAnyPath(root, names) {
  return (await Promise.all(names.map((name) => pathExists(join(root, name))))).some(Boolean)
}

async function waitForHealth(port, child) {
  for (let attempt = 0; attempt < 120; attempt += 1) {
    if (child.exitCode !== null) throw new Error("Codevisor server exited before becoming healthy")
    try {
      const response = await fetch(`http://127.0.0.1:${port}/v1/health`)
      if (response.ok) return
    } catch {
      // The listener is still starting.
    }
    await delay(250)
  }
  throw new Error(`Timed out waiting for the Codevisor server on port ${port}`)
}

function waitForExit(child) {
  if (child.exitCode !== null || child.signalCode !== null) {
    return Promise.resolve({ code: child.exitCode, signal: child.signalCode })
  }
  return new Promise((resolve) => {
    child.once("exit", (code, signal) => resolve({ code, signal }))
  })
}

function describeExit({ code, signal }) {
  return signal === null ? `code ${code ?? 1}` : `signal ${signal}`
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds))
}
