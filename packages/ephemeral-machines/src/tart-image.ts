import { createHash } from "node:crypto"
import { basename } from "node:path"

import { imageSetupScript, type ImageApp } from "./image-setup.js"
import { EphemeralProviderError, type ExecResult, type ProvisionProgress } from "./provider.js"
import {
  assertDiskRoom,
  assertMacOSSlot,
  boot,
  sizeVm,
  type TartCommands,
  type TartHost,
  type TartSizing
} from "./tart-vm.js"

export const IMAGE_PREFIX = "codevisor-image-"

export interface TartImageRecipe {
  readonly appPath: string
  readonly fingerprint: string
  readonly development?: ImageApp["development"]
  readonly installUrl?: string
  readonly installEnvironment?: Readonly<Record<string, string>>
  readonly agentCommands: ReadonlyArray<string>
}

export interface TartImages {
  readonly recipe: () => Promise<TartImageRecipe | undefined>
}

export interface PreparedImage {
  readonly name: string
  readonly baseImage: string
  readonly recipe: TartImageRecipe
}

const buildTimeoutMs = 45 * 60 * 1000
const outputTailLines = 30
const buildingSuffix = "-building"
const applicationsFolder = "/Applications"
const builds = new Map<string, Promise<void>>()

export const preparedImage = (baseImage: string, recipe: TartImageRecipe): PreparedImage => ({
  name: `${IMAGE_PREFIX}${imageHash(baseImage, recipe)}`,
  baseImage,
  recipe
})

export const isPreparedImage = (image: string): boolean => image.startsWith(IMAGE_PREFIX)

export const ensureImage = (
  host: TartHost,
  tart: TartCommands,
  image: PreparedImage,
  sizing: TartSizing,
  progress: ProvisionProgress
): Promise<void> => {
  const pending = builds.get(image.name)
  if (pending !== undefined) {
    progress.log("Waiting for the macOS image another machine is preparing")
    return pending
  }

  const work = buildIfMissing(host, tart, image, sizing, progress).finally(() =>
    builds.delete(image.name)
  )
  builds.set(image.name, work)
  return work
}

const buildIfMissing = async (
  host: TartHost,
  tart: TartCommands,
  image: PreparedImage,
  sizing: TartSizing,
  progress: ProvisionProgress
): Promise<void> => {
  if (await tart.has(image.name)) {
    progress.log(`${image.name} is already prepared`)
    return
  }
  await buildImage(host, tart, image, sizing, progress)
}

const buildImage = async (
  host: TartHost,
  tart: TartCommands,
  image: PreparedImage,
  sizing: TartSizing,
  progress: ProvisionProgress
): Promise<void> => {
  await assertDiskRoom(host, sizing)
  const vm = `${image.name}${buildingSuffix}`
  await tart.remove(vm)
  progress.log(`tart clone ${image.baseImage} ${vm}`)
  await tart.must(["clone", image.baseImage, vm])
  try {
    await installInto(host, tart, vm, image, sizing, progress)
  } catch (cause) {
    await tart.remove(vm)
    throw cause
  }
  await removeOtherImages(tart, image.name, progress)
}

const installInto = async (
  host: TartHost,
  tart: TartCommands,
  vm: string,
  image: PreparedImage,
  sizing: TartSizing,
  progress: ProvisionProgress
): Promise<void> => {
  await assertMacOSSlot(tart)
  await sizeVm(tart, vm, sizing, progress)
  await boot(host, tart, vm, progress)
  await copyApp(host, vm, image.recipe, progress)
  await runSetup(host, vm, image.recipe, progress)
  progress.log(`tart stop ${vm}`)
  await tart.must(["stop", vm])
  await tart.must(["rename", vm, image.name])
}

const copyApp = async (
  host: TartHost,
  vm: string,
  recipe: TartImageRecipe,
  progress: ProvisionProgress
): Promise<void> => {
  progress.log(`Copying ${basename(recipe.appPath)} into /Applications`)
  const result = await host.copyIn(vm, recipe.appPath, applicationsFolder)
  if (result.exitCode !== 0) throw imageFailure("Copying Codevisor into the macOS image", result)
}

const runSetup = async (
  host: TartHost,
  vm: string,
  recipe: TartImageRecipe,
  progress: ProvisionProgress
): Promise<void> => {
  const result = await host.run(["exec", "-i", vm, "sh", "-c", setupScript(recipe)], {
    timeoutMs: buildTimeoutMs,
    onOutput: progress.output
  })
  if (result.exitCode !== 0) throw imageFailure("Preparing the macOS image", result)
}

const removeOtherImages = async (
  tart: TartCommands,
  current: string,
  progress: ProvisionProgress
): Promise<void> => {
  const stale = (await tart.vms()).filter((vm) => isStaleImage(vm.Name, current))
  for (const vm of stale) {
    progress.log(`Deleting the older image ${vm.Name}`)
    await tart.remove(vm.Name)
  }
}

const isStaleImage = (name: string, current: string): boolean =>
  isPreparedImage(name) && name !== current && !name.endsWith(buildingSuffix)

const setupScript = (recipe: TartImageRecipe): string =>
  imageSetupScript({
    agentCommands: recipe.agentCommands,
    ...(recipe.installUrl === undefined ? {} : { installUrl: recipe.installUrl }),
    ...(recipe.installEnvironment === undefined
      ? {}
      : { installEnvironment: recipe.installEnvironment }),
    app: imageApp(recipe)
  })

const imageApp = ({ appPath, development }: TartImageRecipe): ImageApp => ({
  bundleName: basename(appPath),
  ...(development === undefined ? {} : { development })
})

const imageHash = (baseImage: string, recipe: TartImageRecipe): string =>
  createHash("sha256")
    .update(`${baseImage}\n${recipe.fingerprint}\n${setupScript(recipe)}`)
    .digest("hex")
    .slice(0, 16)

const imageFailure = (step: string, result: ExecResult): EphemeralProviderError =>
  new EphemeralProviderError(
    "tart",
    `${step} failed (exit ${result.exitCode}):\n${outputTail(result)}`
  )

const outputTail = (result: ExecResult): string =>
  `${result.stdout}${result.stderr}`.trimEnd().split("\n").slice(-outputTailLines).join("\n")
