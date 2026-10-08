import type { IncomingMessage, ServerResponse } from "node:http"

import { PutNavigationRecordsRequest as PutNavigationRecordsRequestSchema } from "@codevisor/api"

import {
  readSchema,
  run,
  writeJson,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"

/// GET/PUT /v1/navigation/records — account-wide sidebar records (folders,
/// grouping, project order). Clients replicate every record to every
/// machine they reach; a machine keeps a record only when its revision is
/// newer, so all of them converge on the same last write. Publishing the
/// journaled changes wakes connected event readers.
export const routeNavigationRecords = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (url.pathname !== "/v1/navigation/records") return false
  if (request.method === "GET") {
    writeJson(response, 200, await run(services.db.listNavigationRecords))
    return true
  }
  if (request.method !== "PUT") return false
  const payload = await readSchema(request, PutNavigationRecordsRequestSchema)
  const { records, events } = await run(services.db.putNavigationRecords(payload))
  for (const event of events) await run(fanout.publish(event))
  writeJson(response, 200, records)
  return true
}
