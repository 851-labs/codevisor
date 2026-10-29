import { createHash } from "node:crypto"

import {
  CONTAINER_PLATFORM,
  type ContainerCommands,
  type ContainerHost
} from "./apple-container-host.js"
import { DEFAULT_INSTALL_URL, environmentAssignments, shellQuote } from "./bootstrap.js"
import { SandboxProviderError, type ExecResult, type ProvisionProgress } from "./provider.js"

export const CONTAINER_IMAGE_REPOSITORY = "codevisor-sandbox"

export interface ContainerImageRecipe {
  readonly fingerprint: string
  readonly installUrl?: string
  readonly installEnvironment?: Readonly<Record<string, string>>
}

export interface ContainerImages {
  readonly recipe: () => Promise<ContainerImageRecipe | undefined>
}

export interface PreparedContainerImage {
  readonly name: string
  readonly baseImage: string
  readonly containerfile: string
}

export const CONTAINER_BASICS_SCRIPT = [
  "if command -v apt-get >/dev/null 2>&1; then",
  "apt-get update -qq &&",
  "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends ca-certificates curl git procps >/dev/null &&",
  "rm -rf /var/lib/apt/lists/*;",
  "elif command -v dnf >/dev/null 2>&1; then",
  "dnf install -y -q ca-certificates curl git procps-ng shadow-utils util-linux;",
  "fi"
].join(" ")

const buildTimeoutMs = 30 * 60 * 1000
const outputTailLines = 30
const builderId = "buildkit"
const builds = new Map<string, Promise<void>>()

export const preparedContainerImage = (
  baseImage: string,
  recipe: ContainerImageRecipe
): PreparedContainerImage => {
  const containerfile = containerfileFor(baseImage, recipe)
  const tag = shortHash([containerfile, recipe.fingerprint])
  return { name: `${CONTAINER_IMAGE_REPOSITORY}:${tag}`, baseImage, containerfile }
}

export const isPreparedContainerImage = (image: string): boolean =>
  localName(image).startsWith(`${CONTAINER_IMAGE_REPOSITORY}:`)

export const hasImage = (images: ReadonlyArray<string>, image: string): boolean =>
  images.some((each) => localName(each) === localName(image))

export const ensureContainerImage = (
  host: ContainerHost,
  commands: ContainerCommands,
  image: PreparedContainerImage,
  progress: ProvisionProgress
): Promise<void> =>
  once(image.name, progress, async () => {
    const before = await commands.images()
    if (hasImage(before, image.name)) {
      progress.log(`${image.name} is already built`)
      return
    }

    await withBuilder(commands, progress, () => build(host, image, progress))
    await removeLeftovers(commands, image, before, progress)
  })

const once = (
  key: string,
  progress: ProvisionProgress,
  work: () => Promise<void>
): Promise<void> => {
  const pending = builds.get(key)
  if (pending !== undefined) {
    progress.log("Waiting for another sandbox that's building this image")
    return pending
  }

  const started = work().finally(() => builds.delete(key))
  builds.set(key, started)
  return started
}

const withBuilder = async (
  commands: ContainerCommands,
  progress: ProvisionProgress,
  work: () => Promise<void>
): Promise<void> => {
  const builderWasRunning = (await commands.running()).some(({ id }) => id === builderId)
  try {
    await work()
  } finally {
    if (!builderWasRunning) await stopBuilder(commands, progress)
  }
}

const stopBuilder = async (
  commands: ContainerCommands,
  progress: ProvisionProgress
): Promise<void> => {
  progress.log("container builder delete --force")
  await commands.must(["builder", "delete", "--force"]).catch(() => undefined)
}

const build = async (
  host: ContainerHost,
  image: PreparedContainerImage,
  progress: ProvisionProgress
): Promise<void> => {
  const context = await host.buildContext(image.containerfile)
  try {
    progress.log(`container build --platform ${CONTAINER_PLATFORM} -t ${image.name}`)
    const result = await host.run(buildArgs(image, context), {
      timeoutMs: buildTimeoutMs,
      onOutput: progress.output
    })
    if (result.exitCode !== 0) throw buildFailure(result)
  } finally {
    await context.dispose()
  }
}

const buildArgs = (
  image: PreparedContainerImage,
  context: { readonly file: string; readonly directory: string }
): ReadonlyArray<string> => [
  "build",
  "--platform",
  CONTAINER_PLATFORM,
  "--progress",
  "plain",
  "--no-cache",
  "-t",
  image.name,
  "-f",
  context.file,
  context.directory
]

const removeLeftovers = async (
  commands: ContainerCommands,
  image: PreparedContainerImage,
  before: ReadonlyArray<string>,
  progress: ProvisionProgress
): Promise<void> => {
  const older = before.filter((name) => isPreparedContainerImage(name))
  const pulledForBuild = hasImage(before, image.baseImage) ? [] : [image.baseImage]
  for (const name of [...older, ...pulledForBuild]) {
    progress.log(`Deleting the image ${name}`)
    await commands.must(["image", "delete", name]).catch(() => undefined)
  }
}

const containerfileFor = (baseImage: string, recipe: ContainerImageRecipe): string =>
  [
    `FROM --platform=${CONTAINER_PLATFORM} ${baseImage}`,
    `RUN ${CONTAINER_BASICS_SCRIPT}`,
    `RUN ${installCommand(recipe)}`,
    ""
  ].join("\n")

const installCommand = (recipe: ContainerImageRecipe): string =>
  [
    "CODEVISOR_NO_SETUP=1 CODEVISOR_NO_SERVICE=1 CODEVISOR_INSTALL_SERVER=1",
    `${environmentAssignments(recipe.installEnvironment)}sh -c`,
    shellQuote(installScript(recipe.installUrl ?? DEFAULT_INSTALL_URL))
  ].join(" ")

const installScript = (installUrl: string): string =>
  `installer=$(mktemp) && curl -fsSL ${shellQuote(installUrl)} -o "$installer" && sh "$installer" && rm -f "$installer"`

const localName = (image: string): string => image.replace(/^docker\.io\/library\//, "")

const shortHash = (parts: ReadonlyArray<string>): string =>
  createHash("sha256").update(parts.join("\n")).digest("hex").slice(0, 16)

const buildFailure = (result: ExecResult): SandboxProviderError =>
  new SandboxProviderError(
    "apple-container",
    `Building the Codevisor container image failed (exit ${result.exitCode}):\n${outputTail(result)}`
  )

const outputTail = (result: ExecResult): string =>
  `${result.stdout}${result.stderr}`.trimEnd().split("\n").slice(-outputTailLines).join("\n")
