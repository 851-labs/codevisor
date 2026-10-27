import { Schema } from "effect"

import {
  SandboxProviderError,
  type ExecResult,
  type MachinePlatform,
  type OutputStream,
  type ProvisionProgress
} from "./provider.js"

export interface TartRunOptions {
  readonly stdin?: string
  readonly timeoutMs?: number
  readonly onOutput?: (stream: OutputStream, text: string) => void
}

export interface TartHost {
  readonly run: (args: ReadonlyArray<string>, options?: TartRunOptions) => Promise<ExecResult>
  readonly start: (args: ReadonlyArray<string>) => void
  readonly copyIn: (vm: string, source: string, destination: string) => Promise<ExecResult>
  readonly freeDiskBytes: () => Promise<number>
  readonly sleep: (ms: number) => Promise<void>
}

export interface TartSizing {
  readonly cpu: number
  readonly memoryGiB: number
  readonly minFreeDiskGiB: number
}

export const MAX_RUNNING_MACOS_VMS = 2

const bytesPerGiB = 1024 ** 3
const mebibytesPerGiB = 1024
const bootWaitSeconds = 180
const agentAttempts = 60
const agentRetryMs = 2000

const TartVm = Schema.Struct({ Name: Schema.String, State: Schema.String })
export type TartVm = typeof TartVm.Type
const decodeTartVms = Schema.decodeUnknownSync(Schema.fromJsonString(Schema.Array(TartVm)))

const decodeTartVmInfo = Schema.decodeUnknownSync(
  Schema.fromJsonString(Schema.Struct({ OS: Schema.optional(Schema.String) }))
)

const ignore = (): void => undefined

export const silentProgress: ProvisionProgress = { stage: ignore, log: ignore, output: ignore }

export type TartCommands = ReturnType<typeof tartCommands>

export const tartCommands = (host: TartHost) => {
  const must = async (args: ReadonlyArray<string>): Promise<string> => {
    const result = await host.run(args)
    if (result.exitCode !== 0) throw tartFailure(args, result)
    return result.stdout
  }
  const vms = async (): Promise<ReadonlyArray<TartVm>> =>
    decodeTartVms(await must(["list", "--source", "local", "--format", "json"]))
  return {
    must,
    vms,
    has: async (name: string): Promise<boolean> => (await vms()).some((vm) => vm.Name === name),
    platform: async (name: string): Promise<MachinePlatform> =>
      platformFor(decodeTartVmInfo(await must(["get", name, "--format", "json"]))),
    ip: async (name: string): Promise<string> =>
      (await must(["ip", name, "--wait", String(bootWaitSeconds)])).trim(),
    remove: async (name: string): Promise<void> => {
      await host.run(["stop", name])
      await host.run(["delete", name])
    }
  }
}

export const sizeVm = async (
  tart: TartCommands,
  name: string,
  sizing: TartSizing,
  progress: ProvisionProgress
): Promise<void> => {
  const settings = ["--cpu", String(sizing.cpu), "--memory", memoryMiB(sizing)]
  progress.log(`tart set ${name} ${settings.join(" ")}`)
  await tart.must(["set", name, ...settings])
}

export const boot = async (
  host: TartHost,
  tart: TartCommands,
  name: string,
  progress: ProvisionProgress
): Promise<void> => {
  progress.log(`tart run --no-graphics ${name}`)
  host.start(["run", "--no-graphics", name])
  progress.log("Waiting for an IP address")
  progress.log(`Got ${await tart.ip(name)}`)
  progress.log("Waiting for the guest agent")
  await waitForGuestAgent(host, name)
  progress.log("The guest agent is ready")
}

export const assertDiskRoom = async (host: TartHost, sizing: TartSizing): Promise<void> => {
  const shortfall = await diskShortfall(host, sizing)
  if (shortfall !== undefined) throw new SandboxProviderError("tart", shortfall)
}

export const assertMacOSSlot = async (tart: TartCommands): Promise<void> => {
  const full = await macOSSlotsFull(tart)
  if (full !== undefined) throw new SandboxProviderError("tart", full)
}

export const diskShortfall = async (
  host: TartHost,
  sizing: TartSizing
): Promise<string | undefined> => {
  const freeGiB = (await host.freeDiskBytes()) / bytesPerGiB
  if (freeGiB >= sizing.minFreeDiskGiB) return undefined

  return `Only ${freeGiB.toFixed(1)} GB of disk is free on this Mac; a Tart VM needs ${sizing.minFreeDiskGiB} GB`
}

export const macOSSlotsFull = async (tart: TartCommands): Promise<string | undefined> => {
  const running = (await tart.vms()).filter((vm) => vm.State === "running")
  const platforms = await Promise.all(running.map((vm) => tart.platform(vm.Name)))
  if (platforms.filter((platform) => platform === "darwin").length < MAX_RUNNING_MACOS_VMS) {
    return undefined
  }
  return `The limit of ${MAX_RUNNING_MACOS_VMS} macOS VMs per Mac has been reached`
}

const waitForGuestAgent = async (host: TartHost, name: string): Promise<void> => {
  for (let attempt = 1; attempt <= agentAttempts; attempt += 1) {
    if ((await host.run(["exec", name, "true"])).exitCode === 0) return
    await host.sleep(agentRetryMs)
  }
  throw new SandboxProviderError("tart", `The Tart guest agent in ${name} never answered`)
}

const platformFor = (info: { readonly OS?: string | undefined }): MachinePlatform =>
  info.OS === "darwin" ? "darwin" : "linux"

const memoryMiB = (sizing: TartSizing): string => String(sizing.memoryGiB * mebibytesPerGiB)

const tartFailure = (args: ReadonlyArray<string>, result: ExecResult): SandboxProviderError =>
  new SandboxProviderError(
    "tart",
    `tart ${args.join(" ")} failed (exit ${result.exitCode}): ${result.stderr.trim()}`
  )
