import type {
  PluginManifest,
  PluginNamedChanges,
  PluginRegistryEntry,
  PluginRegistryIndex,
  PluginUpdatePlan,
  PluginUpdateReview,
  PluginUpdatesResponse
} from "@codevisor/api"
import {
  compareSemanticVersions,
  isSupportedPluginProtocolVersion,
  parseSemanticVersion
} from "@codevisor/api"
import { randomUUID } from "node:crypto"
import { displayPluginCommand, pluginRunCommand, pluginSetupCommands } from "./plugin-command.js"
import type { PluginInstaller } from "./plugin-install.js"
import type { PreparedPluginUpdate } from "./plugin-install-types.js"
import { readPluginInstallReceipt } from "./plugin-receipt.js"
import type { InstalledPlugin } from "./plugin-store.js"
import { PluginsError } from "./plugins-error.js"

export const PLUGIN_UPDATE_PLAN_TTL_MS = 15 * 60_000

export interface PluginUpdatesDeps {
  readonly installer: PluginInstaller
  readonly listInstalled: () => ReadonlyArray<InstalledPlugin>
  readonly fetchRegistry?: () => Promise<PluginRegistryIndex>
  readonly platform: string
  readonly codevisorVersion?: string
  readonly now?: () => number
  readonly createPlanId?: () => string
  readonly planTtlMs?: number
}

export interface PluginUpdates {
  readonly list: () => Promise<PluginUpdatesResponse>
  readonly prepare: (pluginId: string) => Promise<PluginUpdatePlan>
  readonly apply: (pluginId: string, planId: string) => Promise<PluginManifest>
}

interface ResolvedUpdate {
  readonly installed: InstalledPlugin
  readonly installedResolvedCommit?: string
  readonly entry?: PluginRegistryEntry
  readonly status: PluginUpdatesResponse["updates"][number]
}

interface StoredPlan {
  readonly candidate: PreparedPluginUpdate
  readonly plan: PluginUpdatePlan
  readonly expiresAtMs: number
}

const errorMessage = (cause: unknown): string =>
  cause instanceof Error ? cause.message : String(cause)

const review = (manifest: PluginManifest, platform: string): PluginUpdateReview => ({
  panes: manifest.panes,
  runCommand: displayPluginCommand(pluginRunCommand(manifest)),
  setupCommands: pluginSetupCommands(manifest, platform).map(displayPluginCommand),
  version: manifest.version,
  ...(manifest.tools === undefined ? {} : { tools: manifest.tools }),
  ...(manifest.protocolVersion === 1 || manifest.requirements === undefined
    ? {}
    : { requirements: manifest.requirements })
})

const namedChanges = <Value>(
  current: ReadonlyArray<Value>,
  candidate: ReadonlyArray<Value>,
  name: (value: Value) => string
): PluginNamedChanges => {
  const before = new Map(current.map((value) => [name(value), value]))
  const after = new Map(candidate.map((value) => [name(value), value]))
  return {
    added: [...after.keys()].filter((key) => !before.has(key)).toSorted(),
    changed: [...after.keys()]
      .filter(
        (key) =>
          before.has(key) && JSON.stringify(before.get(key)) !== JSON.stringify(after.get(key))
      )
      .toSorted(),
    removed: [...before.keys()].filter((key) => !after.has(key)).toSorted()
  }
}

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

export const makePluginUpdates = (deps: PluginUpdatesDeps): PluginUpdates => {
  const now = deps.now ?? Date.now
  const createPlanId = deps.createPlanId ?? randomUUID
  const planTtlMs = deps.planTtlMs ?? PLUGIN_UPDATE_PLAN_TTL_MS
  const plans = new Map<string, StoredPlan>()

  const cleanupExpired = async (): Promise<void> => {
    const currentTime = now()
    const expired = [...plans.entries()].filter(([, stored]) => stored.expiresAtMs <= currentTime)
    for (const [planId] of expired) {
      plans.delete(planId)
    }
    await Promise.all(
      expired.map(([, stored]) => deps.installer.discardPreparedUpdate(stored.candidate))
    )
  }

  const resolveUpdates = async (): Promise<ReadonlyArray<ResolvedUpdate>> => {
    const checkedAt = new Date(now()).toISOString()
    const installed = deps.listInstalled()
    const resolved: Array<ResolvedUpdate> = []
    const tracked: Array<{
      installed: InstalledPlugin
      repo: string
      resolvedCommit: string
    }> = []
    for (const plugin of installed) {
      const base = { checkedAt, installedVersion: plugin.manifest.version, pluginId: plugin.id }
      if (plugin.source === "linked") {
        resolved.push({
          installed: plugin,
          status: {
            ...base,
            reason: "Linked development plugins do not track registry updates",
            state: "pinned"
          }
        })
        continue
      }
      const receipt = readPluginInstallReceipt(plugin.path)
      if (receipt === undefined || receipt.pluginId !== plugin.id) {
        resolved.push({
          installed: plugin,
          status: {
            ...base,
            reason: "Reinstall from a known source to enable updates",
            state: "sourceUnknown"
          }
        })
        continue
      }
      if (receipt.source.tracking === "pinned") {
        resolved.push({
          installed: plugin,
          status: {
            ...base,
            reason: "This plugin was installed from a pinned source",
            state: "pinned"
          }
        })
        continue
      }
      if (receipt.source.repo === undefined) {
        resolved.push({
          installed: plugin,
          status: {
            ...base,
            reason: "The install receipt has no registry repository",
            state: "checkFailed"
          }
        })
        continue
      }
      tracked.push({
        installed: plugin,
        repo: receipt.source.repo,
        resolvedCommit: receipt.resolvedCommit
      })
    }
    if (tracked.length === 0) return resolved

    let index: PluginRegistryIndex
    try {
      if (deps.fetchRegistry === undefined) throw new Error("Plugin registry is unavailable")
      index = await deps.fetchRegistry()
    } catch (cause) {
      for (const item of tracked) {
        resolved.push({
          installed: item.installed,
          status: {
            checkedAt,
            installedVersion: item.installed.manifest.version,
            pluginId: item.installed.id,
            reason: errorMessage(cause),
            state: "checkFailed"
          }
        })
      }
      return resolved
    }

    for (const item of tracked) {
      const plugin = item.installed
      const entry = index.entries.find((candidate) => candidate.id === plugin.id)
      const base = { checkedAt, installedVersion: plugin.manifest.version, pluginId: plugin.id }
      if (entry === undefined) {
        resolved.push({
          installed: plugin,
          status: {
            ...base,
            reason: `Plugin ${plugin.id} is not present in the registry`,
            state: "checkFailed"
          }
        })
        continue
      }
      if (entry.repo.toLowerCase() !== item.repo.toLowerCase()) {
        resolved.push({
          entry,
          installed: plugin,
          installedResolvedCommit: item.resolvedCommit,
          status: {
            ...base,
            reason: `Registry repository ${entry.repo} does not match installed source ${item.repo}`,
            registryVersion: entry.version,
            state: "checkFailed"
          }
        })
        continue
      }
      if (
        parseSemanticVersion(plugin.manifest.version) === undefined ||
        parseSemanticVersion(entry.version) === undefined
      ) {
        resolved.push({
          entry,
          installed: plugin,
          installedResolvedCommit: item.resolvedCommit,
          status: {
            ...base,
            reason: "Installed and registry versions must both be valid semantic versions",
            registryVersion: entry.version,
            state: "checkFailed"
          }
        })
        continue
      }
      if (compareSemanticVersions(entry.version, plugin.manifest.version) <= 0) {
        resolved.push({
          entry,
          installed: plugin,
          status: { ...base, registryVersion: entry.version, state: "current" }
        })
        continue
      }
      const incompatible = compatibilityFailure(entry, deps.platform, deps.codevisorVersion)
      resolved.push({
        entry,
        installed: plugin,
        installedResolvedCommit: item.resolvedCommit,
        status: {
          ...base,
          registryVersion: entry.version,
          ...(incompatible === undefined ? {} : { reason: incompatible }),
          state: incompatible === undefined ? "available" : "incompatible"
        }
      })
    }
    return resolved
  }

  return {
    list: async () => {
      await cleanupExpired()
      return { updates: (await resolveUpdates()).map(({ status }) => status) }
    },
    prepare: async (pluginId) => {
      await cleanupExpired()
      const update = (await resolveUpdates()).find(
        (candidate) => candidate.installed.id === pluginId
      )
      if (update === undefined)
        throw new PluginsError("notFound", `Plugin not installed: ${pluginId}`)
      if (update.status.state !== "available" || update.entry === undefined) {
        throw new PluginsError(
          "invalid",
          update.status.reason ?? `Plugin ${pluginId} has no compatible update available`
        )
      }
      const entry = update.entry
      const planId = createPlanId()
      const candidate = await deps.installer.prepareUpdate({
        expectedPluginId: pluginId,
        planId,
        source: `${entry.repo}#${entry.commit}`,
        sourceReceipt: {
          kind: "github",
          repo: entry.repo,
          tracking: "registry",
          url: `https://github.com/${entry.repo}.git`
        }
      })
      try {
        if (
          candidate.resolvedCommit.toLowerCase() !== entry.commit.toLowerCase() ||
          candidate.manifest.version !== entry.version ||
          candidate.previousManifest.version !== update.installed.manifest.version ||
          candidate.previousResolvedCommit !== update.installedResolvedCommit
        ) {
          throw new PluginsError(
            "unavailable",
            `Registry metadata changed while preparing ${pluginId}; check for updates again`
          )
        }
        const expiresAtMs = now() + planTtlMs
        const current = review(candidate.previousManifest, deps.platform)
        const next = review(candidate.manifest, deps.platform)
        const plan: PluginUpdatePlan = {
          candidate: next,
          current,
          expiresAt: new Date(expiresAtMs).toISOString(),
          name: candidate.manifest.name,
          paneChanges: namedChanges(current.panes, next.panes, (pane) => pane.type),
          planId,
          pluginId,
          resolvedCommit: candidate.resolvedCommit,
          toolChanges: namedChanges(current.tools ?? [], next.tools ?? [], (tool) => tool.name)
        }
        const existing = [...plans.entries()].find(
          ([, stored]) => stored.plan.pluginId === pluginId
        )
        if (existing !== undefined) {
          const [existingId, stored] = existing
          plans.delete(existingId)
          await deps.installer.discardPreparedUpdate(stored.candidate)
        }
        plans.set(planId, { candidate, expiresAtMs, plan })
        return plan
      } catch (cause) {
        await deps.installer.discardPreparedUpdate(candidate)
        throw cause
      }
    },
    apply: async (pluginId, planId) => {
      await cleanupExpired()
      const stored = plans.get(planId)
      if (stored === undefined || stored.plan.pluginId !== pluginId) {
        throw new PluginsError("notFound", `Plugin update plan is missing or expired: ${planId}`)
      }
      plans.delete(planId)
      try {
        return await deps.installer.applyPreparedUpdate(stored.candidate)
      } finally {
        await deps.installer.discardPreparedUpdate(stored.candidate)
      }
    }
  }
}
