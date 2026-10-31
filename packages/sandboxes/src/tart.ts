import {
  machineField,
  numberField,
  numberValue,
  optionalString,
  textField,
  type SandboxFieldMaximums,
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
  type TartHostHardware,
  type TartVm
} from "./tart-vm.js"

export {
  MAX_RUNNING_MACOS_VMS,
  type TartHost,
  type TartHostHardware,
  type TartRunOptions
} from "./tart-vm.js"
export { IMAGE_PREFIX, TOOLS_PREFIX, type TartImageRecipe, type TartImages } from "./tart-image.js"

export const DEFAULT_TART_BASE_IMAGE = "ghcr.io/cirruslabs/macos-tahoe-base:latest"

export const TART_CAPABILITY = "tart"

export const TART_MIN_CPUS = 2
export const TART_MIN_MEMORY_GIB = 4

const tartMaxCpus = 64
const tartMaxMemoryGiB = 512
const fallbackMaxCpus = 4
const fallbackMaxMemoryGiB = 8
const hostCpuHeadroom = 2
const hostMemoryHeadroomGiB = 4
const bytesPerGiB = 1024 ** 3
const cpuSteps = Array.from(
  { length: tartMaxCpus - TART_MIN_CPUS + 1 },
  (_, index) => TART_MIN_CPUS + index
)
const memoryStepsGiB = [4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512]

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
    numberField("cpu", "CPUs", {
      default: TART_MIN_CPUS,
      min: TART_MIN_CPUS,
      max: tartMaxCpus,
      steps: cpuSteps,
      fallbackMax: fallbackMaxCpus
    }),
    numberField("memoryGiB", "Memory", {
      default: TART_MIN_MEMORY_GIB,
      min: TART_MIN_MEMORY_GIB,
      max: tartMaxMemoryGiB,
      steps: memoryStepsGiB,
      fallbackMax: fallbackMaxMemoryGiB,
      unit: "GB"
    })
  ]
}

export const tartHostMaximums = (hardware: TartHostHardware): SandboxFieldMaximums => ({
  cpu: Math.max(TART_MIN_CPUS, hardware.cpus - hostCpuHeadroom),
  memoryGiB: Math.max(TART_MIN_MEMORY_GIB, wholeGiB(hardware.memoryBytes) - hostMemoryHeadroomGiB)
})

export interface TartOptions {
  readonly image?: string
  readonly baseImage: string
  readonly cpu: number
  readonly memoryGiB: number
  readonly minFreeDiskGiB: number
}

const tartOptions = (values: SandboxFieldValues): TartOptions => {
  const image = optionalString(values, PREPARED_IMAGE_KEY)
  return {
    ...(image === undefined ? {} : { image }),
    baseImage: optionalString(values, "image") ?? DEFAULT_TART_BASE_IMAGE,
    cpu: numberValue(values, "cpu", TART_MIN_CPUS),
    memoryGiB: numberValue(values, "memoryGiB", TART_MIN_MEMORY_GIB),
    minFreeDiskGiB: numberValue(values, "minFreeDiskGiB", 40)
  }
}

export const tartAdapter = (host: TartHost, images: TartImages = noImages): SandboxAdapter => ({
  definition: TART_DEFINITION,
  connect: () => makeTartProvider(host, images),
  hostMaximums: () => tartHostMaximums(host.hardware())
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
    availability: (values) => diskShortfall(host, tartOptions(values)),
    capacity: async (values) => {
      if (!looksLikeMacOS(tartOptions(values)) || !(await host.installed())) return undefined
      return macOSSlotsFull(tart)
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

const wholeGiB = (bytes: number): number => Math.round(bytes / bytesPerGiB)
