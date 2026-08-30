import type { SyncEntryRecord } from "@codevisor/sync"
import {
  ACCOUNTS_SYNC_NAMESPACE,
  HARNESS_READINESS_NAMESPACE,
  MCPS_SYNC_NAMESPACE,
  PLUGIN_READINESS_NAMESPACE,
  publishAccountsRoster,
  publishMachineReadiness,
  reconcileMcps,
  type HarnessReadinessRow,
  type PluginReadinessRow
} from "../infra/config-sync.js"
import { CREDENTIALS_SYNC_NAMESPACE, reconcileCredentials } from "../infra/credential-sync.js"
import {
  MCP_READINESS_NAMESPACE,
  publishMcpReadiness,
  readMcpOverlays
} from "../infra/mcp-fleet.js"
import { HARNESSES_SYNC_NAMESPACE, reconcileHarnesses } from "../infra/harness-sync.js"
import { PLUGINS_SYNC_NAMESPACE, pluginSyncOrigin, reconcilePlugins } from "../infra/plugin-sync.js"
import type { PluginSyncStatus } from "../infra/plugin-sync.js"
import { reconcileSkills, SKILLS_SYNC_NAMESPACE } from "../infra/skills-sync.js"
import {
  appendAndPublish,
  run,
  swallowError,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { discoverHarnesses, discoverHarnessesFromStoredAuthState } from "./harnesses.js"

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
        listHarnesses: async () =>
          (await discoverHarnesses(services)).map((harness) => ({
            id: harness.id,
            enabled: harness.enabled,
            installed: harness.readiness.state === "ready",
            // Mirrors the PATCH enable gate: without an auth service there
            // is nothing to gate on; with one, signed-in or auth-free only.
            authenticated:
              services.auth === undefined ||
              harness.auth?.state === "authenticated" ||
              harness.auth?.state === "notRequired"
          })),
        setEnabled: (harnessId, enabled) => run(services.db.setHarnessEnabled(harnessId, enabled)),
        beginInstall: async (harnessId) => {
          if (lifecycle === undefined) {
            throw new Error("Harness install unavailable on this machine")
          }
          await lifecycle.beginInstall(harnessId)
        },
        listCustomSpecs: async () => (custom === undefined ? [] : await custom.list()),
        replaceCustomSpecs: async (specs) => {
          if (custom !== undefined) await custom.replace(specs)
        }
      })
    }
    case "credentials": {
      const sources = services.credentialFerry
      if (sources === undefined) return undefined
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
        sources,
        onApplied: (sourceId: string) => {
          const harnessId = harnessFor[sourceId]
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

/// Republishes this machine's harness-account roster (Phase 19). Wired to
/// the auth manager's event stream, so a session that dies of auth — or any
/// probe flipping an account's state — becomes fleet-visible within the
/// gossip round instead of waiting for a client's periodic publish sweep.
/// Change-detected and best-effort like the readiness refresh.
export const republishAccountsRoster = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout
): Promise<void> => {
  try {
    const result = await publishAccountsRoster({
      db: services.db,
      harnessIds: services.agents.catalog.map((definition) => definition.id),
      serverId: config.id
    })
    if (result.changedEntries.length > 0) {
      void appendAndPublish(services.db, fanout, "sync.changed", ACCOUNTS_SYNC_NAMESPACE, {
        namespace: ACCOUNTS_SYNC_NAMESPACE,
        entries: result.changedEntries
      }).catch(swallowError)
    }
  } catch {
    // Best-effort by design; the next client publish sweep is the backstop.
  }
}

/// Re-derives and publishes this machine's MCP readiness entry after an
/// mcps pass (reconciles change connection state and overlays change what
/// counts as suppressed). Change-detected and best-effort: a settled
/// machine publishes nothing, and a failure never affects the pass that
/// triggered it.
export const refreshMcpReadiness = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout
): Promise<void> => {
  const mcp = services.mcp
  if (mcp === undefined) return
  try {
    // Enforcement first, then the report: suppressed servers drop out of
    // session resolution and lose live connections before readiness is
    // derived, so the published entry reflects the enforced state.
    const overlays = await readMcpOverlays(services.db, config.id)
    await mcp.setLocalSuppression(overlays.disabledHere)
    const result = await publishMcpReadiness({ db: services.db, mcp, serverId: config.id })
    if (result.changedEntries.length > 0) {
      void appendAndPublish(services.db, fanout, "sync.changed", MCP_READINESS_NAMESPACE, {
        namespace: MCP_READINESS_NAMESPACE,
        entries: result.changedEntries
      }).catch(swallowError)
    }
  } catch {
    // Best-effort by design; the next pass republishes.
  }
}

/// Re-derives and publishes this machine's harness readiness entry after a
/// harnesses pass or an auth change — the reported side of Phase 24's
/// desired-vs-reported matrix. Change-detected and best-effort like the
/// MCP readiness refresh.
export const refreshHarnessReadiness = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout
): Promise<void> => {
  try {
    const rows: HarnessReadinessRow[] = (await discoverHarnessesFromStoredAuthState(services)).map(
      (harness) => {
        const authed =
          services.auth === undefined ||
          harness.auth?.state === "authenticated" ||
          harness.auth?.state === "notRequired"
        const installed = harness.readiness.state === "ready"
        const desired = harness.desiredEnabled ?? harness.enabled
        const state: HarnessReadinessRow["state"] = !desired
          ? "disabled"
          : !installed
            ? "notInstalled"
            : authed
              ? "ready"
              : "signInRequired"
        const reason = state === "notInstalled" ? harness.readiness.detail : undefined
        return { id: harness.id, state, ...(reason ? { reason } : {}) }
      }
    )
    const result = await publishMachineReadiness({
      db: services.db,
      namespace: HARNESS_READINESS_NAMESPACE,
      serverId: config.id,
      value: { harnesses: rows.toSorted((a, b) => a.id.localeCompare(b.id)) }
    })
    if (result.changedEntries.length > 0) {
      void appendAndPublish(services.db, fanout, "sync.changed", HARNESS_READINESS_NAMESPACE, {
        namespace: HARNESS_READINESS_NAMESPACE,
        entries: result.changedEntries
      }).catch(swallowError)
    }
  } catch {
    // Best-effort by design; the next pass republishes.
  }
}

export interface AuthSyncRefreshScheduler {
  readonly request: () => void
  readonly close: () => void
}

/// Account updates can arrive in large bursts. Run at most one roster/readiness
/// refresh at a time and collapse every burst during that run into one trailing
/// refresh, so event delivery cannot create unbounded background work.
export const makeAuthSyncRefreshScheduler = (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout
): AuthSyncRefreshScheduler => {
  let requested = false
  let closed = false
  let running: Promise<void> | undefined

  const drain = async (): Promise<void> => {
    while (!closed && requested) {
      requested = false
      await Promise.all([
        republishAccountsRoster(services, config, fanout),
        refreshHarnessReadiness(services, config, fanout)
      ])
    }
  }

  const request = (): void => {
    if (closed) return
    requested = true
    if (running !== undefined) return
    // The microtask boundary collapses a synchronous event burst before the
    // first refresh starts. Events received during I/O request one trailing run.
    running = Promise.resolve()
      .then(drain)
      .catch(swallowError)
      .finally(() => {
        running = undefined
      })
  }

  return {
    request,
    close: () => {
      closed = true
      requested = false
    }
  }
}

/// Re-derives and publishes this machine's plugin readiness entry (Phase
/// 24, third readiness instance). `blocked` carries the just-finished
/// pass's refusals so "needs ffmpeg" survives as the row's reason; the
/// on-demand publish has no pass and reports the static picture.
export const refreshPluginReadiness = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  blocked: ReadonlyArray<{ readonly id: string; readonly reason: string }> = []
): Promise<void> => {
  const manager = services.plugins
  if (manager === undefined) return
  try {
    const blockedById = new Map(blocked.map((entry) => [entry.id, entry.reason]))
    const local = (await manager.list()).plugins
    const localIds = new Set(local.map((summary) => summary.id))
    const rows: PluginReadinessRow[] = local.map((summary) => {
      const machineOnly =
        summary.source !== "managed" || pluginSyncOrigin(summary.path) === undefined
      const state: PluginReadinessRow["state"] = machineOnly
        ? "machineOnly"
        : summary.enabled
          ? "ready"
          : "disabled"
      return { id: summary.id, state }
    })
    // Fleet-desired plugins this machine doesn't have yet — blocked passes
    // explain themselves, everything else is simply not installed yet.
    const desired = await run(services.db.getSyncEntries(PLUGINS_SYNC_NAMESPACE))
    for (const entry of desired) {
      if (entry.deleted === true || localIds.has(entry.key)) continue
      const reason = blockedById.get(entry.key)
      rows.push({
        id: entry.key,
        state: reason === undefined ? "notInstalled" : "blocked",
        ...(reason === undefined ? {} : { reason })
      })
    }
    const result = await publishMachineReadiness({
      db: services.db,
      namespace: PLUGIN_READINESS_NAMESPACE,
      serverId: config.id,
      value: { plugins: rows.toSorted((a, b) => a.id.localeCompare(b.id)) }
    })
    if (result.changedEntries.length > 0) {
      void appendAndPublish(services.db, fanout, "sync.changed", PLUGIN_READINESS_NAMESPACE, {
        namespace: PLUGIN_READINESS_NAMESPACE,
        entries: result.changedEntries
      }).catch(swallowError)
    }
  } catch {
    // Best-effort by design; the next pass republishes.
  }
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
    if (namespace === "harnesses") await refreshHarnessReadiness(services, config, fanout)
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
