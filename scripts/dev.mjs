import { createHash } from "node:crypto"
import { spawn } from "node:child_process"
import { access, cp, mkdir, readFile, realpath, rm, writeFile } from "node:fs/promises"
import { createServer } from "node:net"
import { homedir } from "node:os"
import { basename, join } from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"

const repoRoot = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const worktreeName = basename(repoRoot)
const instanceHash = createHash("sha256").update(repoRoot).digest("hex").slice(0, 10)
const worktreeHash = createHash("sha256").update(worktreeName).digest("hex")
const developmentIconColor = colorFromHash(worktreeHash)
const instanceName = `${worktreeName}-${instanceHash}`
const appName = `Codevisor (${worktreeName})`
// All build/server scratch is colocated under a single gitignored tmp/ dir so
// the worktree root stays tidy and everything is removed with the worktree.
const tmpRoot = join(repoRoot, "tmp")
const derivedDataPath = join(tmpRoot, "DerivedData")
// The local dev instance and a standalone "remote" server each get their own
// codevisor data dir — no cross-instance conflicts, and a realistic two-machine
// setup for testing remote flows and sync locally.
const dataDirectory =
  process.env.CODEVISOR_DEV_DATA_DIR ??
  process.env.HERDMAN_DEV_DATA_DIR ??
  join(tmpRoot, "codevisor")
const remoteDataDirectory = join(tmpRoot, "codevisor-remote")
const worktreesDirectory =
  process.env.CODEVISOR_WORKTREES_ROOT ??
  process.env.HERDMAN_WORKTREES_ROOT ??
  join(homedir(), "codevisor-development", instanceName)

const preferredPort = 51_000 + (Number.parseInt(instanceHash.slice(0, 8), 16) % 10_000)
const requestedPort = parsePort(
  process.env.CODEVISOR_DEV_PORT ?? process.env.HERDMAN_DEV_PORT,
  "CODEVISOR_DEV_PORT"
)
const port = requestedPort ?? (await findAvailablePort(preferredPort, 51_000, 10_000))

const preferredWwwPort = 61_000 + (Number.parseInt(instanceHash.slice(0, 8), 16) % 4_000)
const requestedWwwPort = parsePort(process.env.CODEVISOR_DEV_WWW_PORT, "CODEVISOR_DEV_WWW_PORT")
const wwwPort = requestedWwwPort ?? (await findAvailablePort(preferredWwwPort, 61_000, 4_000))

// The dev "remote" server: a real standalone server on this machine, isolated
// from the local instance, so remote-machine flows can be developed offline.
const remotePort = await findAvailablePort(port + 1, 51_000, 10_000)
const remoteName = `Dev Remote (${worktreeName})`

// One-time move of an earlier instance's state into the current data dir, so
// relocating (Application Support → .codevisor → tmp/codevisor) never drops
// the machines/projects you added. Checks each prior location in order.
if (dataDirectory === join(tmpRoot, "codevisor") && !(await pathExists(dataDirectory))) {
  for (const previous of [
    join(repoRoot, ".codevisor"),
    join(homedir(), "Library", "Application Support", "Codevisor Development", instanceName)
  ]) {
    if (await pathExists(previous)) {
      console.log(`Moving dev state into ${dataDirectory}`)
      await mkdir(tmpRoot, { recursive: true })
      await cp(previous, dataDirectory, { recursive: true })
      await rm(previous, { recursive: true, force: true })
      break
    }
  }
}

await mkdir(dataDirectory, { recursive: true })
await mkdir(remoteDataDirectory, { recursive: true })
await mkdir(worktreesDirectory, { recursive: true })

console.log(`Codevisor development instance: ${worktreeName}`)
console.log(`  app:      ${appName}`)
console.log(`  server:   http://127.0.0.1:${port}`)
console.log(`  www:      http://localhost:${wwwPort}`)
console.log(`  remote:   http://127.0.0.1:${remotePort}  (${remoteName})`)
console.log(`  data:     ${dataDirectory}`)
console.log(`  worktrees:${worktreesDirectory}`)
console.log(`  icon:     ${developmentIconColor.hex}`)

if (!(await pathExists(join(repoRoot, "node_modules", ".bin", "tsc")))) {
  await run("bun", ["install", "--frozen-lockfile"])
}
await ensureGhosttyFramework()
await run("bun", ["run", "--cwd", "apps/server", "build"])
const generatedIconDirectory = await createDevelopmentAppIcon()
try {
  await run("xcodebuild", [
    "-project",
    "apps/macos/Codevisor.xcodeproj",
    "-scheme",
    "Codevisor",
    "-configuration",
    "Debug",
    "-derivedDataPath",
    derivedDataPath,
    `CODEVISOR_DEV_PRODUCT_NAME=${appName}`,
    `CODEVISOR_DEV_DISPLAY_NAME=${appName}`,
    `CODEVISOR_DEV_BUNDLE_IDENTIFIER=com.851labs.Codevisor.Development.${instanceHash}`,
    "ASSETCATALOG_COMPILER_APPICON_NAME=AppIconDevGenerated",
    "INFOPLIST_KEY_CFBundleIconFile=AppIconDevGenerated",
    "INFOPLIST_KEY_CFBundleIconName=AppIconDevGenerated",
    "build"
  ])
} finally {
  await rm(generatedIconDirectory, { recursive: true, force: true })
}
const developmentBrowserIconDirectory = await createDevelopmentBrowserExtensionIcons()

const sharedEnvironment = {
  ...process.env,
  CODEVISOR_DEV_WORKTREE: worktreeName,
  CODEVISOR_DEV_INSTANCE_ID: instanceName,
  CODEVISOR_DEV_ICON_COLOR: developmentIconColor.hex,
  CODEVISOR_DEV_EXTENSION_ICON_DIR: developmentBrowserIconDirectory,
  CODEVISOR_DEV_PORT: String(port),
  CODEVISOR_DEV_WWW_PORT: String(wwwPort),
  CODEVISOR_DEV_DATA_DIR: dataDirectory,
  CODEVISOR_WORKTREES_ROOT: worktreesDirectory,
  // The dev remote's details, so the app can offer a one-click "add the test
  // remote" in Settings → Machines (the token is filled in once it's read).
  CODEVISOR_DEV_REMOTE_HOST: "127.0.0.1",
  CODEVISOR_DEV_REMOTE_PORT: String(remotePort),
  CODEVISOR_DEV_REMOTE_NAME: remoteName,
  CODEVISOR_DEV_REMOTE_TOKEN: ""
}
const databasePath = join(dataDirectory, "codevisor-server.sqlite")
const upgradeStatusPath = join(dataDirectory, "data-upgrade.json")
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
    appName,
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

// A standalone "remote" server on this machine, fully isolated from the local
// instance (its own data dir, worktrees, and managed repos) so remote-machine
// development mirrors talking to a real second machine.
const remoteServer = spawn(
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
      ...process.env,
      CODEVISOR_DEV_INSTANCE_ID: `${instanceName}-remote`,
      CODEVISOR_DATA_DIR: remoteDataDirectory,
      CODEVISOR_WORKTREES_ROOT: join(remoteDataDirectory, "worktrees"),
      CODEVISOR_REPOS_ROOT: join(remoteDataDirectory, "repos")
    },
    stdio: "inherit"
  }
)

let app
let stopping = false

const stop = async (exitCode = 0) => {
  if (stopping) return
  stopping = true
  app?.kill("SIGTERM")
  www.kill("SIGTERM")

  for (const [servicePort, child] of [
    [port, server],
    [remotePort, remoteServer]
  ]) {
    try {
      await fetch(`http://127.0.0.1:${servicePort}/v1/shutdown`, { method: "POST" })
    } catch {
      child.kill("SIGTERM")
    }
  }

  await Promise.race([Promise.all([waitForExit(server), waitForExit(remoteServer)]), delay(2_000)])
  for (const child of [server, remoteServer]) {
    if (child.exitCode === null) child.kill("SIGTERM")
  }
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
  watchServerExit(remoteServer, "Codevisor dev remote server")
])

void waitForExit(www).then((result) => {
  if (!stopping) {
    console.error(`www dev server exited unexpectedly (${describeExit(result)}).`)
  }
})

try {
  await waitForHealth(port, server)
  await waitForHealth(remotePort, remoteServer)
  await announceDevRemote()
  const executable = join(
    derivedDataPath,
    "Build",
    "Products",
    "Debug",
    `${appName}.app`,
    "Contents",
    "MacOS",
    appName
  )
  app = spawn(executable, [], { cwd: repoRoot, env: sharedEnvironment, stdio: "inherit" })
  const result = await waitForExit(app)
  if (!stopping) await stop(result.code ?? 0)
  await serverExit
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  await stop(1)
}

// Print the dev remote's connection details so it can be added in the app.
// Its token is stable, so this only needs to be done once per instance.
async function announceDevRemote() {
  let token = "(start the server to read it)"
  try {
    const response = await fetch(`http://127.0.0.1:${remotePort}/v1/auth/connection-token`)
    if (response.ok) token = (await response.json()).token
  } catch {
    // Non-fatal: the address alone is enough to add the machine.
  }
  // Hand the token to the app for the one-click "add test remote" action.
  sharedEnvironment.CODEVISOR_DEV_REMOTE_TOKEN = token
  const deeplink = `codevisor-dev://add-machine?host=127.0.0.1&port=${remotePort}&token=${token}&name=${encodeURIComponent(remoteName)}`
  console.log("")
  console.log(`Dev remote server ready — add it in ${appName}:`)
  console.log(`  Settings → Machines → Add Remote Machine`)
  console.log(`  Address: 127.0.0.1:${remotePort}`)
  console.log(`  Token:   ${token}`)
  console.log(`  Or open: ${deeplink}`)
  console.log("")
}

function parsePort(value, name) {
  if (value === undefined) return undefined
  const parsed = Number(value)
  if (!Number.isInteger(parsed) || parsed < 1_024 || parsed > 65_535) {
    throw new Error(`${name} must be an integer from 1024 through 65535; received ${value}`)
  }
  return parsed
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
  const iconsetDirectory = join(tmpRoot, "BrowserExtensionDev.iconset")
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

function run(command, arguments_) {
  console.log(`\n$ ${command} ${arguments_.join(" ")}`)
  const child = spawn(command, arguments_, { cwd: repoRoot, env: process.env, stdio: "inherit" })
  return waitForExit(child).then((result) => {
    if (result.code === 0) return
    throw new Error(`${command} failed (${describeExit(result)})`)
  })
}

async function ensureGhosttyFramework() {
  const relativeFramework = join("apps", "macos", "Frameworks", "GhosttyKit.xcframework")
  const destination = join(repoRoot, relativeFramework)
  if (await pathExists(destination)) return

  const worktreeList = await capture("git", ["worktree", "list", "--porcelain"])
  const otherWorktrees = worktreeList
    .split("\n")
    .filter((line) => line.startsWith("worktree "))
    .map((line) => line.slice("worktree ".length))
    .filter((path) => path !== repoRoot)

  for (const worktree of otherWorktrees) {
    const source = join(worktree, relativeFramework)
    if (!(await pathExists(source))) continue
    console.log(`\nCopying GhosttyKit.xcframework from ${worktree}`)
    await mkdir(join(repoRoot, "apps", "macos", "Frameworks"), { recursive: true })
    await cp(source, destination, { recursive: true })
    return
  }

  console.log(
    "\nNo existing worktree has GhosttyKit.xcframework; building it from the pinned submodule."
  )
  await run("git", ["submodule", "update", "--init", ".repos/ghostty"])
  await run(join(repoRoot, "apps/macos/scripts/build-ghostty.sh"), [])
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

async function pathExists(path) {
  try {
    await access(path)
    return true
  } catch {
    return false
  }
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
