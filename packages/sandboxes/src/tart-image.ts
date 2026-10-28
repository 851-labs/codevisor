import { createHash } from "node:crypto"
import { basename } from "node:path"

import { imageSetupScript, imageToolsScript, type ImageApp } from "./image-setup.js"
import { SandboxProviderError, type ExecResult, type ProvisionProgress } from "./provider.js"
import { ensurePulled } from "./tart-pull.js"
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
export const TOOLS_PREFIX = "codevisor-tools-"

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

export interface ToolsImage {
  readonly name: string
  readonly baseImage: string
  readonly agentCommands: ReadonlyArray<string>
}

export interface PreparedImage {
  readonly name: string
  readonly tools: ToolsImage
  readonly recipe: TartImageRecipe
}

interface LayerBuild {
  readonly from: string
  readonly to: string
  readonly sizing: TartSizing
  readonly progress: ProvisionProgress
  readonly install: (vm: string) => Promise<void>
}

const buildTimeoutMs = 45 * 60 * 1000
const outputTailLines = 30
const buildingSuffix = "-building"
const applicationsFolder = "/Applications"
const builds = new Map<string, Promise<void>>()

export const preparedImage = (baseImage: string, recipe: TartImageRecipe): PreparedImage => {
  const tools = toolsImage(baseImage, recipe.agentCommands)
  return { name: `${IMAGE_PREFIX}${codevisorLayerHash(tools, recipe)}`, tools, recipe }
}

export const isPreparedImage = (image: string): boolean => image.startsWith(IMAGE_PREFIX)

export const ensureImage = (
  host: TartHost,
  tart: TartCommands,
  image: PreparedImage,
  sizing: TartSizing,
  progress: ProvisionProgress
): Promise<void> =>
  once(image.name, progress, async () => {
    if (await tart.has(image.name)) {
      progress.log(`${image.name} is already prepared`)
      return
    }
    await ensureTools(host, tart, image.tools, sizing, progress)
    await buildLayer(host, tart, {
      from: image.tools.name,
      to: image.name,
      sizing,
      progress,
      install: (vm) => installCodevisor(host, vm, image.recipe, progress)
    })
    await removeOtherLayers(tart, IMAGE_PREFIX, image.name, progress)
  })

const ensureTools = (
  host: TartHost,
  tart: TartCommands,
  tools: ToolsImage,
  sizing: TartSizing,
  progress: ProvisionProgress
): Promise<void> =>
  once(tools.name, progress, async () => {
    if (await tart.has(tools.name)) return

    await ensurePulled(host, tart, tools.baseImage, sizing, progress)
    await buildLayer(host, tart, {
      from: tools.baseImage,
      to: tools.name,
      sizing,
      progress,
      install: (vm) =>
        runScript(
          host,
          vm,
          imageToolsScript(tools.agentCommands),
          "Installing the agent CLIs",
          progress
        )
    })
    await removeOtherLayers(tart, TOOLS_PREFIX, tools.name, progress)
  })

const once = (
  key: string,
  progress: ProvisionProgress,
  work: () => Promise<void>
): Promise<void> => {
  const pending = builds.get(key)
  if (pending !== undefined) {
    progress.log("Waiting for another sandbox that's preparing this image")
    return pending
  }

  const started = work().finally(() => builds.delete(key))
  builds.set(key, started)
  return started
}

const buildLayer = async (host: TartHost, tart: TartCommands, layer: LayerBuild): Promise<void> => {
  await assertDiskRoom(host, layer.sizing)
  const vm = `${layer.to}${buildingSuffix}`
  await tart.remove(vm)
  layer.progress.log(`tart clone ${layer.from} ${vm}`)
  await tart.must(["clone", layer.from, vm])
  try {
    await installInto(host, tart, vm, layer)
  } catch (cause) {
    await tart.remove(vm)
    throw cause
  }
}

const installInto = async (
  host: TartHost,
  tart: TartCommands,
  vm: string,
  layer: LayerBuild
): Promise<void> => {
  await assertMacOSSlot(tart)
  await sizeVm(tart, vm, layer.sizing, layer.progress)
  await boot(host, tart, vm, layer.progress)
  await layer.install(vm)
  layer.progress.log(`tart stop ${vm}`)
  await tart.must(["stop", vm])
  await tart.must(["rename", vm, layer.to])
}

const installCodevisor = async (
  host: TartHost,
  vm: string,
  recipe: TartImageRecipe,
  progress: ProvisionProgress
): Promise<void> => {
  await copyApp(host, vm, recipe, progress)
  await runScript(host, vm, setupScript(recipe), "Setting up macOS", progress)
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

const runScript = async (
  host: TartHost,
  vm: string,
  script: string,
  step: string,
  progress: ProvisionProgress
): Promise<void> => {
  const result = await host.run(["exec", "-i", vm, "sh", "-c", script], {
    timeoutMs: buildTimeoutMs,
    onOutput: progress.output
  })
  if (result.exitCode !== 0) throw imageFailure(step, result)
}

const removeOtherLayers = async (
  tart: TartCommands,
  prefix: string,
  current: string,
  progress: ProvisionProgress
): Promise<void> => {
  const stale = (await tart.vms()).filter((vm) => isStaleLayer(vm.Name, prefix, current))
  for (const vm of stale) {
    progress.log(`Deleting the older image ${vm.Name}`)
    await tart.remove(vm.Name)
  }
}

const isStaleLayer = (name: string, prefix: string, current: string): boolean =>
  name.startsWith(prefix) && name !== current && !name.endsWith(buildingSuffix)

const toolsImage = (baseImage: string, agentCommands: ReadonlyArray<string>): ToolsImage => ({
  name: `${TOOLS_PREFIX}${shortHash([baseImage, imageToolsScript(agentCommands)])}`,
  baseImage,
  agentCommands
})

const setupScript = (recipe: TartImageRecipe): string =>
  imageSetupScript({
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

const codevisorLayerHash = (tools: ToolsImage, recipe: TartImageRecipe): string =>
  shortHash([tools.name, recipe.fingerprint, setupScript(recipe)])

const shortHash = (parts: ReadonlyArray<string>): string =>
  createHash("sha256").update(parts.join("\n")).digest("hex").slice(0, 16)

const imageFailure = (step: string, result: ExecResult): SandboxProviderError =>
  new SandboxProviderError(
    "tart",
    `${step} failed (exit ${result.exitCode}):\n${outputTail(result)}`
  )

const outputTail = (result: ExecResult): string =>
  `${result.stdout}${result.stderr}`.trimEnd().split("\n").slice(-outputTailLines).join("\n")
