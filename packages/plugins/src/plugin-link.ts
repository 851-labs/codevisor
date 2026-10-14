import { lstat, mkdir, readFile, stat, symlink, unlink } from "node:fs/promises"
import { isAbsolute, join, resolve } from "node:path"

import type { LinkPluginRequest, PluginManifest } from "@codevisor/api"

import { parsePluginManifest, PLUGIN_MANIFEST_FILENAME } from "./plugin-manifest.js"
import type { InstalledPlugin } from "./plugin-store.js"
import { PluginsError } from "./plugins-error.js"

export interface PluginLinkDeps {
  readonly pluginsRoot: string
  readonly stop: (pluginId: string) => void
  readonly installedWithId: (pluginId: string) => InstalledPlugin | undefined
  readonly managedDirectory: (pluginId: string) => string
  readonly withLock: <T>(pluginId: string, work: () => Promise<T>) => Promise<T>
  readonly recoverPlugin: (pluginId: string) => Promise<void>
}

export const linkPlugin = async (
  deps: PluginLinkDeps,
  request: LinkPluginRequest
): Promise<PluginManifest> => {
  if (!isAbsolute(request.path)) {
    throw new PluginsError("invalid", `Plugin link path must be absolute: ${request.path}`)
  }
  const target = resolve(request.path)
  let targetStats
  try {
    targetStats = await stat(target)
  } catch {
    throw new PluginsError("invalid", `Not a directory: ${request.path}`)
  }
  if (!targetStats.isDirectory()) {
    throw new PluginsError("invalid", `Not a directory: ${request.path}`)
  }
  let raw: string
  try {
    raw = await readFile(join(target, PLUGIN_MANIFEST_FILENAME), "utf8")
  } catch {
    throw new PluginsError("invalid", `No ${PLUGIN_MANIFEST_FILENAME} found in ${request.path}`)
  }
  const manifest = parsePluginManifest(raw)
  return deps.withLock(manifest.id, async () => {
    await deps.recoverPlugin(manifest.id)
    if (deps.installedWithId(manifest.id) !== undefined) {
      throw new PluginsError("conflict", `Plugin ${manifest.id} is already installed`)
    }
    const destination = deps.managedDirectory(manifest.id)
    try {
      await lstat(destination)
      throw new PluginsError("conflict", `${destination} already exists — remove it before linking`)
    } catch (cause) {
      if (cause instanceof PluginsError) {
        throw cause
      }
    }
    await mkdir(deps.pluginsRoot, { recursive: true })
    await symlink(target, destination)
    return manifest
  })
}

export const unlinkPlugin = async (deps: PluginLinkDeps, pluginId: string): Promise<void> => {
  await deps.withLock(pluginId, async () => {
    const plugin = deps.installedWithId(pluginId)
    if (plugin === undefined) {
      throw new PluginsError("notFound", `Plugin not installed: ${pluginId}`)
    }
    const stats = await lstat(plugin.path)
    if (!stats.isSymbolicLink()) {
      throw new PluginsError(
        "invalid",
        `Plugin ${pluginId} is a managed install, not a link — uninstall it instead`
      )
    }
    deps.stop(pluginId)
    await unlink(plugin.path)
  })
}
