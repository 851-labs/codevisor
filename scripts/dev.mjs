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
const derivedDataPath = join(repoRoot, "DerivedData")
const dataDirectory =
  process.env.CODEVISOR_DEV_DATA_DIR ??
  process.env.HERDMAN_DEV_DATA_DIR ??
  join(homedir(), "Library", "Application Support", "Codevisor Development", instanceName)
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

await mkdir(dataDirectory, { recursive: true })
await mkdir(worktreesDirectory, { recursive: true })

console.log(`Codevisor development instance: ${worktreeName}`)
console.log(`  app:      ${appName}`)
console.log(`  server:   http://127.0.0.1:${port}`)
console.log(`  www:      http://localhost:${wwwPort}`)
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

const sharedEnvironment = {
  ...process.env,
  CODEVISOR_DEV_WORKTREE: worktreeName,
  CODEVISOR_DEV_INSTANCE_ID: instanceName,
  CODEVISOR_DEV_ICON_COLOR: developmentIconColor.hex,
  CODEVISOR_DEV_PORT: String(port),
  CODEVISOR_DEV_WWW_PORT: String(wwwPort),
  CODEVISOR_DEV_DATA_DIR: dataDirectory,
  CODEVISOR_WORKTREES_ROOT: worktreesDirectory
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

let app
let stopping = false

const stop = async (exitCode = 0) => {
  if (stopping) return
  stopping = true
  app?.kill("SIGTERM")
  www.kill("SIGTERM")

  try {
    await fetch(`http://127.0.0.1:${port}/v1/shutdown`, { method: "POST" })
  } catch {
    server.kill("SIGTERM")
  }

  await Promise.race([waitForExit(server), delay(2_000)])
  if (server.exitCode === null) server.kill("SIGTERM")
  process.exitCode = exitCode
}

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => void stop(0))
}

const serverExit = waitForExit(server).then(async (result) => {
  if (!stopping) {
    console.error(`Codevisor server exited unexpectedly (${describeExit(result)}).`)
    await stop(result.code ?? 1)
  }
})

void waitForExit(www).then((result) => {
  if (!stopping) {
    console.error(`www dev server exited unexpectedly (${describeExit(result)}).`)
  }
})

try {
  await waitForHealth(port, server)
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
