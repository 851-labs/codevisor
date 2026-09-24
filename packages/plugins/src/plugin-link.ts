import { lstat, mkdir, readFile, stat, symlink, unlink } from "node:fs/promises"
import { isAbsolute, join, resolve } from "node:path"

import type { LinkPluginRequest, PluginManifest } from "@codevisor/api"

import { parsePluginManifest, PLUGIN_MANIFEST_FILENAME } from "./plugin-manifest.js"
import type { InstalledPlugin } from "./plugin-store.js"
import { PluginsError } from "./plugins-error.js"

/// Development linking: the one install path whose bytes Codevisor does not
/// own. A link points at the developer's checkout, so both operations here
/// are constrained by the same rule — Codevisor creates and removes the
/// LINK, and never touches what it points at.
export interface PluginLinkDeps {
  readonly pluginsRoot: string
  readonly stop: (pluginId: string) => void
  readonly installedWithId: (pluginId: string) => InstalledPlugin | undefined
  readonly managedDirectory: (pluginId: string) => string
  readonly withLock: <T>(pluginId: string, work: () => Promise<T>) => Promise<T>
  readonly recoverPlugin: (pluginId: string) => Promise<void>
}

/// Symlinks a local plugin directory into the plugins root. The manifest is
/// parsed from the target first, so a directory that is not a plugin is
/// refused before anything is written.
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
      // ENOENT: the link path is free.
    }
    await mkdir(deps.pluginsRoot, { recursive: true })
    await symlink(target, destination)
    return manifest
  })
}

/// Removes a link Codevisor created, and only the link. Uninstalling a
/// managed plugin is a different operation with a different confirmation;
/// refusing one here keeps the two destructive paths from being
/// interchangeable by accident.
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
    // unlink, never rm -r: the entry is a symlink, and the only thing that
    // may disappear is the link itself.
    await unlink(plugin.path)
  })
}
