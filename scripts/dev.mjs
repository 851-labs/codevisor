import { createHash, X509Certificate } from "node:crypto"
import { execFileSync, spawn } from "node:child_process"
import { cp, mkdir, readFile, realpath, rm, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
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
import { runXcodebuild } from "./xcodebuild.mjs"

const repoRoot = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const arguments_ = process.argv.slice(2)
const unknownArguments = arguments_.filter((argument) => argument !== "--ios")
if (unknownArguments.length > 0) {
  throw new Error(`Unknown development runner argument: ${unknownArguments.join(", ")}`)
}
const includesIOS = arguments_.includes("--ios")

// Sanitize ambient Codevisor variables before anything inherits our env.
// This script is often launched from inside a running Codevisor instance
// (agent sessions, app terminals) whose server exports CODEVISOR_* state —
// e.g. CODEVISOR_APP_HOSTED=1 — which must never leak into the dev app or
// dev servers (a dev app that inherits APP_HOSTED thinks it manages its own
// server and hangs at "Starting Codevisor Server"). Only the documented
// dev-runner inputs survive.
const ambientAllowlist = new Set([
  "CODEVISOR_DEV_PORT",
  "HERDMAN_DEV_PORT",
  "CODEVISOR_DEV_WWW_PORT",
  "CODEVISOR_DEV_CLOUD_PORT",
  "CODEVISOR_DEV_DATA_DIR",
  "CODEVISOR_DEV_LOGS_DIR",
  "CODEVISOR_DEV_CACHE_DIR",
  "HERDMAN_DEV_DATA_DIR",
  "CODEVISOR_WORKTREES_ROOT",
  "HERDMAN_WORKTREES_ROOT",
  "CODEVISOR_REPOS_ROOT",
  "CODEVISOR_PLUGINS_ROOT",
  "CODEVISOR_GHOSTTY_ARTIFACTS_ROOT",
  "CODEVISOR_GHOSTTY_ARTIFACT_ORIGIN",
  "CODEVISOR_IOS_SIMULATOR",
  "CODEVISOR_VERSION",
  "HERDMAN_VERSION"
])
for (const key of Object.keys(process.env)) {
  if ((key.startsWith("CODEVISOR_") || key.startsWith("HERDMAN_")) && !ambientAllowlist.has(key)) {
    delete process.env[key]
  }
}
const worktreeName = basename(repoRoot)
const instanceHash = createHash("sha256").update(repoRoot).digest("hex").slice(0, 10)
const worktreeHash = createHash("sha256").update(worktreeName).digest("hex")
const developmentIconColor = colorFromHash(worktreeHash)
const instanceName = `${worktreeName}-${instanceHash}`
// Per-instance URL scheme, mirroring the per-instance bundle identifier:
// every dev worktree registering plain codevisor-dev:// would leave
// LaunchServices routing deeplinks to an arbitrary one of them. The Swift
// deeplink parsers accept the whole codevisor-dev-* family.
const urlScheme = `codevisor-dev-${instanceHash}`
const appName = `Codevisor (${worktreeName})`
const macOSBundleIdentifier = `com.851labs.Codevisor.Development.${instanceHash}`
const iOSBundleIdentifier = iosDevelopmentBundleIdentifier(repoRoot)
const layout = developmentLayout(repoRoot)
const tmpRoot = layout.tmpRoot
const derivedDataPath = layout.build.macos.derivedData
const appBundle = join(derivedDataPath, "Build", "Products", "Debug", `${appName}.app`)
const appExecutable = join(appBundle, "Contents", "MacOS", appName)
// The local dev instance and a standalone "remote" server each get their own
// production-shaped roots under tmp/: codevisor mirrors ~/codevisor and
// .codevisor mirrors ~/.codevisor. The fake remote repeats that layout.
const dataDirectory = layout.local.data
const remoteDataDirectory = layout.remote.data
const worktreesDirectory = layout.local.worktrees
const simulatorName = process.env.CODEVISOR_IOS_SIMULATOR ?? "iPhone 17 Pro"

const preferredPort = 51_000 + (Number.parseInt(instanceHash.slice(0, 8), 16) % 10_000)
const requestedPort = parsePort(
  process.env.CODEVISOR_DEV_PORT ?? process.env.HERDMAN_DEV_PORT,
  "CODEVISOR_DEV_PORT"
)
const port = requestedPort ?? (await findAvailablePort(preferredPort, 51_000, 10_000))

const preferredWwwPort = 61_000 + (Number.parseInt(instanceHash.slice(0, 8), 16) % 4_000)
const requestedWwwPort = parsePort(process.env.CODEVISOR_DEV_WWW_PORT, "CODEVISOR_DEV_WWW_PORT")
const wwwPort = requestedWwwPort ?? (await findAvailablePort(preferredWwwPort, 61_000, 4_000))

// The mac app's own server carries a name that says what it is in machine
// lists (the cloud hub, other devices' fleets).
const appServerName = `Mac App (${worktreeName})`
// Two standalone dev servers on this machine, each isolated from the local
// instance and from each other, named for the transport they exercise:
// - Dev Direct: added by token/deeplink; NEVER joins the dev cloud.
// - Dev Cloud: signs into the dev cloud; reached through the relay only.
const directRemotePort = await findAvailablePort(port + 1, 51_000, 10_000)
const directRemoteName = `Dev Direct (${worktreeName})`
const cloudRemotePort = await findAvailablePort(directRemotePort + 1, 51_000, 10_000)
const cloudRemoteName = `Dev Cloud (${worktreeName})`

// The cloud dev instance (apps/cloud on `wrangler dev`): auth + relay hub,
// running fully locally with DEV_AUTH enabled and state under tmp/. Like the
// server and www ports, its preferred port is stable for this worktree and it
// scans its own range when that port is occupied. Pin CODEVISOR_DEV_CLOUD_PORT
// only when testing real GitHub OAuth — OAuth apps allow exactly one callback
// URL, so it must match the registered
// http://localhost:<port>/api/auth/callback/github exactly.
// Optional cloud dev vars live in apps/cloud/.dev.vars — gitignored, created
// once in the MAIN clone. Worktrees read the main clone's copy automatically;
// a worktree-local .dev.vars takes precedence. See .dev.vars.example.
const cloudDevVariables = await readCloudDevVariables()
const preferredCloudPort = 41_000 + (Number.parseInt(instanceHash.slice(0, 8), 16) % 10_000)
const requestedCloudPort = parsePort(
  process.env.CODEVISOR_DEV_CLOUD_PORT,
  "CODEVISOR_DEV_CLOUD_PORT"
)
if (requestedCloudPort !== undefined && !(await isPortAvailable(requestedCloudPort))) {
  throw new Error(
    `CODEVISOR_DEV_CLOUD_PORT ${requestedCloudPort} is already in use; ` +
      "stop its owner or choose a different explicit port."
  )
}
const cloudPort =
  requestedCloudPort ?? (await findAvailablePort(preferredCloudPort, 41_000, 10_000))
const cloudUrl = `http://localhost:${cloudPort}`
const cloudExtraVariables = Object.entries(cloudDevVariables)
  // Keys prefixed CODEVISOR_DEV_ configure this script, not the Worker.
  .filter(([key]) => !key.startsWith("CODEVISOR_DEV_"))
  .flatMap(([key, value]) => ["--var", `${key}:${value}`])
const cloudPersistPath = layout.wrangler

// One-time move of earlier local app/server state into tmp/.codevisor/data.
// The old tmp/codevisor path is recognized only when it contains a server DB;
// after this migration that path belongs exclusively to dev worktrees.
if (dataDirectory === layout.local.data && (await directoryIsEmpty(dataDirectory))) {
  for (const previous of [
    join(tmpRoot, "codevisor"),
    join(repoRoot, ".codevisor"),
    join(homedir(), "Library", "Application Support", "Codevisor Development", instanceName)
  ]) {
    const isLegacyTmpData = previous === join(tmpRoot, "codevisor")
    if (
      (await pathExists(previous)) &&
      (!isLegacyTmpData || (await pathExists(join(previous, "codevisor-server.sqlite"))))
    ) {
      console.log(`Moving dev state into ${dataDirectory}`)
      await rm(dataDirectory, { recursive: true, force: true })
      await mkdir(layout.local.root, { recursive: true })
      await cp(previous, dataDirectory, { recursive: true })
      await rm(previous, { recursive: true, force: true })
      break
    }
  }
}

// The old fake-remote root contained flat server state. Move it only when it
// has no nested repos/worktrees whose Git metadata contains absolute paths.
const legacyRemoteDataDirectory = join(tmpRoot, "codevisor-remote")
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
  join(repoRoot, "apps/cloud")
).catch((error) => {
  console.error(`Cloud dev migrations failed (${error instanceof Error ? error.message : error})`)
})
const cloud = spawn(
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
    `PUBLIC_BASE_URL:${cloudUrl}`,
    "--var",
    `INSTANCE_NAME:Codevisor Cloud (${worktreeName})`,
    ...cloudExtraVariables,
    "--show-interactive-dev-session=false"
  ],
  { cwd: join(repoRoot, "apps/cloud"), env: process.env, stdio: "inherit" }
)

const generatedIconDirectory = await createDevelopmentAppIcon()
const developmentSigningArguments = await resolveDevelopmentSigningArguments()
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
const developmentBrowserIconDirectory = await createDevelopmentBrowserExtensionIcons()

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
const databasePath = join(dataDirectory, "codevisor-server.sqlite")
const upgradeStatusPath = join(dataDirectory, "data-upgrade.json")
// Sign into the dev cloud BEFORE spawning servers, so their environment
// carries a real session token and they auto-provision into the hub.
await prepareCloudSession()

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
  { cwd: repoRoot, env: sharedEnvironment, stdio: "inherit" }
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
const directRemoteServer = spawn(
  "node",
  [
    join(repoRoot, "apps/server/dist/main.js"),
    "serve",
    "--host",
    "0.0.0.0",
    "--port",
    String(directRemotePort),
    "--db",
    join(remoteDataDirectory, "codevisor-server.sqlite"),
    "--auth",
    "token",
    "--kind",
    "remote",
    "--name",
    directRemoteName,
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
      CODEVISOR_DEV_CLOUD_URL: cloudUrl,
      CODEVISOR_DEV_CLOUD_TOKEN: sharedEnvironment.CODEVISOR_DEV_CLOUD_TOKEN
    },
    stdio: "inherit"
  }
)

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
  await waitForHealth(directRemotePort, directRemoteServer)
  await waitForHealth(cloudRemotePort, cloudRemoteServer)
  const remoteToken = await announceDevRemote()
  const launchEnvironment = Object.entries(sharedEnvironment).filter(
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
    const cloudToken = sharedEnvironment.CODEVISOR_DEV_CLOUD_TOKEN
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
      cloudSession: cloudToken === "" ? undefined : { url: cloudUrl, token: cloudToken }
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
    const response = await fetch(`http://127.0.0.1:${directRemotePort}/v1/auth/connection-token`)
    if (response.ok) token = (await response.json()).token
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

// Wait for the cloud Worker, sign in as the dev user, and hand the session
// token to the app (Settings → Account works with zero GitHub OAuth setup).
// Non-fatal throughout: local dev must keep working when the cloud piece is
// broken or slow — it's additive, never required.
async function prepareCloudSession() {
  try {
    for (let attempt = 0; attempt < 120; attempt += 1) {
      if (cloud.exitCode !== null) return
      try {
        const health = await fetch(`${cloudUrl}/health`)
        if (health.ok) break
      } catch {
        // wrangler is still starting.
      }
      await delay(250)
    }
    const response = await fetch(`${cloudUrl}/dev/login`, { method: "POST" })
    if (!response.ok) throw new Error(`dev login returned ${response.status}`)
    const { token } = await response.json()
    sharedEnvironment.CODEVISOR_DEV_CLOUD_TOKEN = token
    console.log("")
    console.log(`Cloud dev instance ready at ${cloudUrl}`)
    console.log(`  Dev account session handed to the app — sign in via "Use Development Account".`)
    console.log(`  Device approvals: ${cloudUrl}/device`)
    console.log("")
  } catch (error) {
    console.error(
      `Cloud dev instance unavailable (${error instanceof Error ? error.message : error}); continuing without it.`
    )
  }
}

// Locate apps/cloud/.dev.vars: this worktree first, then the main clone (via
// git's common dir), so per-developer cloud config is created once and shared
// by every worktree — including app-created ones. Returns {} when absent or
// git is unavailable; the cloud runs fine on dev login alone.
async function readCloudDevVariables() {
  const candidates = [join(repoRoot, "apps/cloud/.dev.vars")]
  try {
    const commonDir = execFileSync("git", ["rev-parse", "--git-common-dir"], {
      cwd: repoRoot,
      encoding: "utf8"
    }).trim()
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

async function createDevelopmentAppIcon() {
  const templateDirectory = join(
    repoRoot,
    "apps",
    "macos",
    "Codevisor",
    "Resources",
    "AppIconDev.icon"
  )
  const generatedDirectory = join(
    repoRoot,
    "apps",
    "macos",
    "Codevisor",
    "Resources",
    "AppIconDevGenerated.icon"
  )
  await rm(generatedDirectory, { recursive: true, force: true })
  await mkdir(join(generatedDirectory, "Assets"), { recursive: true })
  const manifest = JSON.parse(await readFile(join(templateDirectory, "icon.json"), "utf8"))
  manifest.fill = { "automatic-gradient": developmentIconColor.composer }
  await writeFile(join(generatedDirectory, "icon.json"), `${JSON.stringify(manifest, null, 2)}\n`)
  await cp(
    join(templateDirectory, "Assets", "icon-v2.svg"),
    join(generatedDirectory, "Assets", "icon-v2.svg")
  )
  return generatedDirectory
}

async function createDevelopmentBrowserExtensionIcons() {
  const iconsetDirectory = join(layout.build.generated, "BrowserExtensionDev.iconset")
  const compiledIcon = join(
    derivedDataPath,
    "Build",
    "Products",
    "Debug",
    `${appName}.app`,
    "Contents",
    "Resources",
    "AppIconDevGenerated.icns"
  )
  await rm(iconsetDirectory, { recursive: true, force: true })
  await run("iconutil", ["--convert", "iconset", "--output", iconsetDirectory, compiledIcon])
  return iconsetDirectory
}

function run(command, arguments_, cwd = repoRoot) {
  console.log(`\n$ ${command} ${arguments_.join(" ")}`)
  const child = spawn(command, arguments_, { cwd, env: process.env, stdio: "inherit" })
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

function terminateExactDevelopmentApp(executable) {
  const pattern = `^${escapeRegularExpression(executable)}$`
  let processIDs
  try {
    processIDs = execFileSync("/usr/bin/pgrep", ["-f", pattern], { encoding: "utf8" })
      .trim()
      .split(/\s+/)
      .filter(Boolean)
      .map(Number)
  } catch (error) {
    if (error?.status === 1) return
    throw error
  }

  for (const processID of processIDs) {
    let command
    try {
      command = execFileSync("/bin/ps", ["-p", String(processID), "-o", "command="], {
        encoding: "utf8"
      }).trim()
    } catch (error) {
      if (error?.status === 1) continue
      throw error
    }
    if (command !== executable) continue
    try {
      process.kill(processID, "SIGTERM")
    } catch (error) {
      if (error?.code !== "ESRCH") throw error
    }
  }
}

function escapeRegularExpression(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

async function resolveDevelopmentSigningArguments() {
  const identities = await capture("security", ["find-identity", "-v", "-p", "codesigning"])
  const match = identities.match(/[0-9]+\)\s+([0-9A-F]+)\s+"(Apple Development:[^"]+)"/)
  if (match === null) {
    console.warn(
      "\nNo Apple Development signing identity was found. This build will be ad-hoc signed, so macOS may require Accessibility permission again after a rebuild."
    )
    return []
  }
  const [, hash, identity] = match
  const certificate = await capture("security", ["find-certificate", "-c", identity, "-p"])
  const team = new X509Certificate(certificate).toLegacyObject().subject.OU
  if (typeof team !== "string" || team.length === 0) {
    console.warn(
      `\nThe ${identity} certificate has no signing team identifier. This build will be ad-hoc signed, so macOS may require Accessibility permission again after a rebuild.`
    )
    return []
  }
  console.log(`Using stable development signing identity ${hash} (${team})`)
  return [
    `CODE_SIGN_IDENTITY=${hash}`,
    `DEVELOPMENT_TEAM=${team}`,
    "CODE_SIGN_STYLE=Manual",
    "PROVISIONING_PROFILE_SPECIFIER="
  ]
}
