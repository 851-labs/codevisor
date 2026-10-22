import { randomUUID } from "node:crypto"

import type {
  PluginManifest,
  PluginNamedChanges,
  PluginRegistryIndex,
  PluginUpdatePlan,
  PluginUpdateReview,
  PluginUpdatesResponse
} from "@codevisor/api"

import { displayPluginCommand, pluginRunCommand, pluginSetupCommands } from "./plugin-command.js"
import type { PreparedPluginUpdate } from "./plugin-install-types.js"
import type { PluginInstaller } from "./plugin-install.js"
import type { InstalledPlugin } from "./plugin-store.js"
import {
  registryFailures,
  resolveTracked,
  triageInstalled,
  type ResolvedUpdate
} from "./plugin-update-status.js"
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

interface StoredPlan {
  readonly candidate: PreparedPluginUpdate
  readonly plan: PluginUpdatePlan
  readonly expiresAtMs: number
}

const review = (manifest: PluginManifest, platform: string): PluginUpdateReview => ({
  ...(manifest.ageRating === undefined ? {} : { ageRating: manifest.ageRating }),
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
    const { resolved, tracked } = triageInstalled(deps.listInstalled(), checkedAt)
    if (tracked.length === 0) return resolved

    let index: PluginRegistryIndex
    try {
      if (deps.fetchRegistry === undefined) throw new Error("Plugin registry is unavailable")
      index = await deps.fetchRegistry()
    } catch (cause) {
      return [...resolved, ...registryFailures(tracked, checkedAt, cause)]
    }

    return [...resolved, ...tracked.map((item) => resolveTracked(item, index, checkedAt, deps))]
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
