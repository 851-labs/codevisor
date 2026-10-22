import type {
  PluginRegistryEntry,
  PluginRegistryIndex,
  PluginUpdatesResponse
} from "@codevisor/api"
import {
  compareSemanticVersions,
  isSupportedPluginProtocolVersion,
  parseSemanticVersion
} from "@codevisor/api"

import { readPluginInstallReceipt, type PluginInstallReceipt } from "./plugin-receipt.js"
import type { InstalledPlugin } from "./plugin-store.js"

export type PluginUpdateStatus = PluginUpdatesResponse["updates"][number]

export interface ResolvedUpdate {
  readonly installed: InstalledPlugin
  readonly installedResolvedCommit?: string
  readonly entry?: PluginRegistryEntry
  readonly status: PluginUpdateStatus
}

export interface TrackedPlugin {
  readonly installed: InstalledPlugin
  readonly repo: string
  readonly resolvedCommit: string
}

export interface InstalledTriage {
  readonly resolved: Array<ResolvedUpdate>
  readonly tracked: Array<TrackedPlugin>
}

export interface UpdateTarget {
  readonly platform: string
  readonly codevisorVersion?: string
}

export const triageInstalled = (
  installed: ReadonlyArray<InstalledPlugin>,
  checkedAt: string
): InstalledTriage => {
  const triage: InstalledTriage = { resolved: [], tracked: [] }
  for (const plugin of installed) {
    const outcome = triagePlugin(plugin, checkedAt)
    if (outcome.kind === "tracked") triage.tracked.push(outcome.plugin)
    else triage.resolved.push(outcome.update)
  }
  return triage
}

export const registryFailures = (
  tracked: ReadonlyArray<TrackedPlugin>,
  checkedAt: string,
  cause: unknown
): Array<ResolvedUpdate> =>
  tracked.map((item) => ({
    installed: item.installed,
    status: {
      ...statusBase(item.installed, checkedAt),
      reason: errorMessage(cause),
      state: "checkFailed"
    }
  }))

export const resolveTracked = (
  item: TrackedPlugin,
  index: PluginRegistryIndex,
  checkedAt: string,
  target: UpdateTarget
): ResolvedUpdate => {
  const plugin = item.installed
  const entry = index.entries.find((candidate) => candidate.id === plugin.id)
  const base = statusBase(plugin, checkedAt)
  if (entry === undefined) return missingFromRegistry(plugin, base)

  if (repoMismatch(entry, item)) {
    return failedCheck(
      item,
      entry,
      base,
      `Registry repository ${entry.repo} does not match installed source ${item.repo}`
    )
  }
  if (hasInvalidVersion(plugin, entry)) {
    return failedCheck(
      item,
      entry,
      base,
      "Installed and registry versions must both be valid semantic versions"
    )
  }
  if (isUpToDate(entry, plugin)) return currentUpdate(plugin, entry, base)

  const incompatible = compatibilityFailure(entry, target.platform, target.codevisorVersion)
  return candidateUpdate(item, entry, base, incompatible)
}

interface StatusBase {
  readonly checkedAt: string
  readonly installedVersion: string
  readonly pluginId: string
}

type PluginTriage =
  | { readonly kind: "resolved"; readonly update: ResolvedUpdate }
  | { readonly kind: "tracked"; readonly plugin: TrackedPlugin }

const triagePlugin = (plugin: InstalledPlugin, checkedAt: string): PluginTriage => {
  const base = statusBase(plugin, checkedAt)
  if (plugin.source === "linked") {
    return untracked(
      plugin,
      base,
      "pinned",
      "Linked development plugins do not track registry updates"
    )
  }

  const receipt = receiptFor(plugin)
  if (receipt === undefined) {
    return untracked(
      plugin,
      base,
      "sourceUnknown",
      "Reinstall from a known source to enable updates"
    )
  }
  if (receipt.source.tracking === "pinned") {
    return untracked(plugin, base, "pinned", "This plugin was installed from a pinned source")
  }
  if (receipt.source.repo === undefined) {
    return untracked(plugin, base, "checkFailed", "The install receipt has no registry repository")
  }

  return {
    kind: "tracked",
    plugin: {
      installed: plugin,
      repo: receipt.source.repo,
      resolvedCommit: receipt.resolvedCommit
    }
  }
}

const receiptFor = (plugin: InstalledPlugin): PluginInstallReceipt | undefined => {
  const receipt = readPluginInstallReceipt(plugin.path)
  if (receipt === undefined) return undefined
  if (receipt.pluginId !== plugin.id) return undefined
  return receipt
}

const untracked = (
  plugin: InstalledPlugin,
  base: StatusBase,
  state: PluginUpdateStatus["state"],
  reason: string
): PluginTriage => ({
  kind: "resolved",
  update: { installed: plugin, status: { ...base, reason, state } }
})

const statusBase = (plugin: InstalledPlugin, checkedAt: string): StatusBase => ({
  checkedAt,
  installedVersion: plugin.manifest.version,
  pluginId: plugin.id
})

const errorMessage = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

const repoMismatch = (entry: PluginRegistryEntry, item: TrackedPlugin): boolean =>
  entry.repo.toLowerCase() !== item.repo.toLowerCase()

const hasInvalidVersion = (plugin: InstalledPlugin, entry: PluginRegistryEntry): boolean =>
  parseSemanticVersion(plugin.manifest.version) === undefined ||
  parseSemanticVersion(entry.version) === undefined

const isUpToDate = (entry: PluginRegistryEntry, plugin: InstalledPlugin): boolean =>
  compareSemanticVersions(entry.version, plugin.manifest.version) <= 0

const missingFromRegistry = (plugin: InstalledPlugin, base: StatusBase): ResolvedUpdate => ({
  installed: plugin,
  status: {
    ...base,
    reason: `Plugin ${plugin.id} is not present in the registry`,
    state: "checkFailed"
  }
})

const failedCheck = (
  item: TrackedPlugin,
  entry: PluginRegistryEntry,
  base: StatusBase,
  reason: string
): ResolvedUpdate => ({
  entry,
  installed: item.installed,
  installedResolvedCommit: item.resolvedCommit,
  status: { ...base, reason, registryVersion: entry.version, state: "checkFailed" }
})

const currentUpdate = (
  plugin: InstalledPlugin,
  entry: PluginRegistryEntry,
  base: StatusBase
): ResolvedUpdate => ({
  entry,
  installed: plugin,
  status: { ...base, registryVersion: entry.version, state: "current" }
})

const candidateUpdate = (
  item: TrackedPlugin,
  entry: PluginRegistryEntry,
  base: StatusBase,
  incompatible: string | undefined
): ResolvedUpdate => ({
  entry,
  installed: item.installed,
  installedResolvedCommit: item.resolvedCommit,
  status: {
    ...base,
    registryVersion: entry.version,
    ...(incompatible === undefined ? {} : { reason: incompatible }),
    state: incompatible === undefined ? "available" : "incompatible"
  }
})

const compatibilityFailure = (
  entry: PluginRegistryEntry,
  platform: string,
  codevisorVersion: string | undefined
): string | undefined => {
  if (!isSupportedPluginProtocolVersion(entry.protocolVersion)) {
    return `Version ${entry.version} uses unsupported plugin protocol ${entry.protocolVersion}`
  }
  if (entry.platforms !== undefined && !entry.platforms.includes(platform)) {
    return `Version ${entry.version} does not support ${platform}`
  }
  if (entry.minCodevisorVersion === undefined) return undefined
  if (parseSemanticVersion(entry.minCodevisorVersion) === undefined) {
    return `Version ${entry.version} has invalid minimum Codevisor version metadata`
  }
  if (codevisorVersion === undefined || parseSemanticVersion(codevisorVersion) === undefined) {
    return `Version ${entry.version} requires Codevisor ${entry.minCodevisorVersion} or newer, but this build has no comparable version`
  }
  return compareSemanticVersions(codevisorVersion, entry.minCodevisorVersion) < 0
    ? `Version ${entry.version} requires Codevisor ${entry.minCodevisorVersion} or newer; this server is ${codevisorVersion}`
    : undefined
}
