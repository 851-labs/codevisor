import { PutSyncRequest as PutSyncRequestSchema } from "@codevisor/api"
import { isValidSyncNamespace } from "@codevisor/sync"
import type { IncomingMessage, ServerResponse } from "node:http"
import {
  appendAndPublish,
  HttpFailure,
  readSchema,
  run,
  swallowError,
  writeJson,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"

/// The config plane's replica endpoints. GET returns this server's document
/// for a namespace; PUT merges entries in (last-writer-wins, hybrid logical
/// clocks — see @codevisor/sync) and returns the merged document, so one
/// round trip both pushes and pulls. Changes publish `sync.changed` so
/// every connected client adopts them live.
export const routeSync = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
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
