import { execFile } from "node:child_process"
import type { ExecFileOptionsWithStringEncoding } from "node:child_process"
import { createHash } from "node:crypto"
import { readFile, writeFile, rename, rm } from "node:fs/promises"
import { homedir } from "node:os"
import { join, basename } from "node:path"
import { promisify } from "node:util"

import { processIdentity, sameProcess } from "../packages/processes/src/index.mjs"
import type { ProcessIdentity } from "../packages/processes/src/index.mjs"

/// The claim a worktree writes for the simulator it owns, kept both in
/// tmp/runtime and beside the device itself.
export interface SimulatorManifest {
  format: string
  repoRoot: string
  name: string
  udid: string
  lease: string
  owner: ProcessIdentity
  ready: boolean
  deviceType?: string | undefined
  runtimeIdentifier?: string | undefined
  runtime?: string | undefined
}

/// One entry of `xcrun simctl list devices --json`.
export interface SimulatorDevice {
  udid: string
  name: string
  state: string
}

export interface SimulatorDeviceListing {
  devices: Record<string, SimulatorDevice[]>
}

/// One entry of `xcrun simctl list devicetypes --json`.
export interface SimulatorDeviceType {
  name: string
  identifier: string
}

/// One entry of `xcrun simctl list runtimes --json`.
export interface SimulatorRuntime {
  identifier: string
  version: string
  isAvailable: boolean
  name?: string | undefined
  supportedDeviceTypes?: readonly SimulatorDeviceType[] | undefined
}

/// The device and runtime a caller asked for; an unset runtime means "the
/// newest installed one that supports the device".
export interface SimulatorSelectionRequest {
  device: string
  runtime?: string | undefined
}

export interface SimulatorOptions extends SimulatorSelectionRequest {
  help: boolean
}

export interface SimulatorConfiguration {
  deviceType: string
  runtimeIdentifier: string
  runtime: string
}

export type SimulatorControl = (
  args: readonly string[],
  options?: ExecFileOptionsWithStringEncoding
) => Promise<string>

export type SimulatorStateReader = (path: string) => Promise<SimulatorManifest | undefined>

export type ProcessLookup = (pid: number) => Promise<ProcessIdentity | undefined>

export type SimulatorStateRemover = (path: string, options: { force: boolean }) => Promise<void>

/// Every collaborator the state helpers reach for, so tests can substitute
/// simctl, the manifest reader, and the process table wholesale.
export interface SimulatorDependencies {
  read?: SimulatorStateReader | undefined
  simctl?: SimulatorControl | undefined
  identity?: ProcessLookup | undefined
  ownerPath?: ((udid: string) => string) | undefined
  remove?: SimulatorStateRemover | undefined
}

const exec = promisify(execFile)
export const simulatorManifestPath = (repoRoot: string): string =>
  join(repoRoot, "tmp/runtime/ios-simulator.json")
export const simulatorName = (repoRoot: string): string =>
  `Codevisor Worktree ${basename(repoRoot)} (${createHash("sha256").update(repoRoot).digest("hex").slice(0, 10)})`
export const simulatorOwnerPath = (udid: string): string =>
  join(homedir(), "Library/Developer/CoreSimulator/Devices", udid, "codevisor-owner.json")

export async function readJSON<T>(path: string): Promise<T | undefined> {
  try {
    return JSON.parse(await readFile(path, "utf8"))
  } catch (error) {
    if (
      (error as NodeJS.ErrnoException | undefined)?.code === "ENOENT" ||
      error instanceof SyntaxError
    )
      return undefined
    throw error
  }
}

export async function writeJSON(path: string, value: unknown): Promise<void> {
  const temporary = `${path}.${process.pid}.tmp`
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`)
  await rename(temporary, path)
}

// Typed with the string-encoding options: execFile defaults to utf8, and
// that overload is what gives `stdout` a string type here.
export async function simctl(
  args: readonly string[],
  options: ExecFileOptionsWithStringEncoding = {}
): Promise<string> {
  const { stdout } = await exec("xcrun", ["simctl", ...args], {
    maxBuffer: 8 * 1024 * 1024,
    timeout: 120_000,
    ...options
  })
  return stdout.trim()
}

export function parseSimulatorArguments(args: readonly string[]): SimulatorOptions {
  const options: SimulatorOptions = { device: "iPhone 17 Pro", runtime: undefined, help: false }
  for (let i = 0; i < args.length; i++) {
    // Bounded by the loop condition, so the element is always present.
    const argument = args[i] as string
    if (argument === "--help" || argument === "-h") {
      options.help = true
      continue
    }
    const match = argument.match(/^--(device|runtime)(?:=(.*))?$/)
    if (!match) throw new Error(`Unknown ios-simulator argument: ${argument}`)
    const value = match[2] ?? args[++i]
    if (!value || value.startsWith("--")) throw new Error(`${argument} requires a value`)
    // The pattern's first group matched, and it is one of these two keys.
    options[match[1] as "device" | "runtime"] = value
  }
  return options
}

export function selectSimulatorConfiguration(
  options: SimulatorSelectionRequest,
  devices: readonly SimulatorDeviceType[],
  runtimes: readonly SimulatorRuntime[]
): SimulatorConfiguration {
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

export async function simulatorOwnerAlive(
  manifest: SimulatorManifest | undefined,
  identity: ProcessLookup = processIdentity
): Promise<boolean> {
  return (
    manifest?.format === "codevisor-ios-simulator-v1" &&
    Number.isSafeInteger(manifest.owner?.pid) &&
    sameProcess(manifest.owner, await identity(manifest.owner.pid))
  )
}

export async function requireIOSSimulator(
  repoRoot: string,
  dependencies: SimulatorDependencies = {}
): Promise<SimulatorManifest> {
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
  const listing: SimulatorDeviceListing = JSON.parse(await control(["list", "devices", "--json"]))
  const device = Object.values(listing.devices)
    .flat()
    .find((entry) => entry.udid === manifest.udid)
  if (device?.state !== "Booted" || device.name !== manifest.name) throw new Error(hint)
  return manifest
}

// Ownership survives deletion of the worktree: it is stored beside this device,
// never inferred from a friendly name or a recycled worktree name alone.
export async function deleteOwnedSimulator(
  manifest: SimulatorManifest,
  dependencies: SimulatorDependencies = {}
): Promise<void> {
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
  const listing: SimulatorDeviceListing = JSON.parse(await control(["list", "devices", "--json"]))
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

export async function reapOrphanedSimulators(
  dependencies: SimulatorDependencies = {}
): Promise<void> {
  const control = dependencies.simctl ?? simctl
  const read = dependencies.read ?? readJSON
  const ownerPath = dependencies.ownerPath ?? simulatorOwnerPath
  const identity = dependencies.identity ?? processIdentity
  const listing: SimulatorDeviceListing = JSON.parse(await control(["list", "devices", "--json"]))
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
