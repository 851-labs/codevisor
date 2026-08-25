import {
  PutSyncRequest as PutSyncRequestSchema,
  SyncParticipation as SyncParticipationSchema
} from "@codevisor/api"
import {
  isValidBlobId,
  isValidSyncNamespace,
  latestSyncTimestamp,
  nextSyncTimestamp
} from "@codevisor/sync"
import type { IncomingMessage, ServerResponse } from "node:http"
import { ACCOUNTS_SYNC_NAMESPACE, publishAccountsRoster } from "../infra/config-sync.js"
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
  type EventFanout
} from "../server-context.js"
import {
  PARTICIPATION_NAMESPACE,
  publishSyncChanged,
  readParticipation,
  reconcileForNamespace,
  type SyncReconcileNamespace
} from "./sync-reconcilers.js"

const RECONCILE_ROUTES: Record<string, SyncReconcileNamespace> = {
  "/v1/sync/skills/reconcile": "skills",
  "/v1/sync/mcps/reconcile": "mcps",
  "/v1/sync/harnesses/reconcile": "harnesses",
  "/v1/sync/plugins/reconcile": "plugins"
}

const RECONCILE_UNAVAILABLE: Record<SyncReconcileNamespace, string> = {
  skills: "Skills sync unavailable",
  mcps: "MCP sync unavailable",
  harnesses: "Harness sync unavailable",
  plugins: "Plugin sync unavailable"
}

const readRawBody = async (request: IncomingMessage): Promise<Buffer> => {
  const chunks: Array<Buffer> = []
  for await (const chunk of request) {
    /* v8 ignore next -- Node HTTP request body chunks are Buffers in this server. */
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk as string))
  }
  return Buffer.concat(chunks)
}

/// The config plane's endpoints: per-namespace replica documents, the
/// content-addressed blob store clients ferry big payloads through, and
/// the skills reconcile pass. GET/PUT of a namespace merge with
/// last-writer-wins semantics (see @codevisor/sync); the PUT response is
/// the merged document, so one round trip both pushes and pulls. Changes
/// publish `sync.changed` so every connected client adopts them live.
export const routeSync = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  // The machine owner's opt-out: when participation is off, every sync
  // surface refuses — server-enforced, so no client can gossip past it.
  // The flag endpoint itself stays reachable (that is how it turns back
  // on) and lives outside /v1/sync/ so it can never collide with a
  // namespace.
  if (url.pathname === "/v1/sync-participation") {
    if (request.method === "GET") {
      writeJson(response, 200, { enabled: await readParticipation(services) })
      return true
    }
    if (request.method === "PUT") {
      const body = await readSchema(request, SyncParticipationSchema)
      const entries = await run(services.db.getSyncEntries(PARTICIPATION_NAMESPACE))
      await run(
        services.db.mergeSyncEntries(PARTICIPATION_NAMESPACE, [
          {
            key: "enabled",
            value: body.enabled,
            timestamp: nextSyncTimestamp(config.id, latestSyncTimestamp(entries), Date.now())
          }
        ])
      )
      writeJson(response, 200, { enabled: body.enabled })
      return true
    }
    throw new HttpFailure(405, "Method not allowed")
  }
  if (url.pathname.startsWith("/v1/sync/") && !(await readParticipation(services))) {
    throw new HttpFailure(403, "Sync is disabled on this machine")
  }

  const blobMatch = /^\/v1\/sync\/blobs\/([^/]+)$/.exec(url.pathname)
  if (blobMatch !== null) {
    const blobs = services.syncBlobs
    if (blobs === undefined) throw new HttpFailure(501, "Sync blob storage unavailable")
    const id = String(blobMatch[1])
    if (!isValidBlobId(id)) throw new HttpFailure(400, "Invalid blob id")
    if (request.method === "GET") {
      if (!blobs.has(id)) throw new HttpFailure(404, "Blob not found")
      response.writeHead(200, { "content-type": "application/gzip" })
      response.end(await blobs.read(id))
      return true
    }
    if (request.method === "PUT") {
      const bytes = await readRawBody(request)
      // The id IS the unpacked tree hash: bytes that do not reproduce it
      // are rejected, so a ferrying client can never plant mismatched
      // content under a trusted id.
      if (!(await verifySkillArchive(id, bytes))) {
        throw new HttpFailure(400, "Archive contents do not match the blob id")
      }
      blobs.write(id, bytes)
      writeJson(response, 200, { stored: true })
      return true
    }
    throw new HttpFailure(405, "Method not allowed")
  }

  const reconcilePlane = RECONCILE_ROUTES[url.pathname]
  if (reconcilePlane !== undefined && request.method === "POST") {
    const result = await reconcileForNamespace(services, config, reconcilePlane)
    if (result === undefined) {
      throw new HttpFailure(501, RECONCILE_UNAVAILABLE[reconcilePlane])
    }
    publishSyncChanged(services, fanout, reconcilePlane, result.changedEntries)
    writeJson(response, 200, result.status)
    return true
  }

  if (url.pathname === "/v1/sync/accounts/publish" && request.method === "POST") {
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
    writeJson(response, 200, { published: result.changedEntries.length > 0 })
    return true
  }

  const match = /^\/v1\/sync\/([^/]+)$/.exec(url.pathname)
  if (match === null) return false
  const namespace = String(match[1])
  if (!isValidSyncNamespace(namespace)) {
    throw new HttpFailure(400, "Invalid sync namespace")
  }

  if (request.method === "GET") {
    const entries = await run(services.db.getSyncEntries(namespace))
    writeJson(response, 200, { namespace, entries })
    return true
  }

  if (request.method === "PUT") {
    const body = await readSchema(request, PutSyncRequestSchema)
    const result = await run(services.db.mergeSyncEntries(namespace, body.entries))
    if (result.changed.length > 0) {
      void appendAndPublish(services.db, fanout, "sync.changed", namespace, {
        namespace,
        entries: result.changed
      }).catch(swallowError)
    }
    writeJson(response, 200, { namespace, entries: result.merged })
    return true
  }

  throw new HttpFailure(405, "Method not allowed")
}
