import type { PluginsManager } from "@codevisor/plugins"
import type { SkillsManager } from "@codevisor/skills"

import {
  ACCOUNTS_SYNC_NAMESPACE,
  HARNESS_READINESS_NAMESPACE,
  PLUGIN_READINESS_NAMESPACE,
  publishAccountsRoster,
  publishMachineReadiness,
  type HarnessReadinessRow,
  type PluginReadinessRow
} from "../infra/config-sync.js"
import type { HarnessSyncStatus } from "../infra/harness-sync.js"
import {
  MCP_READINESS_NAMESPACE,
  publishMcpReadiness,
  readMcpOverlays
} from "../infra/mcp-fleet.js"
import { pluginSyncOrigin, PLUGINS_SYNC_NAMESPACE } from "../infra/plugin-sync.js"
import { publishSkillReadiness, SKILL_READINESS_NAMESPACE } from "../infra/skills-fleet.js"
import type { SkillsSyncStatus } from "../infra/skills-sync.js"
import {
  appendAndPublish,
  run,
  swallowError,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { discoverHarnessesFromStoredAuthState } from "./harnesses.js"

/// The REPORTED half of every config plane: each machine publishes one
/// single-writer entry per plane saying what it actually looks like there.
/// Split out of sync-reconcilers so the pass logic and the reporting stay
/// separately readable; both are driven from the same triggers.

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
  fanout: EventFanout,
  blocked: HarnessSyncStatus["blocked"] = []
): Promise<void> => {
  try {
    const blockedById = new Map(blocked.map(({ id, reason }) => [id, reason]))
    const rows: HarnessReadinessRow[] = (await discoverHarnessesFromStoredAuthState(services)).map(
      (harness) => {
        const authed =
          services.auth === undefined ||
          harness.auth?.state === "authenticated" ||
          harness.auth?.state === "notRequired"
        const installed = harness.readiness.state === "ready"
        const desired = harness.desiredEnabled ?? harness.enabled
        const phase = harness.lifecycle?.phase
        const refusal = blockedById.get(harness.id)
        const state: HarnessReadinessRow["state"] =
          phase === "failed" || (refusal !== undefined && refusal !== "Sign in required")
            ? "blocked"
            : phase === "installing" || phase === "uninstalling"
              ? phase
              : !desired
                ? "disabled"
                : !installed
                  ? "notInstalled"
                  : authed
                    ? "ready"
                    : "signInRequired"
        const reason =
          state === "blocked"
            ? (refusal ?? harness.lifecycle?.error)
            : state === "notInstalled"
              ? harness.readiness.detail
              : undefined
        return {
          id: harness.id,
          state,
          installed,
          ...(reason ? { reason } : {})
        }
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

/// Re-derives and publishes this machine's skill readiness entry after a
/// skills pass. `missingBlobs` carries the just-finished pass's stranded
/// entries so "waiting for another machine to send this" survives as the
/// row's reason. Change-detected and best-effort like the other three.
export const refreshSkillReadiness = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  skills: SkillsManager,
  missingBlobs: SkillsSyncStatus["missingBlobs"]
): Promise<void> => {
  try {
    const result = await publishSkillReadiness({
      db: services.db,
      skills,
      serverId: config.id,
      missingBlobs: missingBlobs.map((entry) => entry.directoryName)
    })
    if (result.changedEntries.length > 0) {
      void appendAndPublish(services.db, fanout, "sync.changed", SKILL_READINESS_NAMESPACE, {
        namespace: SKILL_READINESS_NAMESPACE,
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
/// pass's refusals so "needs ffmpeg" survives as the row's reason.
export const refreshPluginReadiness = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  manager: PluginsManager,
  blocked: ReadonlyArray<{ readonly id: string; readonly reason: string }>
): Promise<void> => {
  try {
    const blockedById = new Map(blocked.map((entry) => [entry.id, entry.reason]))
    const local = (await manager.list()).plugins
    const localIds = new Set(local.map((summary) => summary.id))
    const rows: PluginReadinessRow[] = local.map((summary) => {
      const machineOnly =
        summary.source !== "managed" || pluginSyncOrigin(summary.path) === undefined
      // A plugin whose process died is the one per-machine condition the
      // fleet list cannot infer from the definition. Reporting it as blocked
      // is what lets the list drop the per-machine pages entirely.
      if (summary.enabled && summary.state === "failed") {
        return {
          id: summary.id,
          state: "blocked",
          reason: "The plugin stopped running on this machine. Restart it to try again."
        }
      }
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
