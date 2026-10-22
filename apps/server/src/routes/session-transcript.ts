import type { IncomingMessage, ServerResponse } from "node:http"

import { HttpFailure, matchRoute, matchRouteParams, run, writeJson } from "../server-context.js"
import type { CodevisorServerServices, RouteState } from "../server-context.js"
import { field } from "../unknown-values.js"
import { withAutoResume } from "./auto-resume-routes.js"
import { routeParam } from "./route-params.js"
import { withUpdateGate } from "./update-gate.js"

export const routeSessionTranscript = async (
  services: CodevisorServerServices,
  routeState: RouteState,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const sessionId = matchRoute(url.pathname, "/v1/sessions/:id/transcript")
  if (sessionId !== undefined && request.method === "GET") {
    await readTranscriptPage(services, routeState, response, url, sessionId)
    return true
  }

  const body = matchRouteParams(url.pathname, "/v1/sessions/:id/transcript/:itemId/body")
  if (body !== undefined && request.method === "GET") {
    await readTranscriptBody(
      services,
      response,
      url,
      routeParam(body, "id"),
      routeParam(body, "itemId")
    )
    return true
  }

  const details = matchRouteParams(url.pathname, "/v1/sessions/:id/transcript/:itemId/details")
  if (details !== undefined && request.method === "GET") {
    await readTranscriptDetails(
      services,
      response,
      url,
      routeParam(details, "id"),
      routeParam(details, "itemId")
    )
    return true
  }

  return false
}

const transcriptPageCursor = (url: URL) => {
  const { before, forward } = transcriptPosition(url.searchParams.get("before"))
  const limit = transcriptPageLimit(url.searchParams.get("limit"))
  return { before, limit, forward }
}

const transcriptBefore = (rawBefore: string | null, byId: boolean, forward: boolean) => {
  if (rawBefore === null) return undefined
  if (byId) return rawBefore.slice(rawBefore.indexOf(":") + 1)
  return Number(forward ? rawBefore.slice(6) : rawBefore)
}

const transcriptPosition = (rawBefore: string | null) => {
  const byId =
    rawBefore?.startsWith("after-id:") === true || rawBefore?.startsWith("before-id:") === true
  const forward =
    rawBefore?.startsWith("after:") === true || rawBefore?.startsWith("after-id:") === true
  const before = transcriptBefore(rawBefore, byId, forward)
  if (
    (typeof before === "number" && (!Number.isSafeInteger(before) || before < 0)) ||
    (typeof before === "string" && !/^[a-fA-F0-9-]{36}$/.test(before))
  ) {
    throw new HttpFailure(400, "Invalid transcript cursor")
  }
  return { before, forward }
}

const transcriptPageLimit = (rawLimit: string | null): number => {
  const limit = rawLimit === null ? 32 : Number(rawLimit)
  if (!Number.isSafeInteger(limit) || limit < 1) {
    throw new HttpFailure(400, "Invalid transcript page limit")
  }
  return limit
}

const readTranscriptPage = async (
  services: CodevisorServerServices,
  routeState: RouteState,
  response: ServerResponse,
  url: URL,
  transcriptSessionId: string
): Promise<void> => {
  const { before, limit, forward } = transcriptPageCursor(url)
  writeJson(
    response,
    200,
    await withAutoResume(
      services.db,
      withUpdateGate(
        await run(services.db.getTranscriptPage(transcriptSessionId, before, limit, forward)),
        services,
        routeState,
        transcriptSessionId
      ),
      transcriptSessionId
    )
  )
}

const readTranscriptBody = async (
  services: CodevisorServerServices,
  response: ServerResponse,
  url: URL,
  id: string,
  itemId: string
): Promise<void> => {
  const key = url.searchParams.get("key")
  const bodyField = url.searchParams.get("field")
  const position = Number(url.searchParams.get("position") ?? "0")
  if (key === null || bodyField === null || !Number.isSafeInteger(position) || position < 0) {
    throw new HttpFailure(400, "Invalid transcript body cursor")
  }
  const page = await run(services.db.getTranscriptBodyPage(id, itemId, key, bodyField, position))
  if (page === undefined) throw new HttpFailure(404, "Transcript body not found")
  writeJson(response, 200, page)
}

const readTranscriptDetails = async (
  services: CodevisorServerServices,
  response: ServerResponse,
  url: URL,
  id: string,
  itemId: string
): Promise<void> => {
  const after = url.searchParams.get("after") ?? undefined
  if (!validTranscriptDetailCursor(after)) {
    writeJson(response, 400, { error: "Invalid transcript detail cursor" })
    return
  }
  const details = await run(services.db.getTranscriptItemDetails(id, itemId, after))
  if (details === undefined) {
    throw new HttpFailure(404, `Transcript item not found: ${itemId}`)
  }
  writeJson(response, 200, details)
}

const validTranscriptDetailCursor = (after: string | undefined): boolean => {
  if (after !== undefined && after !== "latest") {
    try {
      const cursor: unknown = JSON.parse(Buffer.from(after, "base64url").toString())
      const reverse = field(cursor, "reverse")
      if (
        !Number.isSafeInteger(field(cursor, "position")) ||
        typeof field(cursor, "key") !== "string" ||
        (reverse !== undefined && typeof reverse !== "boolean")
      )
        throw new Error("Invalid cursor")
    } catch {
      return false
    }
  }
  return true
}
