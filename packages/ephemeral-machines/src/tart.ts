import { Effect, Schema } from "effect"

import {
  EphemeralProviderError,
  type CreateSpec,
  type OutputStream,
  type ProvisionProgress,
  type EphemeralProvider,
  type EphemeralTags,
  type ExecResult,
  type ListedMachine,
  type MachinePlatform,
  type ProviderMachineState
} from "./provider.js"

export const TartOptions = Schema.Struct({
  image: Schema.String.pipe(
    Schema.withDecodingDefaultKey(Effect.succeed("ghcr.io/cirruslabs/macos-sonoma-base:latest"))
  ),
  cpu: Schema.Number.pipe(Schema.withDecodingDefaultKey(Effect.succeed(4))),
  memoryGiB: Schema.Number.pipe(Schema.withDecodingDefaultKey(Effect.succeed(8))),
  minFreeDiskGiB: Schema.Number.pipe(Schema.withDecodingDefaultKey(Effect.succeed(40)))
})
export type TartOptions = typeof TartOptions.Type

export interface TartRunOptions {
  readonly stdin?: string
  readonly timeoutMs?: number
  readonly onOutput?: (stream: OutputStream, text: string) => void
}

export interface TartHost {
  readonly run: (args: ReadonlyArray<string>, options?: TartRunOptions) => Promise<ExecResult>
  readonly start: (args: ReadonlyArray<string>) => void
  readonly freeDiskBytes: () => Promise<number>
  readonly sleep: (ms: number) => Promise<void>
}

export const MAX_RUNNING_MACOS_VMS = 2

const vmPrefix = "codevisor_"
const bytesPerGiB = 1024 ** 3
const mebibytesPerGiB = 1024
const bootWaitSeconds = 180
const agentAttempts = 60
const agentRetryMs = 2000
const defaultExecTimeoutMs = 10 * 60 * 1000

const TartVm = Schema.Struct({ Name: Schema.String, State: Schema.String })
type TartVm = typeof TartVm.Type
const decodeTartVms = Schema.decodeUnknownSync(Schema.fromJsonString(Schema.Array(TartVm)))
const silentProgress: ProvisionProgress = { stage: () => undefined, log: () => undefined }

const decodeTartVmInfo = Schema.decodeUnknownSync(
  Schema.fromJsonString(Schema.Struct({ OS: Schema.optional(Schema.String) }))
)

export const makeTartProvider = (host: TartHost): EphemeralProvider<TartOptions> => {
  const tart = tartCommands(host)
  return {
    id: "tart",
    displayName: "Tart",
    options: TartOptions,
    provisionStages: ["create", "boot"],
    streamsOutput: true,
    create: async (spec, options, progress = silentProgress) => {
      await assertDiskRoom(host, options)
      const name = vmName(spec)
      progress.log(`tart clone ${options.image} ${name}`)
      await tart.must(["clone", options.image, name])
      try {
        return await bootClone(host, tart, name, options, progress)
      } catch (cause) {
        await tart.remove(name)
        throw cause
      }
    },
    exec: (name, request) =>
      host.run(["exec", "-i", name, "sh", "-c", request.script], {
        stdin: request.stdin ?? "",
        timeoutMs: request.timeoutMs ?? defaultExecTimeoutMs,
        ...(request.onOutput === undefined ? {} : { onOutput: request.onOutput })
      }),
    status: async (name) => ({
      state: stateFor((await tart.vms()).find((vm) => vm.Name === name))
    }),
    destroy: (name) => tart.remove(name),
    resume: (name) => boot(host, tart, name, silentProgress),
    list: async (owner) => (await tart.vms()).flatMap((vm) => ownedMachine(vm.Name, owner)),
    gui: async (name) => ({ vncUrl: `vnc://${await tart.ip(name)}:5900` })
  }
}

type TartCommands = ReturnType<typeof tartCommands>

const tartCommands = (host: TartHost) => {
  const must = async (args: ReadonlyArray<string>): Promise<string> => {
    const result = await host.run(args)
    if (result.exitCode !== 0) throw tartFailure(args, result)
    return result.stdout
  }
  return {
    must,
    vms: async (): Promise<ReadonlyArray<TartVm>> =>
      decodeTartVms(await must(["list", "--source", "local", "--format", "json"])),
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

const bootClone = async (
  host: TartHost,
  tart: TartCommands,
  name: string,
  options: TartOptions,
  progress: ProvisionProgress
): Promise<{ readonly providerMachineId: string; readonly platform: MachinePlatform }> => {
  const platform = await tart.platform(name)
  if (platform === "darwin") await assertMacOSSlot(tart)

  const settings = ["--cpu", String(options.cpu), "--memory", memoryMiB(options)]
  progress.log(`tart set ${name} ${settings.join(" ")}`)
  await tart.must(["set", name, ...settings])
  progress.stage("boot")
  await boot(host, tart, name, progress)
  return { providerMachineId: name, platform }
}

const boot = async (
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

const assertDiskRoom = async (host: TartHost, options: TartOptions): Promise<void> => {
  const freeGiB = (await host.freeDiskBytes()) / bytesPerGiB
  if (freeGiB >= options.minFreeDiskGiB) return

  throw new EphemeralProviderError(
    "tart",
    `Only ${freeGiB.toFixed(1)} GB of disk is free; Tart needs at least ${options.minFreeDiskGiB} GB to start a VM`
  )
}

const assertMacOSSlot = async (tart: TartCommands): Promise<void> => {
  const running = (await tart.vms()).filter((vm) => vm.State === "running")
  const macOS = await Promise.all(running.map((vm) => tart.platform(vm.Name)))
  if (macOS.filter((platform) => platform === "darwin").length < MAX_RUNNING_MACOS_VMS) return

  throw new EphemeralProviderError(
    "tart",
    `macOS allows only ${MAX_RUNNING_MACOS_VMS} macOS VMs running at once on this Mac; stop one first`
  )
}

const waitForGuestAgent = async (host: TartHost, name: string): Promise<void> => {
  for (let attempt = 1; attempt <= agentAttempts; attempt += 1) {
    if ((await host.run(["exec", name, "true"])).exitCode === 0) return
    await host.sleep(agentRetryMs)
  }
  throw new EphemeralProviderError("tart", `The Tart guest agent in ${name} never answered`)
}

export const vmName = (spec: CreateSpec): string =>
  `${vmPrefix}${spec.tags.owner}_${spec.tags.machine}`

const ownedMachine = (name: string, owner: string): ReadonlyArray<ListedMachine> => {
  const tags = tagsFromVmName(name)
  if (tags?.owner !== owner) return []

  return [{ providerMachineId: name, tags }]
}

const tagsFromVmName = (name: string): EphemeralTags | undefined => {
  if (!name.startsWith(vmPrefix)) return undefined
  const [owner, machine] = name.slice(vmPrefix.length).split("_")
  if (owner === undefined || machine === undefined) return undefined

  return { owner, machine }
}

const stateFor = (vm: TartVm | undefined): ProviderMachineState => {
  if (vm === undefined) return "gone"
  return vm.State === "running" ? "running" : "stopped"
}

const platformFor = (info: { readonly OS?: string | undefined }): MachinePlatform =>
  info.OS === "darwin" ? "darwin" : "linux"

const memoryMiB = (options: TartOptions): string => String(options.memoryGiB * mebibytesPerGiB)

const tartFailure = (args: ReadonlyArray<string>, result: ExecResult): EphemeralProviderError =>
  new EphemeralProviderError(
    "tart",
    `tart ${args.join(" ")} failed (exit ${result.exitCode}): ${result.stderr.trim()}`
  )
