import { spawn } from "node:child_process"
import { realpath, rm } from "node:fs/promises"
import { join } from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"

import { bootstrapDevelopment } from "./dev-bootstrap.mjs"
import { parseDevelopmentRunnerArguments } from "./dev-arguments.mjs"
import {
  applyCloudDevMigrations,
  prepareCloudSession,
  resolveCloudDevInstance,
  spawnCloudDev
} from "./dev-cloud.mjs"
import {
  launchDevRemoteServer,
  prepareDevContainers,
  readDevRemoteConnectionToken,
  resolveContainerEngine
} from "./dev-containers.mjs"
import {
  createDevelopmentAppIcon,
  createDevelopmentBrowserExtensionIcons,
  makeCommandRunner,
  resolveDevelopmentSigningArguments,
  terminateExactDevelopmentApp
} from "./dev-host-tools.mjs"
import {
  migrateLegacyDevelopmentState,
  resolveDevelopmentInstance,
  sanitizeAmbientEnvironment
} from "./dev-instance.mjs"
import {
  buildIOSDevelopmentApp,
  launchIOSDevelopmentApp,
  terminateIOSDevelopmentApp
} from "./dev-ios-target.mjs"
import {
  ensureDevelopmentDirectories,
  localDevelopmentEnvironment,
  remoteDevelopmentEnvironment
} from "./dev-layout.mjs"
import { claimDevelopmentRunner, releaseDevelopmentRunner } from "./dev-runtime.mjs"
import { delay, describeExit, waitForExit, waitForHealth } from "./dev-shared.mjs"
import { runXcodebuild } from "./xcodebuild.mjs"

const repoRoot = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const arguments_ = process.argv.slice(2)
const { wantsContainers, containerEnginePreference } = parseDevelopmentRunnerArguments(arguments_, {
  allowedArguments: ["--no-ios"]
})
// Both apps by default — `dev` means the whole rig. `--no-ios` backs the
// dev:macos script; it is plumbing, not a user-facing option (the public
// surface is dev / dev:macos / dev:ios plus the container flags).
const includesIOS = !arguments_.includes("--no-ios")
// Containerized dev remotes are the default: real Linux machines make
// cross-machine sync honest. --no-containers opts out; a missing engine
// falls back to same-host processes with a warning either way.
sanitizeAmbientEnvironment(process.env)
const instance = await resolveDevelopmentInstance(repoRoot, process.env)
const {
  appBundle,
  appExecutable,
  appName,
  appServerName,
  cloudRemoteName,
  cloudRemotePort,
  dataDirectory,
  derivedDataPath,
  developmentIconColor,
  directRemoteName,
  directRemotePort,
  iOSBundleIdentifier,
  instanceHash,
  instanceName,
  layout,
  macOSBundleIdentifier,
  port,
  simulatorName,
  urlScheme,
  worktreeName,
  worktreesDirectory,
  wwwPort
} = instance
const { capture, run } = makeCommandRunner(repoRoot)
const { cloudExtraVariables, cloudPersistPath, cloudPort, cloudUrl } =
  await resolveCloudDevInstance({
    environment: process.env,
    instanceHash,
    layout,
    repoRoot
  })
await migrateLegacyDevelopmentState(instance, repoRoot)

await ensureDevelopmentDirectories(layout)
const runnerManifest = {
  kind: includesIOS ? "all" : "macos",
  pid: process.pid,
  repoRoot,
  startedAt: new Date().toISOString()
}
await claimDevelopmentRunner(layout.runtime.manifest, runnerManifest)
Object.assign(process.env, localDevelopmentEnvironment(layout, process.env))

console.log(`Codevisor development instance: ${worktreeName}`)
console.log(`  app:      ${appName}`)
console.log(`  server:   http://127.0.0.1:${port}`)
console.log(`  www:      http://localhost:${wwwPort}`)
console.log(`  direct:   http://127.0.0.1:${directRemotePort}  (${directRemoteName})`)
console.log(`  viacloud: http://127.0.0.1:${cloudRemotePort}  (${cloudRemoteName})`)
console.log(`  cloud:    ${cloudUrl}`)
console.log(`  data:     ${dataDirectory}`)
console.log(`  worktrees:${worktreesDirectory}`)
console.log(`  icon:     ${developmentIconColor.hex}`)
if (includesIOS) console.log(`  targets:  macOS + iOS (${simulatorName})`)

await bootstrapDevelopment(repoRoot, { environment: process.env, ghostty: true })
await run("bun", ["run", "--cwd", "apps/server", "build"])

// The local cloud instance: real Workers runtime (workerd) with local D1 and
// Durable Objects, persisted under tmp/ like all other dev state. Started
// before the app build so it is healthy — and the dev session is signed in —
// by the time the servers spawn and need CODEVISOR_DEV_CLOUD_TOKEN.
// cwd apps/cloud so bunx resolves the workspace's wrangler version — a
// stray/global wrangler brings its own (older) workerd, which cannot read
// local D1/DO state written by the workspace version. Failures fall through
// to prepareCloudSession's "continuing without it" path instead of crashing.
await applyCloudDevMigrations({ cloudPersistPath, repoRoot, run })
// Containerized dev remotes: Dev Direct and Dev Cloud run as
// real Linux machines so config-plane sync is tested across genuinely
// separate filesystems. Falls back to same-host processes when no engine
// is available — never boots a stopped Docker daemon.
const containerEngine = wantsContainers
  ? await resolveContainerEngine(containerEnginePreference)
  : undefined
if (wantsContainers && containerEngine === undefined) {
  console.warn("No usable container engine; dev remotes run as same-host processes.")
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

const cloud = spawnCloudDev({
  cloud: { cloudExtraVariables, cloudPersistPath, cloudPort, cloudUrl },
  containerized: containerContext !== undefined,
  repoRoot,
  worktreeName
})

const generatedIconDirectory = await createDevelopmentAppIcon(repoRoot, developmentIconColor)
const developmentSigningArguments = await resolveDevelopmentSigningArguments(capture)
try {
  await runXcodebuild(
    repoRoot,
    "macos",
    [
      "-project",
      "apps/macos/Codevisor.xcodeproj",
      "-scheme",
      "Codevisor",
      "-configuration",
      "Debug",
      `CODEVISOR_DEV_PRODUCT_NAME=${appName}`,
      `CODEVISOR_DEV_DISPLAY_NAME=${appName}`,
      `CODEVISOR_DEV_BUNDLE_IDENTIFIER=${macOSBundleIdentifier}`,
      `CODEVISOR_URL_SCHEME=${urlScheme}`,
      "ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDevGenerated",
      "INFOPLIST_KEY_CFBundleIconFile=AppIconDevGenerated",
      "INFOPLIST_KEY_CFBundleIconName=AppIconDevGenerated",
      ...developmentSigningArguments,
      "build"
    ],
    { environment: process.env, layout }
  )
} finally {
  await rm(generatedIconDirectory, { recursive: true, force: true })
}
let iosTarget
if (includesIOS) {
  iosTarget = await buildIOSDevelopmentApp({
    repoRoot,
    layout,
    simulatorName,
    appDisplayName: appName,
    bundleIdentifier: iOSBundleIdentifier,
    urlScheme,
    developmentIconColor,
    environment: process.env
  })
}
const developmentBrowserIconDirectory = await createDevelopmentBrowserExtensionIcons({
  appName,
  derivedDataPath,
  layout,
  run
})

const sharedEnvironment = {
  ...localDevelopmentEnvironment(layout, process.env),
  CODEVISOR_DEV_WORKTREE: worktreeName,
  CODEVISOR_DEV_INSTANCE_ID: instanceName,
  CODEVISOR_DEV_ICON_COLOR: developmentIconColor.hex,
  CODEVISOR_DEV_EXTENSION_ICON_DIR: developmentBrowserIconDirectory,
  CODEVISOR_DEV_PORT: String(port),
  CODEVISOR_DEV_WWW_PORT: String(wwwPort),
  // The direct dev server's details, so the app can offer a one-click "add
  // the test remote" in Settings → Machines (the token is filled in once
  // it's read). The cloud dev server is deliberately absent here — it
  // arrives through the dev cloud account, exercising the relay path.
  CODEVISOR_DEV_REMOTE_HOST: "127.0.0.1",
  CODEVISOR_DEV_REMOTE_PORT: String(directRemotePort),
  CODEVISOR_DEV_REMOTE_NAME: directRemoteName,
  CODEVISOR_DEV_REMOTE_TOKEN: "",
  // The local cloud instance (auth + relay). The token is a dev-user session
  // filled in once the cloud is healthy, so clients can sign in without any
  // GitHub OAuth setup.
  CODEVISOR_DEV_CLOUD_URL: cloudUrl,
  // Vite only exposes VITE_-prefixed vars to app code (import.meta.env);
  // the www plugin directory uses these to hit the dev cloud registry and to
  // deeplink into this instance's app (not some other worktree's).
  VITE_CODEVISOR_DEV_CLOUD_URL: cloudUrl,
  CODEVISOR_DEV_URL_SCHEME: urlScheme,
  VITE_CODEVISOR_DEV_URL_SCHEME: urlScheme,
  CODEVISOR_DEV_CLOUD_TOKEN: ""
}
/// Everything except the dev-cloud session token. Only the Dev Cloud
/// container is pre-signed-in (the "machine somewhere else"); every other
/// process authenticates exactly as it would in production.
const withoutCloudToken = (environment) => {
  const copy = { ...environment }
  delete copy.CODEVISOR_DEV_CLOUD_TOKEN
  return copy
}
const databasePath = join(dataDirectory, "codevisor-server.sqlite")
const upgradeStatusPath = join(dataDirectory, "data-upgrade.json")
// Sign into the dev cloud BEFORE spawning servers, so their environment
// carries a real session token and they auto-provision into the hub.
await prepareCloudSession({ cloudProcess: cloud, cloudUrl, sharedEnvironment })

const server = spawn(
  "node",
  [
    join(repoRoot, "apps/server/dist/main.js"),
    "serve",
    "--host",
    "0.0.0.0",
    "--port",
    String(port),
    "--db",
    databasePath,
    "--auth",
    "token",
    "--kind",
    "local",
    "--name",
    appServerName,
    "--upgrade-status",
    upgradeStatusPath
  ],
  // No session token: in production the Mac App's server joins the cloud
  // when the user signs into the app, which then registers it. The dev
  // cloud URL stays so that sign-in targets the local cloud instance.
  { cwd: repoRoot, env: withoutCloudToken(sharedEnvironment), stdio: "inherit" }
)

const www = spawn(
  "bun",
  ["run", "--cwd", "apps/www", "dev", "--port", String(wwwPort), "--strictPort"],
  { cwd: repoRoot, env: sharedEnvironment, stdio: "inherit" }
)

// Dev Direct: a standalone server fully isolated from the local instance
// (its own data dir, worktrees, and managed repos), added by token/deeplink
// so direct-connection flows mirror talking to a real second machine. It
// gets NO cloud environment — a direct machine must stay direct.
const directRemoteEnvironment = {
  ...remoteDevelopmentEnvironment(layout, process.env),
  CODEVISOR_DEV_INSTANCE_ID: `${instanceName}-direct`
}
delete directRemoteEnvironment.CODEVISOR_DEV_CLOUD_URL
delete directRemoteEnvironment.CODEVISOR_DEV_CLOUD_TOKEN
const directRemoteServer = await launchDevRemoteServer({
  containerContext,
  repoRoot,
  remoteRootHost: join(layout.tmpRoot, "remote"),
  serverRoots: layout.remote,
  port: directRemotePort,
  serverName: directRemoteName,
  environment: directRemoteEnvironment
})

// Dev Cloud: a second standalone server that signs into the dev cloud and is
// reached through the relay — the hub's realistic "machine somewhere else".
const cloudRemoteServer = await launchDevRemoteServer({
  containerContext,
  repoRoot,
  remoteRootHost: join(layout.tmpRoot, "remote-cloud"),
  serverRoots: layout.remoteCloud,
  port: cloudRemotePort,
  serverName: cloudRemoteName,
  environment: {
    ...remoteDevelopmentEnvironment(layout, process.env, layout.remoteCloud),
    CODEVISOR_DEV_INSTANCE_ID: `${instanceName}-cloud`,
    CODEVISOR_DEV_CLOUD_URL: cloudUrl,
    CODEVISOR_DEV_CLOUD_TOKEN: sharedEnvironment.CODEVISOR_DEV_CLOUD_TOKEN
  }
})

let app
let stopping = false

const stop = async (exitCode = 0) => {
  if (stopping) return
  stopping = true
  terminateExactDevelopmentApp(appExecutable)
  terminateIOSDevelopmentApp(iosTarget)
  app?.kill("SIGTERM")
  www.kill("SIGTERM")
  cloud.kill("SIGTERM")

  for (const [servicePort, child] of [
    [port, server],
    [directRemotePort, directRemoteServer],
    [cloudRemotePort, cloudRemoteServer]
  ]) {
    try {
      await fetch(`http://127.0.0.1:${servicePort}/v1/shutdown`, { method: "POST" })
    } catch {
      child.kill("SIGTERM")
    }
  }

  await Promise.race([
    Promise.all([
      waitForExit(server),
      waitForExit(directRemoteServer),
      waitForExit(cloudRemoteServer)
    ]),
    delay(2_000)
  ])
  for (const child of [server, directRemoteServer, cloudRemoteServer]) {
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
  watchServerExit(server, "Codevisor server"),
  watchServerExit(directRemoteServer, "Codevisor dev direct server"),
  watchServerExit(cloudRemoteServer, "Codevisor dev cloud server")
])

void waitForExit(www).then((result) => {
  if (!stopping) {
    console.error(`www dev server exited unexpectedly (${describeExit(result)}).`)
  }
})

void waitForExit(cloud).then((result) => {
  if (!stopping) {
    console.error(`cloud dev server exited unexpectedly (${describeExit(result)}).`)
  }
})

try {
  await waitForHealth(port, server)
  // First container boots install Linux node_modules; allow minutes, not 30s.
  const remoteHealthAttempts = containerContext === undefined ? 120 : 2400
  await waitForHealth(directRemotePort, directRemoteServer, remoteHealthAttempts)
  await waitForHealth(cloudRemotePort, cloudRemoteServer, remoteHealthAttempts)
  const remoteToken = await announceDevRemote()
  // The apps sign into the dev cloud the production way (device-code
  // flow against CODEVISOR_DEV_CLOUD_URL); the session token never reaches
  // them, so cloud machines appear on a client only after a real sign-in.
  const launchEnvironment = Object.entries(withoutCloudToken(sharedEnvironment)).filter(
    ([key]) =>
      key === "TMPDIR" ||
      key.startsWith("CODEVISOR_") ||
      key.startsWith("HERDMAN_") ||
      key.startsWith("GHOSTTY_")
  )
  const openArguments = [
    "-n",
    "-W",
    ...launchEnvironment.flatMap(([key, value]) => ["--env", `${key}=${value}`]),
    appBundle
  ]
  // LaunchServices gives the app its own macOS responsibility identity. A
  // direct child executable inherits the invoking terminal/agent identity,
  // making an enabled Accessibility toggle appear denied after an update.
  app = spawn("/usr/bin/open", openArguments, {
    cwd: repoRoot,
    env: process.env,
    stdio: "inherit"
  })
  if (iosTarget !== undefined) {
    await launchIOSDevelopmentApp({
      repoRoot,
      target: iosTarget,
      environment: process.env,
      worktreeName,
      instanceName,
      developmentIconColor,
      remoteHost: "127.0.0.1",
      remotePort: directRemotePort,
      remoteToken,
      remoteName: directRemoteName,
      urlScheme,
      cloudURL: cloudUrl
    })
    console.log("Press Ctrl+C to stop both apps and their shared development services.")
  }
  const result = await waitForExit(app)
  if (!stopping) await stop(result.code ?? 0)
  await serverExit
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  await stop(1)
}

// Print the direct dev server's connection details so it can be added in the
// app. Its token is stable, so this only needs to be done once per instance.
async function announceDevRemote() {
  let token = "(start the server to read it)"
  try {
    token = await readDevRemoteConnectionToken(
      directRemoteServer,
      `http://127.0.0.1:${directRemotePort}`
    )
  } catch {
    // Non-fatal: the address alone is enough to add the machine.
  }
  // Hand the token to the app for the one-click "add test remote" action.
  sharedEnvironment.CODEVISOR_DEV_REMOTE_TOKEN = token
  const deeplink = `${urlScheme}://add-machine?host=127.0.0.1&port=${directRemotePort}&token=${token}&name=${encodeURIComponent(directRemoteName)}`
  console.log("")
  console.log(`Dev servers ready:`)
  console.log(`  ${directRemoteName} — direct-connection testing; add it in ${appName}:`)
  console.log(`    Settings → Machines → Add Remote Machine`)
  console.log(`    Address: 127.0.0.1:${directRemotePort}`)
  console.log(`    Token:   ${token}`)
  console.log(`    Or open: ${deeplink}`)
  console.log(`  ${cloudRemoteName} — relay testing; appears after signing into the dev cloud.`)
  console.log("")
  return token
}
