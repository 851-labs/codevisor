import type { IncomingMessage, ServerResponse } from "node:http"

import { ScreenSharingReply, ScreenSharingRequest } from "@codevisor/api"
import { Schema } from "effect"

import {
  HttpFailure,
  run,
  writeJson,
  type CodevisorServerConfig,
  type CodevisorServerServices
} from "../server-context.js"

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export const routeScreenSharing = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (url.pathname !== "/v1/screen-sharing") return false
  // Machine authentication has already run. Websites cannot use loopback trust.
  if (request.headers.origin !== undefined || request.headers["sec-fetch-site"] !== undefined)
    throw new HttpFailure(403, "Native clients only")
  if (request.method !== "POST") throw new HttpFailure(405, "Use POST for Screen Sharing")
  response.setHeader("Cache-Control", "no-store")
  const chunks: Buffer[] = []
  let size = 0
  for await (const chunk of request) {
    const bytes = Buffer.from(chunk)
    size += bytes.length
    if (size > 300 * 1024) throw new HttpFailure(413, "Screen Sharing request is too large")
    chunks.push(bytes)
  }
  let payload: ScreenSharingRequest
  try {
    payload = Schema.decodeUnknownSync(ScreenSharingRequest)(
      JSON.parse(Buffer.concat(chunks).toString("utf8"))
    )
  } catch {
    throw new HttpFailure(400, "Invalid Screen Sharing request")
  }
  if (![payload.workspaceId, payload.paneId, payload.viewerId].every((id) => uuid.test(id)))
    throw new HttpFailure(400, "Invalid Screen Sharing identity")
  if (
    (payload.operation === "start" || payload.operation === "restart") &&
    (payload.offer === undefined ||
      Buffer.byteLength(payload.offer) > 256 * 1024 ||
      !payload.offer.includes("a=fingerprint:sha-256 ") ||
      payload.displayId === undefined ||
      !uuid.test(payload.displayId))
  )
    throw new HttpFailure(400, "Invalid Screen Sharing offer or display")
  if (["start", "restart", "heartbeat"].includes(payload.operation)) {
    const workspace = (await run(services.db.listWorkspaces)).find(
      (item) => item.id.toLowerCase() === payload.workspaceId.toLowerCase()
    )
    const pane = (await run(services.db.listWorkspacePanes)).find(
      (item) => item.id.toLowerCase() === payload.paneId.toLowerCase()
    )
    if (
      workspace === undefined ||
      workspace.isArchived ||
      pane === undefined ||
      pane.workspaceId.toLowerCase() !== workspace.id.toLowerCase() ||
      pane.providerId !== "codevisor" ||
      pane.paneType !== "screen-sharing"
    )
      throw new HttpFailure(404, "Screen Sharing pane is no longer available")
  }
  if (config.screenSharing === undefined)
    throw new HttpFailure(501, "Screen Sharing requires the native Codevisor app on a Mac")
  let result: ScreenSharingReply
  try {
    result = Schema.decodeUnknownSync(ScreenSharingReply)(await config.screenSharing(payload))
  } catch {
    // Never expose helper paths, tokens, or SDP through a transport error.
    throw new HttpFailure(
      503,
      "Open or update Codevisor on the host Mac, then retry Screen Sharing"
    )
  }
  writeJson(response, 200, result)
  return true
}
