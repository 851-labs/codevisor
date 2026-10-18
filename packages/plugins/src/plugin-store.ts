import { existsSync, readdirSync, readFileSync, statSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

import type { PluginManifest, PluginSource } from "@codevisor/api"

import { parsePluginManifest, PLUGIN_MANIFEST_FILENAME } from "./plugin-manifest.js"
import { readPluginInstallReceipt, type PluginInstallReceipt } from "./plugin-receipt.js"
import { PluginsError } from "./plugins-error.js"

export const MANAGED_PLUGIN_MARKER = ".codevisor-managed-plugin"

export const MANAGED_PLUGIN_MARKER_CONTENT =
  "This plugin was installed by Codevisor and may be removed by uninstalling it.\n"

export interface InstalledPlugin {
  readonly id: string
  readonly directoryName: string
  readonly path: string
  readonly source: PluginSource
  readonly manifest: PluginManifest
  readonly receipt?: PluginInstallReceipt
}

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

type PluginScanEntry = InstalledPlugin | InvalidPluginEntry | undefined

const scanPluginManifest = (
  directoryName: string,
  path: string,
  seenIds: Map<string, string>
): PluginScanEntry => {
  const manifestPath = join(path, PLUGIN_MANIFEST_FILENAME)
  if (!existsSync(manifestPath)) {
    return { directoryName, message: `Missing ${PLUGIN_MANIFEST_FILENAME}` }
  }
  try {
    const manifest = parsePluginManifest(readFileSync(manifestPath, "utf8"))
    const existing = seenIds.get(manifest.id)
    if (existing !== undefined) {
      return {
        directoryName,
        message: `Duplicate plugin id ${manifest.id} (already provided by ${existing})`
      }
    }
    seenIds.set(manifest.id, directoryName)
    const receipt = readPluginInstallReceipt(path)
    return {
      directoryName,
      id: manifest.id,
      manifest,
      path,
      source: existsSync(join(path, MANAGED_PLUGIN_MARKER)) ? "managed" : "linked",
      ...(receipt === undefined || receipt.pluginId !== manifest.id ? {} : { receipt })
    }
  } catch (cause) {
    return {
      directoryName,
      /* v8 ignore next */
      message: cause instanceof Error ? cause.message : String(cause)
    }
  }
}

const scanPluginDirectory = (
  root: string,
  directoryName: string,
  seenIds: Map<string, string>
): PluginScanEntry => {
  if (directoryName.startsWith(".")) return undefined
  const path = join(root, directoryName)
  try {
    if (!statSync(path).isDirectory()) return undefined
  } catch {
    return { directoryName, message: "Unreadable entry (broken symlink?)" }
  }
  return scanPluginManifest(directoryName, path, seenIds)
}

export const scanPlugins = (root: string): PluginScan => {
  const plugins: Array<InstalledPlugin> = []
  const invalid: Array<InvalidPluginEntry> = []
  if (!existsSync(root)) return { invalid, plugins }
  const seenIds = new Map<string, string>()
  for (const entry of readdirSync(root).toSorted()) {
    const result = scanPluginDirectory(root, entry, seenIds)
    if (result === undefined) continue
    if ("message" in result) {
      invalid.push(result)
    } else {
      plugins.push(result)
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
