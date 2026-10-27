import type { Harness } from "@codevisor/api"
import type { SyncEntryRecord } from "@codevisor/sync"

import { MCPS_SYNC_NAMESPACE, reconcileMcps } from "../infra/config-sync.js"
import { CREDENTIALS_SYNC_NAMESPACE, reconcileCredentials } from "../infra/credential-sync.js"
import {
  HARNESSES_SYNC_NAMESPACE,
  reconcileHarnesses,
  type LocalHarnessState
} from "../infra/harness-sync.js"
import { reconcileSkills, SKILLS_SYNC_NAMESPACE } from "../infra/skills-sync.js"
import {
  appendAndPublish,
  run,
  swallowError,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { discoverHarnesses } from "./harnesses.js"
import { refreshHarnessReadiness, refreshMcpReadiness } from "./sync-readiness.js"

export type SyncReconcileNamespace = "skills" | "mcps" | "harnesses" | "credentials"

export interface SyncReconcileOutcome {
  readonly status: unknown
  readonly changedEntries: ReadonlyArray<SyncEntryRecord>
  readonly refreshReadiness?: (fanout: EventFanout) => Promise<void>
}

export const reconcileForNamespace = (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  namespace: SyncReconcileNamespace
): Promise<SyncReconcileOutcome | undefined> => {
  switch (namespace) {
    case "skills":
      return reconcileSkillsPlane(services, config)
    case "mcps":
      return reconcileMcpsPlane(services, config)
    case "harnesses":
      return reconcileHarnessesPlane(services, config)
    default:
      return reconcileCredentialsPlane(services, config)
  }
}

export const publishSyncChanged = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  namespace: SyncReconcileNamespace,
  changedEntries: ReadonlyArray<SyncEntryRecord>
): void => {
  publishSyncEntries(services, fanout, WIRE_NAMESPACES[namespace], changedEntries)
}

export const publishSyncEntries = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  wire: string,
  changedEntries: ReadonlyArray<SyncEntryRecord>
): void => {
  if (changedEntries.length === 0) return

  void appendAndPublish(services.db, fanout, "sync.changed", wire, {
    namespace: wire,
    entries: changedEntries
  }).catch(swallowError)
}

export const runBackgroundSyncReconcile = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  namespace: SyncReconcileNamespace
): Promise<void> => {
  try {
    const result = await reconcileForNamespace(services, config, namespace)
    if (result === undefined) return

    publishSyncChanged(services, fanout, namespace, result.changedEntries)
    await result.refreshReadiness?.(fanout)
    if (namespace !== "harnesses") return

    const credentials = await reconcileForNamespace(services, config, "credentials")
    if (credentials === undefined) return

    publishSyncChanged(services, fanout, "credentials", credentials.changedEntries)
  } catch {}
}

export const configMutationNamespace = (
  method: string | undefined,
  pathname: string
): SyncReconcileNamespace | undefined => {
  if (isReadOnlyMethod(method)) return undefined
  if (isMcpConfigPath(pathname)) return "mcps"
  if (pathname.startsWith("/v1/skills")) return "skills"
  if (pathname.startsWith("/v1/harnesses")) return "harnesses"
  return undefined
}

const reconcileSkillsPlane = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig
): Promise<SyncReconcileOutcome | undefined> => {
  const blobs = services.syncBlobs
  const skills = services.skills
  if (blobs === undefined || skills === undefined) return undefined

  return reconcileSkills({ db: services.db, store: skills, blobs, serverId: config.id })
}

const reconcileMcpsPlane = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig
): Promise<SyncReconcileOutcome | undefined> => {
  const mcp = services.mcp
  if (mcp === undefined) return undefined

  const outcome = await reconcileMcps({ db: services.db, mcp, serverId: config.id })
  return {
    ...outcome,
    refreshReadiness: (fanout) => refreshMcpReadiness(services, config, fanout)
  }
}

const reconcileHarnessesPlane = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig
): Promise<SyncReconcileOutcome> => {
  const lifecycle = services.lifecycle
  const outcome = await reconcileHarnesses({
    db: services.db,
    serverId: config.id,
    listHarnesses: () => listSyncHarnesses(services),
    setEnabled: (harnessId, enabled) => run(services.db.setHarnessEnabled(harnessId, enabled)),
    beginInstall: async (harnessId) => {
      if (lifecycle === undefined) throw new Error("Harness install unavailable on this machine")
      await lifecycle.beginInstall(harnessId)
    },
    beginUninstall: async (harnessId) => {
      if (lifecycle === undefined) throw new Error("Uninstall unavailable on this machine")
      await lifecycle.beginUninstall(harnessId)
    }
  })
  return {
    ...outcome,
    refreshReadiness: (fanout) =>
      refreshHarnessReadiness(services, config, fanout, outcome.status.blocked)
  }
}

const reconcileCredentialsPlane = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig
): Promise<SyncReconcileOutcome | undefined> => {
  await services.sharedAccounts?.reconcile()
  if (services.credentialFerry === undefined) return undefined

  return reconcileCredentials({
    db: services.db,
    serverId: config.id,
    sources: services.credentialFerry,
    profileSources: services.auth?.sharedOpenCodeProfiles,
    onApplied: (sourceId: string) => refreshCredentialHarness(services, sourceId)
  })
}

const listSyncHarnesses = async (
  services: CodevisorServerServices
): Promise<ReadonlyArray<LocalHarnessState>> => {
  const raw = await run(
    services.db.applyHarnessSettings(await run(services.agents.discoverHarnesses))
  )
  const decorated = await discoverHarnesses(services, false, undefined, true)
  return raw.map((harness) => syncHarnessFor(services, decorated, harness))
}

const syncHarnessFor = (
  services: CodevisorServerServices,
  decorated: ReadonlyArray<Harness>,
  harness: Harness
): LocalHarnessState => ({
  id: harness.id,
  name: harness.name,
  symbolName: harness.symbolName,
  enabled: harness.enabled,
  installed: harness.readiness.state === "ready",
  authenticated: isAuthenticated(services, decorated, harness),
  phase: decoratedHarness(decorated, harness)?.lifecycle?.phase
})

const isAuthenticated = (
  services: CodevisorServerServices,
  decorated: ReadonlyArray<Harness>,
  harness: Harness
): boolean =>
  services.auth === undefined ||
  decoratedHarness(decorated, harness)?.auth?.state === "authenticated" ||
  decoratedHarness(decorated, harness)?.auth?.state === "notRequired"

const decoratedHarness = (
  decorated: ReadonlyArray<Harness>,
  harness: Harness
): Harness | undefined => decorated.find((item) => item.id === harness.id)

const refreshCredentialHarness = (services: CodevisorServerServices, sourceId: string): void => {
  const harnessId = credentialHarnessFor(sourceId)
  if (harnessId !== undefined) void services.auth?.refresh(harnessId).catch(swallowError)
}

const credentialHarnessFor = (sourceId: string): string | undefined => {
  if (sourceId.startsWith("opencode-profile:")) return "opencode"
  return CREDENTIAL_SOURCE_HARNESSES[sourceId]
}

const isReadOnlyMethod = (method: string | undefined): boolean =>
  method === undefined || method === "GET" || method === "HEAD" || method === "OPTIONS"

const isMcpConfigPath = (pathname: string): boolean =>
  pathname.startsWith("/v1/mcps") ||
  pathname.startsWith("/v1/native-mcps") ||
  pathname.startsWith("/v1/plugins/catalog")

const WIRE_NAMESPACES: Record<SyncReconcileNamespace, string> = {
  skills: SKILLS_SYNC_NAMESPACE,
  mcps: MCPS_SYNC_NAMESPACE,
  harnesses: HARNESSES_SYNC_NAMESPACE,
  credentials: CREDENTIALS_SYNC_NAMESPACE
}

const CREDENTIAL_SOURCE_HARNESSES: Record<string, string> = {
  "pi-auth": "pi",
  "opencode-auth": "opencode",
  "codex-auth-file": "codex"
}
