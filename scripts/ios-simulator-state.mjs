import { execFile } from "node:child_process"
import { createHash } from "node:crypto"
import { readFile, writeFile, rename, rm } from "node:fs/promises"
import { homedir } from "node:os"
import { join, basename } from "node:path"
import { promisify } from "node:util"

import { processIdentity, sameProcess } from "../packages/processes/src/index.mjs"

const exec = promisify(execFile)
export const simulatorManifestPath = (repoRoot) => join(repoRoot, "tmp/runtime/ios-simulator.json")
export const simulatorName = (repoRoot) =>
  `Codevisor Worktree ${basename(repoRoot)} (${createHash("sha256").update(repoRoot).digest("hex").slice(0, 10)})`
export const simulatorOwnerPath = (udid) =>
  join(homedir(), "Library/Developer/CoreSimulator/Devices", udid, "codevisor-owner.json")

export async function readJSON(path) {
  try {
    return JSON.parse(await readFile(path, "utf8"))
  } catch (error) {
    if (error.code === "ENOENT" || error instanceof SyntaxError) return undefined
    throw error
  }
}

export async function writeJSON(path, value) {
  const temporary = `${path}.${process.pid}.tmp`
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`)
  await rename(temporary, path)
}

export async function simctl(args, options = {}) {
  const { stdout } = await exec("xcrun", ["simctl", ...args], {
    maxBuffer: 8 * 1024 * 1024,
    timeout: 120_000,
    ...options
  })
  return stdout.trim()
}

export function parseSimulatorArguments(args) {
  const options = { device: "iPhone 17 Pro", runtime: undefined, help: false }
  for (let i = 0; i < args.length; i++) {
    const argument = args[i]
    if (argument === "--help" || argument === "-h") {
      options.help = true
      continue
    }
    const match = argument.match(/^--(device|runtime)(?:=(.*))?$/)
    if (!match) throw new Error(`Unknown ios-simulator argument: ${argument}`)
    const value = match[2] ?? args[++i]
    if (!value || value.startsWith("--")) throw new Error(`${argument} requires a value`)
    options[match[1]] = value
  }
  return options
}

export function selectSimulatorConfiguration(options, devices, runtimes) {
  const device = devices.find(
    (entry) => entry.name === options.device || entry.identifier === options.device
  )
  if (!device)
    throw new Error(
      `Unknown simulator device: ${options.device}. Use an installed device type from xcrun simctl list devicetypes.`
    )
  const candidates = runtimes.filter(
    (runtime) =>
      runtime.isAvailable &&
      runtime.identifier.includes(".iOS-") &&
      (!options.runtime ||
        [runtime.identifier, runtime.version, runtime.name].includes(options.runtime)) &&
      (!runtime.supportedDeviceTypes ||
        runtime.supportedDeviceTypes.some((type) => type.identifier === device.identifier))
  )
  candidates.sort((a, b) => b.version.localeCompare(a.version, undefined, { numeric: true }))
  const runtime = candidates[0]
  if (!runtime)
    throw new Error(
      `No installed iOS runtime supports ${options.device}${options.runtime ? ` with runtime ${options.runtime}` : ""}. Install it in Xcode first.`
    )
  return {
    deviceType: device.identifier,
    runtimeIdentifier: runtime.identifier,
    runtime: `iOS ${runtime.version}`
  }
}

export async function simulatorOwnerAlive(manifest, identity = processIdentity) {
  return (
    manifest?.format === "codevisor-ios-simulator-v1" &&
    Number.isSafeInteger(manifest.owner?.pid) &&
    sameProcess(manifest.owner, await identity(manifest.owner.pid))
  )
}

export async function requireIOSSimulator(repoRoot, dependencies = {}) {
  const read = dependencies.read ?? readJSON
  const control = dependencies.simctl ?? simctl
  const identity = dependencies.identity ?? processIdentity
  const manifest = await read(simulatorManifestPath(repoRoot))
  const hint =
    "This worktree's simulator must already be running. Start it in a separate background task with: bun run ios-simulator"
  if (
    manifest?.repoRoot !== repoRoot ||
    !manifest.ready ||
    !(await simulatorOwnerAlive(manifest, identity))
  )
    throw new Error(hint)
  const listing = JSON.parse(await control(["list", "devices", "--json"]))
  const device = Object.values(listing.devices)
    .flat()
    .find((entry) => entry.udid === manifest.udid)
  if (device?.state !== "Booted" || device.name !== manifest.name) throw new Error(hint)
  return manifest
}

// Ownership survives deletion of the worktree: it is stored beside this device,
// never inferred from a friendly name or a recycled worktree name alone.
export async function deleteOwnedSimulator(manifest, dependencies = {}) {
  const control = dependencies.simctl ?? simctl
  const read = dependencies.read ?? readJSON
  const markerPath = (dependencies.ownerPath ?? simulatorOwnerPath)(manifest.udid)
  const marker = await read(markerPath)
  if (
    marker?.lease !== manifest.lease ||
    marker?.udid !== manifest.udid ||
    marker?.repoRoot !== manifest.repoRoot
  )
    return
  const listing = JSON.parse(await control(["list", "devices", "--json"]))
  const device = Object.values(listing.devices)
    .flat()
    .find((entry) => entry.udid === manifest.udid)
  if (device && device.name !== manifest.name) return
  if (device) {
    if (device.state !== "Shutdown") await control(["shutdown", manifest.udid])
    await control(["delete", manifest.udid])
  }
  const current = await read(simulatorManifestPath(manifest.repoRoot))
  if (current?.lease === manifest.lease)
    await (dependencies.remove ?? rm)(simulatorManifestPath(manifest.repoRoot), { force: true })
}

export async function reapOrphanedSimulators(dependencies = {}) {
  const control = dependencies.simctl ?? simctl
  const read = dependencies.read ?? readJSON
  const ownerPath = dependencies.ownerPath ?? simulatorOwnerPath
  const identity = dependencies.identity ?? processIdentity
  const listing = JSON.parse(await control(["list", "devices", "--json"]))
  for (const device of Object.values(listing.devices).flat()) {
    if (!device.name.startsWith("Codevisor Worktree ")) continue
    const marker = await read(ownerPath(device.udid))
    if (
      marker?.format !== "codevisor-ios-simulator-v1" ||
      marker.udid !== device.udid ||
      marker.name !== device.name
    )
      continue
    if (await simulatorOwnerAlive(marker, identity)) continue
    await deleteOwnedSimulator(marker, dependencies)
  }
}
