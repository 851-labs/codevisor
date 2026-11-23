import type { Harness } from "@codevisor/api"
import type { McpManager } from "@codevisor/mcp"
import type { SyncEntryRecord } from "@codevisor/sync"

import {
  ACCOUNTS_SYNC_NAMESPACE,
  HARNESS_READINESS_NAMESPACE,
  publishAccountsRoster,
  publishMachineReadiness,
  type HarnessReadinessRow
} from "../infra/config-sync.js"
import type { HarnessSyncStatus } from "../infra/harness-sync.js"
import {
  MCP_READINESS_NAMESPACE,
  publishMcpReadiness,
  readMcpOverlays
} from "../infra/mcp-fleet.js"
import {
  appendAndPublish,
  swallowError,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { discoverHarnessesFromStoredAuthState } from "./harnesses.js"

const publishReadinessChanges = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  namespace: string,
  result: { readonly changedEntries: ReadonlyArray<SyncEntryRecord> }
): void => {
  if (result.changedEntries.length > 0) {
    void appendAndPublish(services.db, fanout, "sync.changed", namespace, {
      namespace,
      entries: result.changedEntries
    }).catch(swallowError)
  }
}

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
    publishReadinessChanges(services, fanout, ACCOUNTS_SYNC_NAMESPACE, result)
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
    await republishMcpReadiness(services, config, fanout, mcp)
  } catch {}
}

export const publishMcpChanges = (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  mcp: McpManager
): (() => void) => {
  const readiness = makeRefreshScheduler(() => republishMcpReadiness(services, config, fanout, mcp))
  const unsubscribe = mcp.subscribeServersChanged((id) => {
    void appendAndPublish(services.db, fanout, "mcp.updated", id, { id }).catch(swallowError)
    readiness.request()
  })
  return () => {
    unsubscribe()
    readiness.close()
  }
}

const republishMcpReadiness = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  mcp: McpManager
): Promise<void> => {
  try {
    const result = await publishMcpReadiness({ db: services.db, mcp, serverId: config.id })
    publishReadinessChanges(services, fanout, MCP_READINESS_NAMESPACE, result)
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
    const refusals = new Map(blocked.map(({ id, reason }) => [id, reason]))
    const harnesses = await discoverHarnessesFromStoredAuthState(services)
    const rows = await Promise.all(
      harnesses.map((harness) => readinessRow(services, harness, refusals.get(harness.id)))
    )
    const result = await publishMachineReadiness({
      db: services.db,
      namespace: HARNESS_READINESS_NAMESPACE,
      serverId: config.id,
      value: { harnesses: rows.toSorted((a, b) => a.id.localeCompare(b.id)) },
      ...(answers === undefined ? {} : { answers })
    })
    publishReadinessChanges(services, fanout, HARNESS_READINESS_NAMESPACE, result)
  } catch {}
}

export const canUninstall = async (
  services: CodevisorServerServices,
  harness: Harness
): Promise<boolean> => {
  if (harness.readiness.state !== "ready" || services.lifecycle === undefined) return false
  try {
    return await services.lifecycle.canUninstall(harness)
  } catch {
    return false
  }
}

const readinessRow = async (
  services: CodevisorServerServices,
  harness: Harness,
  refusal: string | undefined
): Promise<HarnessReadinessRow> => {
  const installed = harness.readiness.state === "ready"
  const state = readinessState(services, harness, refusal)
  const reason = readinessReason(harness, state, refusal)
  const version = installed ? harness.readiness.version : undefined
  return {
    id: harness.id,
    name: harness.name,
    symbolName: harness.symbolName,
    state,
    installed,
    authRequired: harness.auth?.state !== "notRequired",
    needsSignIn: needsSignIn(services, harness),
    canUninstall: await canUninstall(services, harness),
    ...(reason ? { reason } : {}),
    ...(version ? { version } : {})
  }
}

const readinessState = (
  services: CodevisorServerServices,
  harness: Harness,
  refusal: string | undefined
): HarnessReadinessRow["state"] => {
  const phase = harness.lifecycle?.phase
  if (phase === "failed" || isRealRefusal(refusal)) return "blocked"
  if (phase === "installing" || phase === "uninstalling") return phase
  if (!wantsEnabled(harness)) return "disabled"
  if (harness.readiness.state !== "ready") return "notInstalled"
  if (isAuthed(services, harness)) return "ready"
  return "signInRequired"
}

const readinessReason = (
  harness: Harness,
  state: HarnessReadinessRow["state"],
  refusal: string | undefined
): string | undefined => {
  if (state === "blocked") return refusal ?? harness.lifecycle?.error
  if (state === "notInstalled") return harness.readiness.detail
  if (state === "signInRequired" && authUnreadable(harness)) return harness.auth?.detail
  return undefined
}

const needsSignIn = (services: CodevisorServerServices, harness: Harness): boolean =>
  wantsEnabled(harness) && harness.readiness.state === "ready" && !isAuthed(services, harness)

const isRealRefusal = (refusal: string | undefined): boolean =>
  refusal !== undefined && refusal !== "Sign in required"

const wantsEnabled = (harness: Harness): boolean => harness.desiredEnabled ?? harness.enabled

const isAuthed = (services: CodevisorServerServices, harness: Harness): boolean =>
  services.auth === undefined ||
  harness.auth?.state === "authenticated" ||
  harness.auth?.state === "notRequired"

const authUnreadable = (harness: Harness): boolean =>
  harness.auth?.state === "error" || harness.auth?.state === "unavailable"

export interface RefreshScheduler {
  readonly request: () => void
  readonly close: () => void
}

export const makeAuthSyncRefreshScheduler = (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout
): RefreshScheduler =>
  makeRefreshScheduler(async () => {
    await Promise.all([
      republishAccountsRoster(services, config, fanout),
      refreshHarnessReadiness(services, config, fanout)
    ])
  })

const makeRefreshScheduler = (refresh: () => Promise<void>): RefreshScheduler => {
  let requested = false
  let closed = false
  let running: Promise<void> | undefined

  const drain = async (): Promise<void> => {
    // oxlint-disable-next-line no-unmodified-loop-condition
    while (!closed && requested) {
      requested = false
      await refresh()
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
