import type { ContainerCommands, ContainerHost } from "./apple-container-host.js"
import { CONTAINER_PLATFORM } from "./apple-container-host.js"
import {
  CONTAINER_BASICS_SCRIPT,
  hasImage,
  isPreparedContainerImage
} from "./apple-container-image.js"
import {
  SandboxProviderError,
  type CreateSpec,
  type CreatedMachine,
  type ProvisionProgress
} from "./provider.js"
import { MACHINE_TAG, OWNER_TAG } from "./tags.js"

export interface StartOptions {
  readonly image?: string
  readonly baseImage: string
  readonly cpu: number
  readonly memoryGiB: number
}

export interface StartRequest {
  readonly spec: CreateSpec
  readonly options: StartOptions
  readonly progress: ProvisionProgress
}

export const CONTAINER_EXEC_TIMEOUT_MS = 10 * 60 * 1000

const containerNameLimit = 63
const namePrefix = "codevisor-"
const execAttempts = 30
const execRetryMs = 1000

export const containerName = (spec: CreateSpec): string =>
  `${namePrefix}${spec.tags.machine}`.slice(0, containerNameLimit)

export const startContainer = async (
  host: ContainerHost,
  commands: ContainerCommands,
  request: StartRequest
): Promise<CreatedMachine> => {
  const { spec, options, progress } = request
  const image = options.image ?? options.baseImage
  const preinstalled = isPreparedContainerImage(image)
  if (!preinstalled) await pullBase(commands, image, progress)

  const name = containerName(spec)
  progress.log(`container run ${name} from ${image}`)
  await commands.must(runArgs(spec, name, image, options))
  try {
    progress.stage("boot")
    await waitForExec(host, name)
    if (!preinstalled) await installBasics(host, name, progress)
    return { providerMachineId: name, platform: "linux", preinstalled }
  } catch (cause) {
    await commands.remove(name)
    throw cause
  }
}

const pullBase = async (
  commands: ContainerCommands,
  image: string,
  progress: ProvisionProgress
): Promise<void> => {
  if (hasImage(await commands.images(), image)) return

  progress.log(`container image pull --platform ${CONTAINER_PLATFORM} ${image}`)
  await commands.must(["image", "pull", "--platform", CONTAINER_PLATFORM, image], {
    onOutput: progress.output
  })
}

const runArgs = (
  spec: CreateSpec,
  name: string,
  image: string,
  options: StartOptions
): ReadonlyArray<string> => [
  "run",
  "--detach",
  "--init",
  "--platform",
  CONTAINER_PLATFORM,
  "--name",
  name,
  "--label",
  `${OWNER_TAG}=${spec.tags.owner}`,
  "--label",
  `${MACHINE_TAG}=${spec.tags.machine}`,
  "--cpus",
  String(options.cpu),
  "--memory",
  `${options.memoryGiB}g`,
  image,
  "sleep",
  "infinity"
]

const waitForExec = async (host: ContainerHost, name: string): Promise<void> => {
  for (let attempt = 1; attempt <= execAttempts; attempt += 1) {
    if ((await host.run(["exec", name, "true"])).exitCode === 0) return
    await host.sleep(execRetryMs)
  }
  throw new SandboxProviderError("apple-container", `The container ${name} never answered`)
}

const installBasics = async (
  host: ContainerHost,
  name: string,
  progress: ProvisionProgress
): Promise<void> => {
  progress.log("Installing curl and git")
  const result = await host.run(["exec", name, "sh", "-c", CONTAINER_BASICS_SCRIPT], {
    timeoutMs: CONTAINER_EXEC_TIMEOUT_MS,
    onOutput: progress.output
  })
  if (result.exitCode !== 0) {
    throw new SandboxProviderError(
      "apple-container",
      `Installing curl and git failed (exit ${result.exitCode})`
    )
  }
}
