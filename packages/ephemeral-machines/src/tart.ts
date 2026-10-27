import { Effect, Schema } from "effect"

import type {
  CreateSpec,
  EphemeralProvider,
  EphemeralTags,
  ListedMachine,
  MachinePlatform,
  ProviderMachineState,
  ProvisionPlan,
  ProvisionProgress
} from "./provider.js"
import {
  ensureImage,
  isPreparedImage,
  preparedImage,
  type PreparedImage,
  type TartImages
} from "./tart-image.js"
import {
  assertDiskRoom,
  assertMacOSSlot,
  boot,
  silentProgress,
  sizeVm,
  tartCommands,
  type TartCommands,
  type TartHost,
  type TartVm
} from "./tart-vm.js"

export { MAX_RUNNING_MACOS_VMS, type TartHost, type TartRunOptions } from "./tart-vm.js"
export { IMAGE_PREFIX, type TartImageRecipe, type TartImages } from "./tart-image.js"

export const DEFAULT_TART_BASE_IMAGE = "ghcr.io/cirruslabs/macos-tahoe-base:latest"

export const TartOptions = Schema.Struct({
  image: Schema.optional(Schema.String),
  baseImage: Schema.String.pipe(
    Schema.withDecodingDefaultKey(Effect.succeed(DEFAULT_TART_BASE_IMAGE))
  ),
  cpu: Schema.Number.pipe(Schema.withDecodingDefaultKey(Effect.succeed(4))),
  memoryGiB: Schema.Number.pipe(Schema.withDecodingDefaultKey(Effect.succeed(8))),
  minFreeDiskGiB: Schema.Number.pipe(Schema.withDecodingDefaultKey(Effect.succeed(40)))
})
export type TartOptions = typeof TartOptions.Type

const vmPrefix = "codevisor_"
const defaultExecTimeoutMs = 10 * 60 * 1000
const bootStages = ["create", "boot"] as const

const noImages: TartImages = { recipe: () => Promise.resolve(undefined) }

export const makeTartProvider = (
  host: TartHost,
  images: TartImages = noImages
): EphemeralProvider<TartOptions> => {
  const tart = tartCommands(host)
  const imageFor = async (options: TartOptions): Promise<PreparedImage | undefined> => {
    if (options.image !== undefined) return undefined
    const recipe = await images.recipe()
    return recipe === undefined ? undefined : preparedImage(options.baseImage, recipe)
  }
  return {
    id: "tart",
    displayName: "Tart",
    options: TartOptions,
    provisionStages: bootStages,
    streamsOutput: true,
    plan: async (options) => planFor(tart, options, await imageFor(options)),
    prepare: async (options, plan, progress) => {
      const image = await imageFor(options)
      if (image === undefined) return { ...options, image: options.image ?? options.baseImage }

      if (plan.stages.includes("image")) progress.stage("image")
      await ensureImage(host, tart, image, options, progress)
      return { ...options, image: image.name }
    },
    create: async (spec, options, progress = silentProgress) => {
      await assertDiskRoom(host, options)
      const image = options.image ?? options.baseImage
      const name = vmName(spec)
      progress.log(`tart clone ${image} ${name}`)
      await tart.must(["clone", image, name])
      try {
        const platform = await bootClone(host, tart, name, options, progress)
        return { providerMachineId: name, platform, preinstalled: isPreparedImage(image) }
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

const planFor = async (
  tart: TartCommands,
  options: TartOptions,
  image: PreparedImage | undefined
): Promise<ProvisionPlan> => {
  if (image === undefined) {
    return { stages: bootStages, preinstalled: isPreparedImage(options.image ?? "") }
  }
  const stages = (await tart.has(image.name)) ? bootStages : ["image" as const, ...bootStages]
  return { stages, preinstalled: true }
}

const bootClone = async (
  host: TartHost,
  tart: TartCommands,
  name: string,
  options: TartOptions,
  progress: ProvisionProgress
): Promise<MachinePlatform> => {
  const platform = await tart.platform(name)
  if (platform === "darwin") await assertMacOSSlot(tart)

  await sizeVm(tart, name, options, progress)
  progress.stage("boot")
  await boot(host, tart, name, progress)
  return platform
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
