import type { ContainerCommands, ContainerHost } from "./apple-container-host.js"
import { isSupportedContainer, SUPPORTED_CONTAINER } from "./apple-container-install.js"

export interface ContainerSizing {
  readonly memoryGiB: number
  readonly minFreeDiskGiB: number
}

export const MINIMUM_MACOS_MAJOR = 26
export const MEMORY_FULL_REASON = "This Mac doesn't have enough free memory right now"
export const HOST_MEMORY_HEADROOM_GIB = 4

const bytesPerGiB = 1024 ** 3

export const unavailableReason = async (
  host: ContainerHost,
  sizing: ContainerSizing
): Promise<string | undefined> =>
  (await oldMacOS(host)) ?? (await unsupportedCli(host)) ?? (await diskShortfall(host, sizing))

export const memoryFull = async (
  host: ContainerHost,
  commands: ContainerCommands,
  sizing: ContainerSizing
): Promise<string | undefined> =>
  (await memoryShortfall(host, commands, sizing)) === undefined ? undefined : MEMORY_FULL_REASON

export const memoryFullDetail = async (
  host: ContainerHost,
  commands: ContainerCommands,
  sizing: ContainerSizing
): Promise<string | undefined> => {
  const shortfall = await memoryShortfall(host, commands, sizing)
  if (shortfall === undefined) return undefined

  return `${MEMORY_FULL_REASON}: running containers already reserve ${shortfall.reservedGiB} of the ${shortfall.spareGiB} GB it can spare, and this profile needs ${shortfall.neededGiB} GB`
}

export const spareMemoryGiB = (host: ContainerHost): number =>
  wholeGiB(host.hardware().memoryBytes) - HOST_MEMORY_HEADROOM_GIB

interface MemoryShortfall {
  readonly reservedGiB: number
  readonly spareGiB: number
  readonly neededGiB: number
}

const memoryShortfall = async (
  host: ContainerHost,
  commands: ContainerCommands,
  sizing: ContainerSizing
): Promise<MemoryShortfall | undefined> => {
  if (!(await systemUp(host, commands))) return undefined

  const reservedGiB = wholeGiB(sum((await commands.running()).map((each) => each.memoryBytes)))
  const spareGiB = spareMemoryGiB(host)
  if (reservedGiB + sizing.memoryGiB <= spareGiB) return undefined

  return { reservedGiB, spareGiB, neededGiB: sizing.memoryGiB }
}

const oldMacOS = async (host: ContainerHost): Promise<string | undefined> => {
  const version = await host.macOSVersion()
  if (Number(version.split(".")[0]) >= MINIMUM_MACOS_MAJOR) return undefined

  return `Apple containers need macOS ${MINIMUM_MACOS_MAJOR} or later, and this Mac runs macOS ${version}`
}

const unsupportedCli = async (host: ContainerHost): Promise<string | undefined> => {
  const cli = await host.locate()
  if (cli === undefined || isSupportedContainer(cli.version)) return undefined

  return `This Mac has container ${cli.version} at ${cli.binary}, and Codevisor needs ${SUPPORTED_CONTAINER.major}.${SUPPORTED_CONTAINER.minimumMinor} or a later ${SUPPORTED_CONTAINER.major}.x release. Update it from github.com/apple/container`
}

const diskShortfall = async (
  host: ContainerHost,
  sizing: ContainerSizing
): Promise<string | undefined> => {
  const freeGiB = (await host.freeDiskBytes()) / bytesPerGiB
  if (freeGiB >= sizing.minFreeDiskGiB) return undefined

  return `Only ${freeGiB.toFixed(1)} GB of disk is free on this Mac; a container sandbox needs ${sizing.minFreeDiskGiB} GB`
}

const systemUp = async (host: ContainerHost, commands: ContainerCommands): Promise<boolean> =>
  (await host.locate()) !== undefined && (await commands.systemRunning())

const sum = (values: ReadonlyArray<number>): number =>
  values.reduce((total, value) => total + value, 0)

const wholeGiB = (bytes: number): number => Math.round(bytes / bytesPerGiB)
