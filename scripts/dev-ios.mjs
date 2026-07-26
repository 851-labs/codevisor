// iOS development loop: starts the standalone "Dev Remote" Codevisor server on
// this Mac (the same isolated instance scripts/dev.mjs runs alongside the macOS
// app), then builds and launches the iOS app in the visible Simulator. No macOS
// app is built or launched — the iOS app is a pure client of the dev remote.
import { createHash } from "node:crypto"
import { spawn } from "node:child_process"
import { access, mkdir, realpath } from "node:fs/promises"
import { createServer } from "node:net"
import { basename, join } from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"

const repoRoot = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const worktreeName = basename(repoRoot)
const instanceHash = createHash("sha256").update(repoRoot).digest("hex").slice(0, 10)
const instanceName = `${worktreeName}-${instanceHash}`
const tmpRoot = join(repoRoot, "tmp")
const derivedDataPath = join(tmpRoot, "DerivedData-iOS")
// Shared with scripts/dev.mjs's dev remote so the simulator talks to the same
// "Dev Remote" machine (same data, same stable token) either way.
const remoteDataDirectory = join(tmpRoot, "codevisor-remote")
const remoteName = `Dev Remote (${worktreeName})`
const bundleIdentifier = "com.dylanplayer.codevisor.ios"
const simulatorName = process.env.CODEVISOR_IOS_SIMULATOR ?? "iPhone 17 Pro"

const preferredPort = 51_000 + (Number.parseInt(instanceHash.slice(0, 8), 16) % 10_000)
const requestedPort = parsePort(process.env.CODEVISOR_DEV_REMOTE_PORT, "CODEVISOR_DEV_REMOTE_PORT")
const remotePort = requestedPort ?? (await findAvailablePort(preferredPort + 1, 51_000, 10_000))
const serverURL = `http://127.0.0.1:${remotePort}`

await mkdir(remoteDataDirectory, { recursive: true })

console.log(`Codevisor iOS development instance: ${worktreeName}`)
console.log(`  server:    ${serverURL}  (${remoteName})`)
console.log(`  data:      ${remoteDataDirectory}`)
console.log(`  simulator: ${simulatorName}`)

if (!(await pathExists(join(repoRoot, "node_modules", ".bin", "tsc")))) {
  await run("bun", ["install", "--frozen-lockfile"])
}
await run("bun", ["run", "--cwd", "apps/server", "build"])

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
      ...process.env,
      CODEVISOR_DEV_INSTANCE_ID: `${instanceName}-remote`,
      CODEVISOR_DATA_DIR: remoteDataDirectory,
      CODEVISOR_WORKTREES_ROOT: join(remoteDataDirectory, "worktrees"),
      CODEVISOR_REPOS_ROOT: join(remoteDataDirectory, "repos")
    },
    stdio: "inherit"
  }
)

let stopping = false
let simulatorUdid

const stop = async (exitCode = 0) => {
  if (stopping) return
  stopping = true
  if (simulatorUdid !== undefined) {
    spawn("xcrun", ["simctl", "terminate", simulatorUdid, bundleIdentifier], {
      stdio: "ignore"
    }).unref()
  }
  try {
    await fetch(`${serverURL}/v1/shutdown`, { method: "POST" })
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
    console.error(`Codevisor dev remote server exited unexpectedly (${describeExit(result)}).`)
    await stop(result.code ?? 1)
  }
})

try {
  const simulator = await selectSimulator(simulatorName)
  simulatorUdid = simulator.udid
  console.log(`  device:    ${simulator.name} (${simulator.runtime}) ${simulator.udid}`)

  await run("xcodebuild", [
    "-project",
    "apps/ios/Codevisor.xcodeproj",
    "-scheme",
    "Codevisor",
    "-configuration",
    "Debug",
    "-destination",
    `platform=iOS Simulator,id=${simulator.udid}`,
    "-derivedDataPath",
    derivedDataPath,
    "build"
  ])

  await waitForHealth(remotePort, server)
  const token = await readConnectionToken()

  // Boot (if needed), make the Simulator window visible, then install + launch
  // with the dev server's coordinates in the app's environment.
  await run("xcrun", ["simctl", "bootstatus", simulator.udid, "-b"])
  await openSimulatorUserInterface()
  const appBundle = join(
    derivedDataPath,
    "Build",
    "Products",
    "Debug-iphonesimulator",
    "Codevisor.app"
  )
  await run("xcrun", ["simctl", "install", simulator.udid, appBundle])
  spawn("xcrun", ["simctl", "terminate", simulator.udid, bundleIdentifier], { stdio: "ignore" })
  await delay(500)
  await runWithEnvironment("xcrun", ["simctl", "launch", simulator.udid, bundleIdentifier], {
    ...process.env,
    SIMCTL_CHILD_CODEVISOR_DEV_SERVER_URL: serverURL,
    SIMCTL_CHILD_CODEVISOR_DEV_SERVER_TOKEN: token,
    SIMCTL_CHILD_CODEVISOR_DEV_SERVER_NAME: remoteName
  })

  console.log("")
  console.log(`Codevisor iOS is running on ${simulator.name} against the dev remote:`)
  console.log(`  Address: 127.0.0.1:${remotePort}`)
  console.log(`  Token:   ${token}`)
  console.log(
    `  Or open: codevisor-dev://add-machine?host=127.0.0.1&port=${remotePort}&token=${token}&name=${encodeURIComponent(remoteName)}`
  )
  console.log("")
  console.log("Press Ctrl+C to stop the server (the simulator stays open).")

  await serverExit
} catch (error) {
  console.error(error instanceof Error ? error.message : error)
  await stop(1)
}

// Make the simulator window visible. The UI app ships inside the selected
// Xcode and is not reliably registered with LaunchServices by name: older
// Xcodes have Developer/Applications/Simulator.app, Xcode 27+ replaced it with
// Contents/Applications/DeviceHub.app.
async function openSimulatorUserInterface() {
  const developerDirectory = (await capture("xcode-select", ["-p"])).trim()
  const xcodeContents = join(developerDirectory, "..")
  const candidates = [
    join(developerDirectory, "Applications", "Simulator.app"),
    join(xcodeContents, "Applications", "DeviceHub.app")
  ]
  for (const candidate of candidates) {
    if (await pathExists(candidate)) {
      await run("open", [candidate])
      return
    }
  }
  console.warn(
    "No simulator UI app (Simulator.app or DeviceHub.app) was found in the selected Xcode; the app is running headless. Open the simulator UI manually to see it."
  )
}

async function selectSimulator(name) {
  const listing = JSON.parse(
    await capture("xcrun", ["simctl", "list", "devices", "available", "--json"])
  )
  const candidates = []
  for (const [runtimeIdentifier, devices] of Object.entries(listing.devices)) {
    const match = runtimeIdentifier.match(/iOS-(\d+)-(\d+)$/)
    if (match === null) continue
    const version = Number(match[1]) * 100 + Number(match[2])
    for (const device of devices) {
      if (device.name !== name) continue
      candidates.push({
        udid: device.udid,
        name: device.name,
        runtime: `iOS ${match[1]}.${match[2]}`,
        version,
        booted: device.state === "Booted"
      })
    }
  }
  if (candidates.length === 0) {
    throw new Error(
      `No available simulator named "${name}" was found. Set CODEVISOR_IOS_SIMULATOR to one of the devices in \`xcrun simctl list devices available\`.`
    )
  }
  // Prefer an already-booted device, then the newest runtime.
  candidates.sort((a, b) => Number(b.booted) - Number(a.booted) || b.version - a.version)
  return candidates[0]
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

function run(command, arguments_) {
  return runWithEnvironment(command, arguments_, process.env)
}

function runWithEnvironment(command, arguments_, environment) {
  console.log(`\n$ ${command} ${arguments_.join(" ")}`)
  const child = spawn(command, arguments_, { cwd: repoRoot, env: environment, stdio: "inherit" })
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
