import type { SyncEntryRecord } from "@codevisor/sync"

import { MCPS_SYNC_NAMESPACE, reconcileMcps } from "../infra/config-sync.js"
import { CREDENTIALS_SYNC_NAMESPACE, reconcileCredentials } from "../infra/credential-sync.js"
import {
  HARNESSES_SYNC_NAMESPACE,
  reconcileHarnesses,
  type HarnessSyncStatus
} from "../infra/harness-sync.js"
import { PLUGINS_SYNC_NAMESPACE, pluginSyncOrigin, reconcilePlugins } from "../infra/plugin-sync.js"
import type { PluginSyncStatus } from "../infra/plugin-sync.js"
import { reconcileSkills, SKILLS_SYNC_NAMESPACE } from "../infra/skills-sync.js"
import type { SkillsSyncStatus } from "../infra/skills-sync.js"
import {
  appendAndPublish,
  run,
  swallowError,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { discoverHarnesses } from "./harnesses.js"
import {
  refreshHarnessReadiness,
  refreshMcpReadiness,
  refreshPluginReadiness,
  refreshSkillReadiness
} from "./sync-readiness.js"

/// The reconcile passes shared by two callers: the explicit
/// /v1/sync/<plane>/reconcile routes clients drive, and the mutation hook —
/// any config-changing request (add an MCP, create a skill, enable a
/// harness, install a plugin) triggers the matching pass right after its
/// response, so the change enters the replica and publishes sync.changed
/// within a second instead of waiting for a client's periodic sweep.

export type SyncReconcileNamespace = "skills" | "mcps" | "harnesses" | "plugins" | "credentials"

export interface SyncReconcileOutcome {
  readonly status: unknown
  readonly changedEntries: ReadonlyArray<SyncEntryRecord>
}

/// The participation flag lives in a dot-named namespace the HTTP surface
/// can never serve or gossip; only the dedicated endpoint reads it.
export const PARTICIPATION_NAMESPACE = "local.sync"

export const readParticipation = async (services: CodevisorServerServices): Promise<boolean> => {
  const entries = await run(services.db.getSyncEntries(PARTICIPATION_NAMESPACE))
  return entries.find((entry) => entry.key === "enabled")?.value !== false
}

/// One reconcile pass for a plane; undefined when the backing services are
/// absent on this machine (callers decide whether that is a 501 or a
/// silent skip).
export const reconcileForNamespace = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  namespace: SyncReconcileNamespace
): Promise<SyncReconcileOutcome | undefined> => {
  switch (namespace) {
    case "skills": {
      const blobs = services.syncBlobs
      const skills = services.skills
      if (blobs === undefined || skills === undefined) return undefined
      return reconcileSkills({ db: services.db, skills, blobs, serverId: config.id })
    }
    case "mcps": {
      const mcp = services.mcp
      if (mcp === undefined) return undefined
      return reconcileMcps({
        db: services.db,
        mcp,
        serverId: config.id
      })
    }
    case "harnesses": {
      const lifecycle = services.lifecycle
      const custom = services.customHarnesses
      return reconcileHarnesses({
        db: services.db,
        serverId: config.id,
        listHarnesses: async () => {
          const raw = await run(
            services.db.applyHarnessSettings(await run(services.agents.discoverHarnesses))
          )
          const decorated = await discoverHarnesses(services, false, undefined, true)
          return raw.map((harness) => ({
            id: harness.id,
            name: harness.name,
            symbolName: harness.symbolName,
            source: harness.source,
            enabled: harness.enabled,
            installed: harness.readiness.state === "ready",
            // Mirrors the PATCH enable gate: without an auth service there
            // is nothing to gate on; with one, signed-in or auth-free only.
            authenticated:
              services.auth === undefined ||
              decorated.find((item) => item.id === harness.id)?.auth?.state === "authenticated" ||
              decorated.find((item) => item.id === harness.id)?.auth?.state === "notRequired",
            phase: decorated.find((item) => item.id === harness.id)?.lifecycle?.phase
          }))
        },
        setEnabled: (harnessId, enabled) => run(services.db.setHarnessEnabled(harnessId, enabled)),
        beginInstall: async (harnessId) => {
          if (lifecycle === undefined) {
            throw new Error("Harness install unavailable on this machine")
          }
          await lifecycle.beginInstall(harnessId)
        },
        beginUninstall: async (harnessId) => {
          if (lifecycle === undefined) throw new Error("Uninstall unavailable on this machine")
          await lifecycle.beginUninstall(harnessId)
        },
        listCustomSpecs: async () => (custom === undefined ? [] : await custom.list()),
        replaceCustomSpecs: async (specs) => {
          if (custom !== undefined) await custom.replace(specs)
        }
      })
    }
    case "credentials": {
      await services.sharedAccounts?.reconcile()
      if (services.credentialFerry === undefined) return undefined
      // Ferried content landing locally forces an auth probe; the account
      // state change then republishes the roster via the auth bridge.
      const harnessFor: Record<string, string> = {
        "pi-auth": "pi",
        "opencode-auth": "opencode",
        "codex-auth-file": "codex"
      }
      return reconcileCredentials({
        db: services.db,
        serverId: config.id,
        sources: services.credentialFerry,
        profileSources: services.auth?.sharedOpenCodeProfiles,
        onApplied: (sourceId: string) => {
          const harnessId = sourceId.startsWith("opencode-profile:")
            ? "opencode"
            : harnessFor[sourceId]
          if (harnessId !== undefined) void services.auth?.refresh(harnessId).catch(swallowError)
        }
      })
    }
    case "plugins": {
      const manager = services.plugins
      if (manager === undefined) return undefined
      return reconcilePlugins({
        db: services.db,
        serverId: config.id,
        listPlugins: async () =>
          (await manager.list()).plugins.map((summary) => {
            const origin = summary.source === "managed" ? pluginSyncOrigin(summary.path) : undefined
            return {
              id: summary.id,
              enabled: summary.enabled,
              ...(origin === undefined ? {} : { origin })
            }
          }),
        installFromSource: async (source) => {
          await manager.importRemote({ source })
        },
        setEnabled: async (pluginId, enabled) => {
          await manager.setEnabled(pluginId, enabled)
        },
        removePlugin: async (pluginId) => {
          await manager.remove(pluginId)
        }
      })
    }
  }
}

const WIRE_NAMESPACES: Record<SyncReconcileNamespace, string> = {
  skills: SKILLS_SYNC_NAMESPACE,
  mcps: MCPS_SYNC_NAMESPACE,
  harnesses: HARNESSES_SYNC_NAMESPACE,
  plugins: PLUGINS_SYNC_NAMESPACE,
  credentials: CREDENTIALS_SYNC_NAMESPACE
}

export const publishSyncChanged = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  namespace: SyncReconcileNamespace,
  changedEntries: ReadonlyArray<SyncEntryRecord>
): void => {
  if (changedEntries.length === 0) return
  const wire = WIRE_NAMESPACES[namespace]
  void appendAndPublish(services.db, fanout, "sync.changed", wire, {
    namespace: wire,
    entries: changedEntries
  }).catch(swallowError)
}

/// The mutation hook's half: run the pass and publish, silently skipping
/// machines that opted out of sync or lack the backing services. Never
/// throws — a failed background pass must not affect the request that
/// triggered it.
export const runBackgroundSyncReconcile = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  namespace: SyncReconcileNamespace
): Promise<void> => {
  try {
    if (!(await readParticipation(services))) return
    const result = await reconcileForNamespace(services, config, namespace)
    if (result === undefined) return
    publishSyncChanged(services, fanout, namespace, result.changedEntries)
    if (namespace === "mcps") await refreshMcpReadiness(services, config, fanout)
    if (namespace === "skills") {
      await refreshSkillReadiness(
        services,
        config,
        fanout,
        (result.status as SkillsSyncStatus).missingBlobs
      )
    }
    if (namespace === "harnesses") {
      await refreshHarnessReadiness(
        services,
        config,
        fanout,
        (result.status as HarnessSyncStatus).blocked
      )
    }
    if (namespace === "plugins") {
      await refreshPluginReadiness(
        services,
        config,
        fanout,
        (result.status as PluginSyncStatus).blocked
      )
    }
    // Auth mutations ride the harnesses trigger; the credential ferry
    // re-hashes its files on the same beat (cheap when nothing changed).
    if (namespace === "harnesses") {
      const credentials = await reconcileForNamespace(services, config, "credentials")
      if (credentials !== undefined) {
        publishSyncChanged(services, fanout, "credentials", credentials.changedEntries)
      }
    }
  } catch {
    // Best-effort by design; the periodic client sweep remains the backstop.
  }
}

/// Maps a request to the plane its success would have mutated; undefined
/// for reads and for surfaces too chatty to reconcile behind (plugin pane
/// proxies, pane tokens, tool invocations).
export const configMutationNamespace = (
  method: string | undefined,
  pathname: string
): SyncReconcileNamespace | undefined => {
  if (method === undefined || method === "GET" || method === "HEAD" || method === "OPTIONS") {
    return undefined
  }
  if (pathname.startsWith("/v1/mcps") || pathname.startsWith("/v1/native-mcps")) return "mcps"
  if (pathname.startsWith("/v1/skills")) return "skills"
  if (pathname.startsWith("/v1/harnesses")) return "harnesses"
  if (pathname.startsWith("/v1/plugins")) {
    if (
      pathname.includes("/app/") ||
      pathname.includes("/panes/") ||
      pathname.includes("/tools/")
    ) {
      return undefined
    }
    return "plugins"
  }
  return undefined
}
