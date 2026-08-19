import type { PluginManifest, PluginSource } from "@codevisor/api"
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"
import { parsePluginManifest, PLUGIN_MANIFEST_FILENAME } from "./plugin-manifest.js"
import { PluginsError } from "./plugins-error.js"

/// Marks a plugin directory as installed (and therefore deletable) by
/// Codevisor. Linked dev plugins never carry the marker, so uninstall can
/// only ever remove what the app provably created — same discipline as the
/// skills store's managed marker.
export const MANAGED_PLUGIN_MARKER = ".codevisor-managed-plugin"

export const MANAGED_PLUGIN_MARKER_CONTENT =
  "This plugin was installed by Codevisor and may be removed by uninstalling it.\n"

export interface InstalledPlugin {
  readonly id: string
  readonly directoryName: string
  readonly path: string
  readonly source: PluginSource
  readonly manifest: PluginManifest
}

/// A directory under the plugins root that could not be loaded as a plugin —
/// surfaced (not silently dropped) so authors and agents can see why their
/// plugin is missing from the list.
export interface InvalidPluginEntry {
  readonly directoryName: string
  readonly message: string
}

export interface PluginScan {
  readonly plugins: ReadonlyArray<InstalledPlugin>
  readonly invalid: ReadonlyArray<InvalidPluginEntry>
}

export const defaultPluginsRoot = (): string =>
  process.env["CODEVISOR_PLUGINS_ROOT"] ?? join(homedir(), ".codevisor", "plugins")

/// Scans the plugins root for installed plugins. Dropping a manifest-bearing
/// directory (or symlink) into the root IS installation for dev workflows;
/// no registration step exists on purpose. Invalid entries never abort the
/// scan — one broken plugin must not hide the rest.
export const scanPlugins = (root: string = defaultPluginsRoot()): PluginScan => {
  const plugins: Array<InstalledPlugin> = []
  const invalid: Array<InvalidPluginEntry> = []
  if (!existsSync(root)) {
    return { invalid, plugins }
  }
  const seenIds = new Map<string, string>()
  for (const entry of readdirSync(root).sort()) {
    if (entry.startsWith(".")) {
      continue
    }
    const path = join(root, entry)
    try {
      // statSync follows symlinks, so linked dev plugins resolve like real
      // directories.
      if (!statSync(path).isDirectory()) {
        continue
      }
    } catch {
      invalid.push({ directoryName: entry, message: "Unreadable entry (broken symlink?)" })
      continue
    }
    const manifestPath = join(path, PLUGIN_MANIFEST_FILENAME)
    if (!existsSync(manifestPath)) {
      invalid.push({ directoryName: entry, message: `Missing ${PLUGIN_MANIFEST_FILENAME}` })
      continue
    }
    try {
      const manifest = parsePluginManifest(readFileSync(manifestPath, "utf8"))
      const existing = seenIds.get(manifest.id)
      if (existing !== undefined) {
        invalid.push({
          directoryName: entry,
          message: `Duplicate plugin id ${manifest.id} (already provided by ${existing})`
        })
        continue
      }
      seenIds.set(manifest.id, entry)
      plugins.push({
        directoryName: entry,
        id: manifest.id,
        manifest,
        path,
        source: existsSync(join(path, MANAGED_PLUGIN_MARKER)) ? "managed" : "linked"
      })
    } catch (cause) {
      invalid.push({
        directoryName: entry,
        /* v8 ignore next -- manifest loading only throws PluginsError or fs errors with messages. */
        message: cause instanceof Error ? cause.message : String(cause)
      })
    }
  }
  return { invalid, plugins }
}

export const findPluginOrFail = (scan: PluginScan, pluginId: string): InstalledPlugin => {
  const plugin = scan.plugins.find((candidate) => candidate.id === pluginId)
  if (plugin === undefined) {
    throw new PluginsError("notFound", `Plugin not installed: ${pluginId}`)
  }
  return plugin
}
