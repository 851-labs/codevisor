import type { PluginsManager } from "@codevisor/plugins"
import type { SyncEntryRecord } from "@codevisor/sync"

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
import {
  appendAndPublish,
  run,
  swallowError,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { discoverHarnessesFromStoredAuthState } from "./harnesses.js"

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
  } catch {}
}

export const refreshMcpReadiness = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout
): Promise<void> => {
  const mcp = services.mcp
  if (mcp === undefined) return
  try {
    const overlays = await readMcpOverlays(services.db, config.id)
    await mcp.setLocalSuppression(overlays.disabledHere)
    const result = await publishMcpReadiness({ db: services.db, mcp, serverId: config.id })
    if (result.changedEntries.length > 0) {
      void appendAndPublish(services.db, fanout, "sync.changed", MCP_READINESS_NAMESPACE, {
        namespace: MCP_READINESS_NAMESPACE,
        entries: result.changedEntries
      }).catch(swallowError)
    }
  } catch {}
}

export const refreshHarnessReadiness = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  blocked: HarnessSyncStatus["blocked"] = [],
  answers?: ReadonlyArray<SyncEntryRecord>
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
        let state: HarnessReadinessRow["state"]
        if (phase === "failed" || (refusal !== undefined && refusal !== "Sign in required")) {
          state = "blocked"
        } else if (phase === "installing" || phase === "uninstalling") {
          state = phase
        } else if (!desired) {
          state = "disabled"
        } else if (!installed) {
          state = "notInstalled"
        } else if (authed) {
          state = "ready"
        } else {
          state = "signInRequired"
        }
        let reason: HarnessReadinessRow["reason"]
        if (state === "blocked") {
          reason = refusal ?? harness.lifecycle?.error
        } else if (state === "notInstalled") {
          reason = harness.readiness.detail
        } else if (
          state === "signInRequired" &&
          (harness.auth?.state === "error" || harness.auth?.state === "unavailable")
        ) {
          reason = harness.auth.detail
        }
        const version = installed ? harness.readiness.version : undefined
        return {
          id: harness.id,
          name: harness.name,
          symbolName: harness.symbolName,
          state,
          installed,
          authRequired: harness.auth?.state !== "notRequired",
          ...(reason ? { reason } : {}),
          ...(version ? { version } : {})
        }
      }
    )
    const result = await publishMachineReadiness({
      db: services.db,
      namespace: HARNESS_READINESS_NAMESPACE,
      serverId: config.id,
      value: { harnesses: rows.toSorted((a, b) => a.id.localeCompare(b.id)) },
      ...(answers === undefined ? {} : { answers })
    })
    if (result.changedEntries.length > 0) {
      void appendAndPublish(services.db, fanout, "sync.changed", HARNESS_READINESS_NAMESPACE, {
        namespace: HARNESS_READINESS_NAMESPACE,
        entries: result.changedEntries
      }).catch(swallowError)
    }
  } catch {}
}

export interface AuthSyncRefreshScheduler {
  readonly request: () => void
  readonly close: () => void
}

export const makeAuthSyncRefreshScheduler = (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout
): AuthSyncRefreshScheduler => {
  let requested = false
  let closed = false
  let running: Promise<void> | undefined

  const drain = async (): Promise<void> => {
    // oxlint-disable-next-line no-unmodified-loop-condition
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
  } catch {}
}
