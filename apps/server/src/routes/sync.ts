import type { IncomingMessage, ServerResponse } from "node:http"

import { PutSyncRequest as PutSyncRequestSchema } from "@codevisor/api"
import { isValidBlobId, isValidSyncNamespace } from "@codevisor/sync"
import type { BlobStore, SyncEntryRecord, SyncMergeResult } from "@codevisor/sync"

import { ACCOUNTS_SYNC_NAMESPACE, publishAccountsRoster } from "../infra/config-sync.js"
import type { AccountsRosterDeps } from "../infra/config-sync.js"
import { MCP_OVERLAYS_NAMESPACE } from "../infra/mcp-fleet.js"
import { harnessesSignedInBy, SHARED_ACCOUNTS_NAMESPACE } from "../infra/shared-account-store.js"
import { verifySkillArchive } from "../infra/skills-sync.js"
import {
  appendAndPublish,
  HttpFailure,
  readSchema,
  run,
  swallowError,
  writeJson,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { isRoute, rejectSyncThrows, whenMethod } from "./route-context.js"
import type { RouteContext } from "./route-context.js"
import { refreshHarnessReadiness, refreshMcpReadiness } from "./sync-readiness.js"
import {
  publishSyncChanged,
  reconcileForNamespace,
  type SyncReconcileNamespace
} from "./sync-reconcilers.js"

export const routeSync = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  config: CodevisorServerConfig,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> =>
  rejectSyncThrows(() =>
    dispatchSyncRoute({ services, fanout, routeState, request, response, url, config })
  )

interface RosterPublish {
  readonly changedEntries: ReadonlyArray<SyncEntryRecord>
}

const RECONCILE_ROUTES: Record<string, SyncReconcileNamespace> = {
  "/v1/sync/skills/reconcile": "skills",
  "/v1/sync/mcps/reconcile": "mcps",
  "/v1/sync/harnesses/reconcile": "harnesses",
  "/v1/sync/plugins/reconcile": "plugins",
  "/v1/sync/credentials/reconcile": "credentials"
}

const RECONCILE_UNAVAILABLE: Record<SyncReconcileNamespace, string> = {
  skills: "Skills sync unavailable",
  mcps: "MCP sync unavailable",
  harnesses: "Harness sync unavailable",
  plugins: "Plugin sync unavailable",
  credentials: "Credential sync unavailable"
}

const blobPath = /^\/v1\/sync\/blobs\/([^/]+)$/

const namespacePath = /^\/v1\/sync\/([^/]+)$/

const dispatchSyncRoute = (route: RouteContext): Promise<boolean> => {
  const { request, url } = route
  const blobMatch = blobPath.exec(url.pathname)
  if (blobMatch !== null) return routeBlob(route, blobMatch)

  const plane = whenMethod(request, "POST", RECONCILE_ROUTES[url.pathname])
  if (plane !== undefined) return reconcileSyncPlane(route, plane)

  if (isRoute(url, request, "/v1/sync/accounts/publish", "POST")) return publishAccounts(route)

  const namespaceMatch = namespacePath.exec(url.pathname)
  if (namespaceMatch === null) return Promise.resolve(false)
  return routeNamespace(route, String(namespaceMatch[1]))
}

const routeBlob = (route: RouteContext, blobMatch: RegExpExecArray): Promise<boolean> => {
  const blobs = route.services.syncBlobs
  if (blobs === undefined) throw new HttpFailure(501, "Sync blob storage unavailable")

  const id = String(blobMatch[1])
  if (!isValidBlobId(id)) throw new HttpFailure(400, "Invalid blob id")

  if (route.request.method === "GET") return readBlob(route, blobs, id)
  if (route.request.method === "PUT") return writeBlob(route, blobs, id)
  throw new HttpFailure(405, "Method not allowed")
}

const readBlob = async (
  { response }: RouteContext,
  blobs: BlobStore,
  id: string
): Promise<boolean> => {
  if (!blobs.has(id)) throw new HttpFailure(404, "Blob not found")

  response.writeHead(200, { "content-type": "application/gzip" })
  response.end(await blobs.read(id))
  return true
}

const writeBlob = async (
  { request, response }: RouteContext,
  blobs: BlobStore,
  id: string
): Promise<boolean> => {
  const bytes = await readRawBody(request)
  if (!(await verifySkillArchive(id, bytes))) {
    throw new HttpFailure(400, "Archive contents do not match the blob id")
  }

  blobs.write(id, bytes)
  writeJson(response, 200, { stored: true })
  return true
}

const reconcileSyncPlane = async (
  { services, fanout, response, config }: RouteContext,
  plane: SyncReconcileNamespace
): Promise<boolean> => {
  const result = await reconcileForNamespace(services, config, plane)
  if (result === undefined) throw new HttpFailure(501, RECONCILE_UNAVAILABLE[plane])

  publishSyncChanged(services, fanout, plane, result.changedEntries)
  await result.refreshReadiness?.(fanout)
  writeJson(response, 200, result.status)
  return true
}

const publishAccounts = async (route: RouteContext): Promise<boolean> => {
  const result = await publishAccountsRoster(rosterDeps(route))
  if (rosterChanged(result)) publishRosterChanged(route, result)

  writeJson(route.response, 200, { published: rosterChanged(result) })
  return true
}

const routeNamespace = (route: RouteContext, namespace: string): Promise<boolean> => {
  if (!isValidSyncNamespace(namespace)) throw new HttpFailure(400, "Invalid sync namespace")

  if (route.request.method === "GET") return readNamespace(route, namespace)
  if (route.request.method === "PUT") return mergeNamespace(route, namespace)
  throw new HttpFailure(405, "Method not allowed")
}

const readNamespace = async (
  { services, response }: RouteContext,
  namespace: string
): Promise<boolean> => {
  const entries = await run(services.db.getSyncEntries(namespace))
  writeJson(response, 200, { namespace, entries })
  return true
}

const mergeNamespace = async (route: RouteContext, namespace: string): Promise<boolean> => {
  const { services, fanout, request, response, config } = route
  const body = await readSchema(request, PutSyncRequestSchema)
  const result = await run(services.db.mergeSyncEntries(namespace, body.entries))

  if (namespace === SHARED_ACCOUNTS_NAMESPACE) {
    await services.sharedAccounts?.reconcileRemote()
    refreshSignedInHarnesses(route, result)
  }

  if (result.changed.length > 0) {
    publishNamespaceChanged(route, namespace, result)
    if (namespace === MCP_OVERLAYS_NAMESPACE) await refreshMcpReadiness(services, config, fanout)
  }

  writeJson(response, 200, { namespace, entries: result.merged })
  return true
}

const rosterDeps = ({ services, config }: RouteContext): AccountsRosterDeps => ({
  db: services.db,
  harnessIds: services.agents.catalog.map((definition) => definition.id),
  serverId: config.id
})

const rosterChanged = (result: RosterPublish): boolean => result.changedEntries.length > 0

const publishRosterChanged = ({ services, fanout }: RouteContext, result: RosterPublish): void => {
  void appendAndPublish(services.db, fanout, "sync.changed", ACCOUNTS_SYNC_NAMESPACE, {
    namespace: ACCOUNTS_SYNC_NAMESPACE,
    entries: result.changedEntries
  }).catch(swallowError)
}

const refreshSignedInHarnesses = (route: RouteContext, result: SyncMergeResult): void => {
  const signedIn = harnessesSignedInBy(result.changed)
  if (signedIn.length > 0) refreshHarnessAuth(route, signedIn, result)
}

const refreshHarnessAuth = (
  { services, fanout, config }: RouteContext,
  harnessIds: ReadonlyArray<string>,
  result: SyncMergeResult
): void => {
  void Promise.allSettled(harnessIds.map(async (harnessId) => services.auth?.refresh(harnessId)))
    .then(() => refreshHarnessReadiness(services, config, fanout, [], result.changed))
    .catch(swallowError)
}

const publishNamespaceChanged = (
  { services, fanout }: RouteContext,
  namespace: string,
  result: SyncMergeResult
): void => {
  void appendAndPublish(services.db, fanout, "sync.changed", namespace, {
    namespace,
    entries: result.changed
  }).catch(swallowError)
}

const readRawBody = async (request: IncomingMessage): Promise<Buffer> => {
  const chunks: Array<Buffer> = []
  for await (const chunk of request) {
    /* v8 ignore next */
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk))
  }
  return Buffer.concat(chunks)
}
