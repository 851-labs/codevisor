import { execFile } from "node:child_process"
import { createHash } from "node:crypto"
import { readFile, rename, rm, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { basename, join } from "node:path"
import { promisify } from "node:util"

export interface OwnerIdentity {
  readonly pid: number
  readonly startedAt?: string
  readonly state?: string
}

export interface SimulatorManifest {
  readonly format?: string
  readonly repoRoot?: string
  readonly ready?: boolean
  readonly udid: string
  readonly name: string
  readonly runtime?: string
  readonly lease?: string
  readonly owner?: OwnerIdentity
}

export interface SimulatorOptions {
  device: string
  runtime: string | undefined
  help: boolean
}

export interface SimulatorDeviceType {
  readonly name: string
  readonly identifier: string
}

export interface SimulatorRuntime {
  readonly identifier: string
  readonly version: string
  readonly name: string
  readonly isAvailable: boolean
  readonly supportedDeviceTypes?: ReadonlyArray<{ readonly identifier: string }>
}

export type IdentityLookup = (pid: number) => Promise<OwnerIdentity | undefined | null>

export interface SimulatorDependencies {
  readonly identity: IdentityLookup
  readonly read?: (path: string) => Promise<unknown>
  readonly simctl?: (args: ReadonlyArray<string>) => Promise<string>
  readonly ownerPath?: (udid: string) => string
  readonly remove?: (path: string, options: { force: boolean }) => Promise<unknown>
}

interface ListedDevice {
  readonly udid: string
  readonly name: string
  readonly state: string
}

const exec = promisify(execFile)
const manifestFormat = "codevisor-ios-simulator-v1"
const simulatorHint =
  "This worktree's simulator must already be running. Start it in a separate background task with: bun run ios-simulator"

export const simulatorManifestPath = (repoRoot: string): string =>
  join(repoRoot, "tmp/runtime/ios-simulator.json")

export const simulatorName = (repoRoot: string): string =>
  `Codevisor Worktree ${basename(repoRoot)} (${createHash("sha256").update(repoRoot).digest("hex").slice(0, 10)})`

export const simulatorOwnerPath = (udid: string): string =>
  join(homedir(), "Library/Developer/CoreSimulator/Devices", udid, "codevisor-owner.json")

export async function readJSON(path: string): Promise<unknown> {
  try {
    return JSON.parse(await readFile(path, "utf8"))
  } catch (error) {
    if (
      (error instanceof Error && "code" in error && error.code === "ENOENT") ||
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

export async function simctl(
  args: ReadonlyArray<string>,
  options: { timeout?: number; signal?: AbortSignal } = {}
): Promise<string> {
  const { stdout } = await exec("xcrun", ["simctl", ...args], {
    maxBuffer: 8 * 1024 * 1024,
    timeout: 120_000,
    ...options
  })
  return stdout.trim()
}

export function parseSimulatorArguments(args: ReadonlyArray<string>): SimulatorOptions {
  const options: SimulatorOptions = { device: "iPhone 17 Pro", runtime: undefined, help: false }
  for (let index = 0; index < args.length; index += 1) {
    const argument = args[index] ?? ""
    if (argument === "--help" || argument === "-h") {
      options.help = true
      continue
    }
    const match = /^--(device|runtime)(?:=(.*))?$/.exec(argument)
    if (!match) throw new Error(`Unknown ios-simulator argument: ${argument}`)
    const value = match[2] ?? args[(index += 1)]
    if (!value || value.startsWith("--")) throw new Error(`${argument} requires a value`)
    if (match[1] === "device") options.device = value
    else options.runtime = value
  }
  return options
}

export function selectSimulatorConfiguration(
  options: SimulatorOptions,
  devices: ReadonlyArray<SimulatorDeviceType>,
  runtimes: ReadonlyArray<SimulatorRuntime>
): { deviceType: string; runtimeIdentifier: string; runtime: string } {
  const device = findSimulatorDevice(options, devices)
  const runtime = selectInstalledRuntime(options, device, runtimes)
  return {
    deviceType: device.identifier,
    runtimeIdentifier: runtime.identifier,
    runtime: `iOS ${runtime.version}`
  }
}

export async function simulatorOwnerAlive(
  manifest: unknown,
  identity: IdentityLookup
): Promise<boolean> {
  const owner = asManifest(manifest)?.owner
  if (
    asManifest(manifest)?.format !== manifestFormat ||
    owner === undefined ||
    !Number.isSafeInteger(owner.pid)
  )
    return false

  return isSameProcess(owner, await identity(owner.pid))
}

export async function requireIOSSimulator(
  repoRoot: string,
  dependencies: SimulatorDependencies
): Promise<SimulatorManifest> {
  const manifest = asManifest(
    await (dependencies.read ?? readJSON)(simulatorManifestPath(repoRoot))
  )
  if (
    manifest?.repoRoot !== repoRoot ||
    !manifest.ready ||
    !(await simulatorOwnerAlive(manifest, dependencies.identity))
  ) {
    throw new Error(simulatorHint)
  }
  const device = (await listDevices(dependencies)).find((entry) => entry.udid === manifest.udid)
  if (device?.state !== "Booted" || device.name !== manifest.name) throw new Error(simulatorHint)
  return manifest
}

export async function deleteOwnedSimulator(
  manifest: SimulatorManifest,
  dependencies: Omit<SimulatorDependencies, "identity"> = {}
): Promise<void> {
  const read = dependencies.read ?? readJSON
  const marker = asManifest(
    await read((dependencies.ownerPath ?? simulatorOwnerPath)(manifest.udid))
  )
  if (
    marker?.lease !== manifest.lease ||
    marker?.udid !== manifest.udid ||
    marker?.repoRoot !== manifest.repoRoot
  )
    return

  const control = dependencies.simctl ?? simctl
  const device = (await listDevices(dependencies)).find((entry) => entry.udid === manifest.udid)
  if (device && device.name !== manifest.name) return
  if (device) {
    if (device.state !== "Shutdown") await control(["shutdown", manifest.udid])
    await control(["delete", manifest.udid])
  }
  if (manifest.repoRoot === undefined) return

  const current = asManifest(await read(simulatorManifestPath(manifest.repoRoot)))
  if (current?.lease === manifest.lease)
    await (dependencies.remove ?? rm)(simulatorManifestPath(manifest.repoRoot), { force: true })
}

export async function reapOrphanedSimulators(dependencies: SimulatorDependencies): Promise<void> {
  const read = dependencies.read ?? readJSON
  const ownerPath = dependencies.ownerPath ?? simulatorOwnerPath
  for (const device of await listDevices(dependencies)) {
    if (!device.name.startsWith("Codevisor Worktree ")) continue

    const marker = asManifest(await read(ownerPath(device.udid)))
    if (
      marker?.format !== manifestFormat ||
      marker.udid !== device.udid ||
      marker.name !== device.name
    )
      continue
    if (await simulatorOwnerAlive(marker, dependencies.identity)) continue

    await deleteOwnedSimulator(marker, dependencies)
  }
}

function isSameProcess(expected: OwnerIdentity, actual: OwnerIdentity | undefined | null): boolean {
  if (actual === undefined || actual === null) return false

  return (
    expected.pid === actual.pid &&
    expected.startedAt === actual.startedAt &&
    !(actual.state ?? "").startsWith("Z")
  )
}

async function listDevices(
  dependencies: Pick<SimulatorDependencies, "simctl">
): Promise<Array<ListedDevice>> {
  const listing: unknown = JSON.parse(
    await (dependencies.simctl ?? simctl)(["list", "devices", "--json"])
  )
  const devices =
    isObject(listing) && isObject(listing.devices) ? Object.values(listing.devices) : []
  return devices.flat().filter(isListedDevice)
}

function asManifest(value: unknown): SimulatorManifest | undefined {
  return isManifest(value) ? value : undefined
}

function isManifest(value: unknown): value is SimulatorManifest {
  return isObject(value)
}

function isListedDevice(value: unknown): value is ListedDevice {
  return (
    isObject(value) &&
    typeof value.udid === "string" &&
    typeof value.name === "string" &&
    typeof value.state === "string"
  )
}

function isObject(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object"
}

function findSimulatorDevice(
  options: SimulatorOptions,
  devices: ReadonlyArray<SimulatorDeviceType>
): SimulatorDeviceType {
  const device = devices.find(
    (entry) => entry.name === options.device || entry.identifier === options.device
  )
  if (!device) {
    throw new Error(
      `Unknown simulator device: ${options.device}. Use an installed device type from xcrun simctl list devicetypes.`
    )
  }
  return device
}

function runtimeSupportsDevice(
  runtime: SimulatorRuntime,
  options: SimulatorOptions,
  device: SimulatorDeviceType
): boolean {
  if (!runtime.isAvailable || !runtime.identifier.includes(".iOS-")) return false
  if (
    options.runtime &&
    ![runtime.identifier, runtime.version, runtime.name].includes(options.runtime)
  )
    return false

  return (
    !runtime.supportedDeviceTypes ||
    runtime.supportedDeviceTypes.some((type) => type.identifier === device.identifier)
  )
}

function selectInstalledRuntime(
  options: SimulatorOptions,
  device: SimulatorDeviceType,
  runtimes: ReadonlyArray<SimulatorRuntime>
): SimulatorRuntime {
  const runtime = runtimes
    .filter((candidate) => runtimeSupportsDevice(candidate, options, device))
    .toSorted((a, b) => b.version.localeCompare(a.version, undefined, { numeric: true }))[0]
  if (!runtime) {
    const withRuntime = options.runtime ? ` with runtime ${options.runtime}` : ""
    throw new Error(
      `No installed iOS runtime supports ${options.device}${withRuntime}. Install it in Xcode first.`
    )
  }
  return runtime
}
