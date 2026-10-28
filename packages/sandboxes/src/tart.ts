import {
  machineField,
  numberField,
  numberValue,
  optionalString,
  textField,
  type SandboxFieldValues
} from "./fields.js"
import type {
  CreateSpec,
  SandboxAdapter,
  SandboxProvider,
  SandboxProviderDefinition,
  SandboxTags,
  ListedMachine,
  MachinePlatform,
  ProviderMachineState,
  ProvisionPlan,
  ProvisionProgress,
  ProvisionStage
} from "./provider.js"
import {
  ensureImage,
  isPreparedImage,
  preparedImage,
  type PreparedImage,
  type TartImages
} from "./tart-image.js"
import { ensurePulled } from "./tart-pull.js"
import {
  assertMacOSSlot,
  boot,
  diskShortfall,
  macOSSlotsFull,
  silentProgress,
  sizeVm,
  tartCommands,
  type TartCommands,
  type TartHost,
  type TartVm
} from "./tart-vm.js"

export { MAX_RUNNING_MACOS_VMS, type TartHost, type TartRunOptions } from "./tart-vm.js"
export { IMAGE_PREFIX, TOOLS_PREFIX, type TartImageRecipe, type TartImages } from "./tart-image.js"

export const DEFAULT_TART_BASE_IMAGE = "ghcr.io/cirruslabs/macos-tahoe-base:latest"

export const TART_CAPABILITY = "tart"

export const TART_DEFINITION: SandboxProviderDefinition = {
  id: "tart",
  displayName: "Tart",
  sandboxNoun: "Tart VM",
  platform: "darwin",
  tested: true,
  accountFields: [
    machineField("machineId", "Mac", TART_CAPABILITY, {
      required: true,
      help: "The Apple silicon Mac that runs this provider's VMs."
    })
  ],
  profileFields: [
    textField("image", "Image", {
      default: DEFAULT_TART_BASE_IMAGE,
      help: "A Tart image. macOS images get Codevisor and its permissions built in on first use."
    }),
    numberField("cpu", "CPUs", { default: 4, min: 1, max: 32 }),
    numberField("memoryGiB", "Memory (GiB)", { default: 8, min: 2, max: 128 })
  ]
}

export interface TartOptions {
  readonly image?: string
  readonly baseImage: string
  readonly cpu: number
  readonly memoryGiB: number
  readonly minFreeDiskGiB: number
}

export const tartOptions = (values: SandboxFieldValues): TartOptions => {
  const image = optionalString(values, PREPARED_IMAGE_KEY)
  return {
    ...(image === undefined ? {} : { image }),
    baseImage: optionalString(values, "image") ?? DEFAULT_TART_BASE_IMAGE,
    cpu: numberValue(values, "cpu", 4),
    memoryGiB: numberValue(values, "memoryGiB", 8),
    minFreeDiskGiB: numberValue(values, "minFreeDiskGiB", 40)
  }
}

export const tartAdapter = (host: TartHost, images: TartImages = noImages): SandboxAdapter => ({
  definition: TART_DEFINITION,
  connect: () => makeTartProvider(host, images)
})

const PREPARED_IMAGE_KEY = "preparedImage"

const vmPrefix = "codevisor_"
const defaultExecTimeoutMs = 10 * 60 * 1000
const bootStages = ["create", "boot"] as const

const noImages: TartImages = { recipe: () => Promise.resolve(undefined) }

export const makeTartProvider = (
  host: TartHost,
  images: TartImages = noImages
): SandboxProvider => {
  const tart = tartCommands(host)
  const imageFor = async (options: TartOptions): Promise<PreparedImage | undefined> => {
    if (options.image !== undefined || !/macos/i.test(options.baseImage)) return undefined
    const recipe = await images.recipe()
    return recipe === undefined ? undefined : preparedImage(options.baseImage, recipe)
  }
  return {
    definition: TART_DEFINITION,
    provisionStages: bootStages,
    streamsOutput: true,
    availability: async (values) => {
      const options = tartOptions(values)
      if (looksLikeMacOS(options) && (await host.installed())) {
        const full = await macOSSlotsFull(tart)
        if (full !== undefined) return full
      }
      return diskShortfall(host, options)
    },
    plan: async (values) => {
      const options = tartOptions(values)
      return planFor(tart, options, await imageFor(options), await host.installed())
    },
    prepare: async (values, plan, progress) => {
      await installTart(host, plan, progress)
      const options = tartOptions(values)
      const image = await imageFor(options)
      if (image === undefined) return withPreparedImage(values, options.image ?? options.baseImage)

      if (plan.stages.includes("image")) progress.stage("image")
      await ensureImage(host, tart, image, options, progress)
      return withPreparedImage(values, image.name)
    },
    create: async (spec, values, progress = silentProgress) => {
      const options = tartOptions(values)
      const image = options.image ?? options.baseImage
      await ensurePulled(host, tart, image, options, progress)
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
    list: async (owner) => {
      if (!(await host.installed())) return []
      return (await tart.vms()).flatMap((vm) => ownedMachine(vm.Name, owner))
    },
    gui: async (name) => ({ vncUrl: `vnc://${await tart.ip(name)}:5900` })
  }
}

const withPreparedImage = (values: SandboxFieldValues, image: string): SandboxFieldValues => ({
  ...values,
  [PREPARED_IMAGE_KEY]: image
})

const looksLikeMacOS = (options: TartOptions): boolean =>
  /macos/i.test(options.baseImage) || isPreparedImage(options.image ?? "")

const planFor = async (
  tart: TartCommands,
  options: TartOptions,
  image: PreparedImage | undefined,
  installed: boolean
): Promise<ProvisionPlan> => {
  const install: ReadonlyArray<ProvisionStage> = installed ? [] : ["tart"]
  if (image === undefined) {
    return {
      stages: [...install, ...bootStages],
      preinstalled: isPreparedImage(options.image ?? "")
    }
  }
  const imageReady = installed && (await tart.has(image.name))
  return {
    stages: [...install, ...(imageReady ? [] : ["image" as const]), ...bootStages],
    preinstalled: true
  }
}

const installTart = async (
  host: TartHost,
  plan: ProvisionPlan,
  progress: ProvisionProgress
): Promise<void> => {
  if (await host.installed()) return

  if (plan.stages.includes("tart")) progress.stage("tart")
  await host.install(progress.log)
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

const tagsFromVmName = (name: string): SandboxTags | undefined => {
  if (!name.startsWith(vmPrefix)) return undefined
  const [owner, machine] = name.slice(vmPrefix.length).split("_")
  if (owner === undefined || machine === undefined) return undefined

  return { owner, machine }
}

const stateFor = (vm: TartVm | undefined): ProviderMachineState => {
  if (vm === undefined) return "gone"
  return vm.State === "running" ? "running" : "stopped"
}
