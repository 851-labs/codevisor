import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { realpath } from "node:fs/promises"
import { basename, join } from "node:path"
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
import { makeCommandRunner, readCloudDevVariables } from "./dev-host-tools.mjs"
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
const { capture } = makeCommandRunner(repoRoot)
const simulator = await requireIOSSimulator(repoRoot)
const { wantsContainers, containerEnginePreference } = parseDevelopmentRunnerArguments(
  process.argv.slice(2)
)
const worktreeName = basename(repoRoot)
const instanceHash = createHash("sha256").update(repoRoot).digest("hex").slice(0, 10)
const instanceName = `${worktreeName}-${instanceHash}`
const layout = developmentLayout(repoRoot)
const cloudRemoteDataDirectory = layout.remoteCloud.data
const cloudRemoteName = `Dev Cloud (${worktreeName})`
const worktreeHash = createHash("sha256").update(worktreeName).digest("hex")
const developmentIconColor = colorFromHash(worktreeHash)
const appDisplayName = `Codevisor (${worktreeName})`
const bundleIdentifier = iosDevelopmentBundleIdentifier(repoRoot)
const urlScheme = `codevisor-dev-${instanceHash}`

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
let cloudPort
if (externalCloudURL === undefined) {
  cloudPort = requestedCloudPort ?? (await findAvailablePort(preferredCloudPort, 41_000, 10_000))
}
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

let containerEngine
if (wantsContainers) containerEngine = await resolveContainerEngine(containerEnginePreference)
if (wantsContainers && containerEngine === undefined) {
  console.warn("No usable container engine; the dev remote runs as a same-host process.")
}
let containerContext
if (containerEngine !== undefined) {
  containerContext = await prepareDevContainers({
    repoRoot,
    containerRoot: join(layout.tmpRoot, "container"),
    engine: containerEngine,
    worktreeHash: instanceHash
  })
}

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
  const cloudDevVariables = await readCloudDevVariables(repoRoot, capture)
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
      `HOOKS_BASE_URL:${cloudURL}/hooks`,
      "--var",
      `INSTANCE_NAME:Codevisor Cloud (${worktreeName})`,
      ...cloudExtraVariables,
      "--show-interactive-dev-session=false"
    ],
    { cwd: join(repoRoot, "apps/cloud"), env: cloudWranglerEnvironment(), stdio: "inherit" }
  )
}

const cloudSession = await resolveCloudSession(cloudURL, cloud)
if (cloudSession === undefined) {
  console.warn(
    "Without a dev cloud the simulator app cannot reach any machine; " +
      "check the cloud output above or CODEVISOR_DEV_CLOUD_URL."
  )
}

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
    `Cloud dev instance unavailable (${lastError instanceof Error ? lastError.message : String(lastError)}); continuing without it.`
  )
  return undefined
}
