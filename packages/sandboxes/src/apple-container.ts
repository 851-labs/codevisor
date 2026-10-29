import {
  memoryFull,
  memoryFullDetail,
  spareMemoryGiB,
  unavailableReason
} from "./apple-container-checks.js"
import {
  containerCommands,
  type ContainerCommands,
  type ContainerHost
} from "./apple-container-host.js"
import {
  ensureContainerImage,
  hasImage,
  isPreparedContainerImage,
  preparedContainerImage,
  type ContainerImages,
  type PreparedContainerImage
} from "./apple-container-image.js"
import { CONTAINER_EXEC_TIMEOUT_MS, startContainer } from "./apple-container-start.js"
import {
  machineField,
  numberField,
  numberValue,
  optionalString,
  textField,
  type SandboxFieldMaximums,
  type SandboxFieldValues
} from "./fields.js"
import {
  SandboxProviderError,
  type ProvisionPlan,
  type ProvisionProgress,
  type ProvisionStage,
  type SandboxAdapter,
  type SandboxProvider,
  type SandboxProviderDefinition
} from "./provider.js"
import { listedMachine, OWNER_TAG } from "./tags.js"
import { silentProgress } from "./tart-vm.js"

export {
  type ContainerCli,
  type ContainerHost,
  type ContainerHostHardware,
  type ContainerRunOptions
} from "./apple-container-host.js"
export { containerName } from "./apple-container-start.js"
export {
  CONTAINER_IMAGE_REPOSITORY,
  type ContainerImageRecipe,
  type ContainerImages
} from "./apple-container-image.js"

export const APPLE_CONTAINER_CAPABILITY = "apple-container"
export const DEFAULT_CONTAINER_IMAGE = "docker.io/library/debian:bookworm-slim"
export const CONTAINER_MIN_CPUS = 1
export const CONTAINER_MIN_MEMORY_GIB = 2

const maxCpus = 64
const maxMemoryGiB = 512
const defaultCpus = 2
const defaultMemoryGiB = 4
const hostCpuHeadroom = 2
const minFreeDiskGiB = 10
const preparedImageKey = "preparedImage"
const bootStages = ["create", "boot"] as const
const noImages: ContainerImages = { recipe: () => Promise.resolve(undefined) }

export const APPLE_CONTAINER_DEFINITION: SandboxProviderDefinition = {
  id: "apple-container",
  displayName: "Apple Containers",
  sandboxNoun: "Linux container",
  platform: "linux",
  tested: true,
  accountFields: [
    machineField("machineId", "Mac", APPLE_CONTAINER_CAPABILITY, {
      required: true,
      help: "The Apple silicon Mac on macOS 26 or later that runs this provider's containers."
    })
  ],
  profileFields: [
    textField("image", "Image", {
      default: DEFAULT_CONTAINER_IMAGE,
      help: "A Debian or Ubuntu image for linux/arm64. Codevisor builds its server into it on first use."
    }),
    numberField("cpu", "CPUs", {
      default: defaultCpus,
      min: CONTAINER_MIN_CPUS,
      max: maxCpus,
      steps: Array.from({ length: maxCpus }, (_, index) => index + 1),
      fallbackMax: 4
    }),
    numberField("memoryGiB", "Memory", {
      default: defaultMemoryGiB,
      min: CONTAINER_MIN_MEMORY_GIB,
      max: maxMemoryGiB,
      steps: [2, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 384, 512],
      fallbackMax: 8,
      unit: "GB"
    })
  ]
}

export interface ContainerOptions {
  readonly image?: string
  readonly baseImage: string
  readonly cpu: number
  readonly memoryGiB: number
  readonly minFreeDiskGiB: number
}

export const containerOptions = (values: SandboxFieldValues): ContainerOptions => {
  const image = optionalString(values, preparedImageKey)
  return {
    ...(image === undefined ? {} : { image }),
    baseImage: optionalString(values, "image") ?? DEFAULT_CONTAINER_IMAGE,
    cpu: numberValue(values, "cpu", defaultCpus),
    memoryGiB: numberValue(values, "memoryGiB", defaultMemoryGiB),
    minFreeDiskGiB: numberValue(values, "minFreeDiskGiB", minFreeDiskGiB)
  }
}

export const appleContainerAdapter = (
  host: ContainerHost,
  images: ContainerImages = noImages
): SandboxAdapter => ({
  definition: APPLE_CONTAINER_DEFINITION,
  connect: () => makeAppleContainerProvider(host, images),
  hostMaximums: () => containerHostMaximums(host)
})

export const containerHostMaximums = (host: ContainerHost): SandboxFieldMaximums => ({
  cpu: Math.max(CONTAINER_MIN_CPUS, host.hardware().cpus - hostCpuHeadroom),
  memoryGiB: Math.max(CONTAINER_MIN_MEMORY_GIB, spareMemoryGiB(host))
})

export const makeAppleContainerProvider = (
  host: ContainerHost,
  images: ContainerImages = noImages
): SandboxProvider => {
  const commands = containerCommands(host)
  const imageFor = async (options: ContainerOptions) => {
    if (options.image !== undefined) return undefined
    const recipe = await images.recipe()
    return recipe === undefined ? undefined : preparedContainerImage(options.baseImage, recipe)
  }
  const installed = async () => (await host.locate()) !== undefined
  return {
    definition: APPLE_CONTAINER_DEFINITION,
    provisionStages: bootStages,
    streamsOutput: true,
    availability: (values) => unavailableReason(host, containerOptions(values)),
    capacity: (values) => memoryFull(host, commands, containerOptions(values)),
    plan: async (values) => {
      const options = containerOptions(values)
      return planFor(commands, options, await imageFor(options), await installed())
    },
    prepare: async (values, plan, progress) => {
      await installContainer(host, plan, progress)
      await commands.ensureSystem(progress)
      const image = await imageFor(containerOptions(values))
      if (image === undefined) return values

      if (plan.stages.includes("image")) progress.stage("image")
      return withImage(values, await builtOrFallback(host, commands, image, progress))
    },
    create: async (spec, values, progress = silentProgress) => {
      const options = containerOptions(values)
      await assertCanStart(host, commands, options)
      return startContainer(host, commands, { spec, options, progress })
    },
    exec: async (name, request) =>
      host.run(["exec", "--interactive", name, "sh", "-c", request.script], {
        stdin: request.stdin ?? "",
        timeoutMs: request.timeoutMs ?? CONTAINER_EXEC_TIMEOUT_MS,
        ...(request.onOutput === undefined ? {} : { onOutput: request.onOutput })
      }),
    status: async (name) => {
      if (!(await installed())) return { state: "gone" }
      await commands.ensureSystem(silentProgress)
      const container = (await commands.containers()).find((each) => each.id === name)
      if (container === undefined) return { state: "gone" }
      return { state: container.state === "running" ? "running" : "stopped" }
    },
    destroy: async (name) => {
      if (await installed()) await commands.remove(name)
    },
    resume: async (name) => {
      await commands.ensureSystem(silentProgress)
      await commands.must(["start", name])
    },
    list: async (owner) => {
      if (!(await installed())) return []
      await commands.ensureSystem(silentProgress)
      return (await commands.containers())
        .filter((container) => container.labels[OWNER_TAG] === owner)
        .flatMap((container) => listedMachine(container.id, container.labels))
    }
  }
}

const planFor = async (
  commands: ContainerCommands,
  options: ContainerOptions,
  image: PreparedContainerImage | undefined,
  installed: boolean
): Promise<ProvisionPlan> => {
  const install: ReadonlyArray<ProvisionStage> = installed ? [] : ["container"]
  const preinstalled = image !== undefined || isPreparedContainerImage(options.image ?? "")
  if (image === undefined) return { stages: [...install, ...bootStages], preinstalled }

  const ready = installed && (await imageBuilt(commands, image))
  return { stages: [...install, ...(ready ? [] : ["image" as const]), ...bootStages], preinstalled }
}

const imageBuilt = async (
  commands: ContainerCommands,
  image: PreparedContainerImage
): Promise<boolean> =>
  (await commands.systemRunning()) && hasImage(await commands.images(), image.name)

const installContainer = async (
  host: ContainerHost,
  plan: ProvisionPlan,
  progress: ProvisionProgress
): Promise<void> => {
  if ((await host.locate()) !== undefined) return

  if (plan.stages.includes("container")) progress.stage("container")
  await host.install(progress.log)
}

const builtOrFallback = async (
  host: ContainerHost,
  commands: ContainerCommands,
  image: PreparedContainerImage,
  progress: ProvisionProgress
): Promise<string | undefined> => {
  try {
    await ensureContainerImage(host, commands, image, progress)
    return image.name
  } catch (cause) {
    progress.log(`${messageOf(cause)}\nInstalling Codevisor when the container starts instead`)
    return undefined
  }
}

const withImage = (values: SandboxFieldValues, image: string | undefined): SandboxFieldValues =>
  image === undefined ? values : { ...values, [preparedImageKey]: image }

const assertCanStart = async (
  host: ContainerHost,
  commands: ContainerCommands,
  options: ContainerOptions
): Promise<void> => {
  const reason =
    (await unavailableReason(host, options)) ?? (await memoryFullDetail(host, commands, options))
  if (reason !== undefined) throw new SandboxProviderError("apple-container", reason)
}

const messageOf = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)
