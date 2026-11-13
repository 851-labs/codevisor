import type { IncomingMessage, ServerResponse } from "node:http"

import {
  ScreenSharingReply,
  ScreenSharingRequest,
  type ScreenSharingMediaAddress,
  type WorkspacePane
} from "@codevisor/api"
import { Schema } from "effect"

import {
  BoundedBody,
  HttpFailure,
  run,
  writeJson,
  type CodevisorServerConfig,
  type CodevisorServerServices
} from "../server-context.js"

const maxRequestBytes = 300 * 1024
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const computerUsePrefix = "computer-use:"
const computerUseTarget =
  /^computer-use:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

const computerUseSessionId = (displayId: string | undefined): string | undefined =>
  displayId !== undefined && computerUseTarget.test(displayId)
    ? displayId.slice(computerUsePrefix.length).toLowerCase()
    : undefined

const simulatorTarget = /^simulator:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const isSimulatorTarget = (displayId: string | undefined): boolean =>
  displayId !== undefined && simulatorTarget.test(displayId)

const desktopPaneTypes: ReadonlySet<string> = new Set(["screen-sharing", "machine-desktop"])

const paneMismatchesTarget = (
  pane: WorkspacePane,
  displayId: string | undefined,
  sessionId: string | undefined
): boolean => {
  if (isSimulatorTarget(displayId)) return pane.paneType !== "simulator"
  if (sessionId === undefined) return !desktopPaneTypes.has(pane.paneType)
  return (
    pane.paneType !== "chat" ||
    pane.resourceKind !== "session" ||
    String(pane.resourceId).toLowerCase() !== sessionId
  )
}

const isKnownTarget = (displayId: string): boolean =>
  uuid.test(displayId) ||
  computerUseSessionId(displayId) !== undefined ||
  isSimulatorTarget(displayId)

const endpointId = /^[0-9a-f]{64}$/i
const maxMediaAddrs = 32
const maxAppNameLength = 64

const appIsWellFormed = (payload: ScreenSharingRequest): boolean =>
  payload.app === undefined ||
  (endpointId.test(payload.app.key) &&
    payload.app.name.trim().length > 0 &&
    payload.app.name.length <= maxAppNameLength)

const appStartIsComplete = (payload: ScreenSharingRequest): boolean =>
  payload.app === undefined ||
  (payload.intent !== undefined &&
    payload.media?.endpointId.toLowerCase() === payload.app.key.toLowerCase())

const startTargetIsValid = (payload: ScreenSharingRequest): boolean =>
  payload.displayId === undefined ? payload.app !== undefined : isKnownTarget(payload.displayId)

const appOwnsDesktopSession = (payload: ScreenSharingRequest): boolean =>
  payload.app !== undefined &&
  computerUseSessionId(payload.displayId) === undefined &&
  !isSimulatorTarget(payload.displayId)

const isMediaAddress = (media: ScreenSharingMediaAddress | undefined): boolean =>
  media !== undefined &&
  endpointId.test(media.endpointId) &&
  (media.relayUrl === undefined || media.relayUrl.length <= 512) &&
  media.directAddrs.length <= maxMediaAddrs &&
  media.directAddrs.every((addr) => addr.length <= 64)

export const routeScreenSharing = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (url.pathname !== "/v1/screen-sharing") return false
  if (request.headers.origin !== undefined || request.headers["sec-fetch-site"] !== undefined)
    throw new HttpFailure(403, "Native clients only")
  if (request.method !== "POST") throw new HttpFailure(405, "Use POST for Screen Sharing")
  response.setHeader("Cache-Control", "no-store")
  const received = new BoundedBody(maxRequestBytes)
  for await (const chunk of request)
    if (!received.accept(chunk)) throw new HttpFailure(413, "Screen Sharing request is too large")
  let payload: ScreenSharingRequest
  let body: unknown
  try {
    body = JSON.parse(received.text())
    payload = Schema.decodeUnknownSync(ScreenSharingRequest)(body)
  } catch {
    throw new HttpFailure(400, "Invalid Screen Sharing request")
  }
  if (typeof body === "object" && body !== null && "offer" in body && payload.engine !== "v2")
    throw new HttpFailure(
      400,
      "Update Codevisor on this device to view this Mac. Screen Sharing no longer uses WebRTC."
    )
  if (![payload.workspaceId, payload.paneId, payload.viewerId].every((id) => uuid.test(id)))
    throw new HttpFailure(400, "Invalid Screen Sharing identity")
  if (!appIsWellFormed(payload)) throw new HttpFailure(400, "Invalid Screen Sharing identity")
  const starts = payload.operation === "start" || payload.operation === "restart"
  if (
    starts &&
    (payload.engine !== "v2" || !isMediaAddress(payload.media) || !startTargetIsValid(payload))
  )
    throw new HttpFailure(400, "Invalid Screen Sharing media or display")
  if (starts && !appStartIsComplete(payload))
    throw new HttpFailure(400, "Invalid Screen Sharing identity")
  if (payload.displayId !== undefined && !isKnownTarget(payload.displayId))
    throw new HttpFailure(400, "Invalid Screen Sharing display")
  const checksPane = ["start", "restart", "heartbeat"].includes(payload.operation)
  if (checksPane && !appOwnsDesktopSession(payload)) {
    const sessionId = computerUseSessionId(payload.displayId)
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
      paneMismatchesTarget(pane, payload.displayId, sessionId)
    )
      throw new HttpFailure(404, "Screen Sharing pane is no longer available")
  }
  if (config.screenSharing === undefined)
    throw new HttpFailure(501, "Screen Sharing requires the native Codevisor app on a Mac")
  let result: ScreenSharingReply
  try {
    result = Schema.decodeUnknownSync(ScreenSharingReply)(await config.screenSharing(payload))
  } catch (cause) {
    throw screenSharingHostFailure(cause)
  }
  writeJson(response, 200, result)
  return true
}

export const screenSharingHostFailure = (cause: unknown): HttpFailure => {
  const message = cause instanceof Error ? cause.message : ""
  if (message === "Screen Sharing host timed out." || message === "Computer Use helper timed out")
    return new HttpFailure(
      504,
      "The host Mac didn't answer in time; its screen capture may be stuck. Retry in a minute."
    )
  if (message === "Screen Sharing host is stopped.")
    return new HttpFailure(
      503,
      "Codevisor on the host Mac isn't sharing right now. Open a Codevisor window there, then retry."
    )
  return new HttpFailure(503, "Open or update Codevisor on the host Mac, then retry Screen Sharing")
}
