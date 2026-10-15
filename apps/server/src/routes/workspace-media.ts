import type { IncomingMessage, ServerResponse } from "node:http"

import type { WorkspaceLink, WorkspaceLinkPage, WorkspacePhotoPage } from "@codevisor/api"
import type { WorkspaceMediaCursor } from "@codevisor/db"

import {
  HttpFailure,
  matchRouteParams,
  run,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"
import { markdownLinks } from "./markdown-links.js"
import { routeParam } from "./route-params.js"

const messageScanSize = 100

const pageLimit = (raw: string | null, fallback: number): number => {
  const limit = raw === null ? fallback : Number(raw)
  return Number.isInteger(limit) ? Math.min(Math.max(limit, 1), 200) : fallback
}

const encodeCursor = (cursor: WorkspaceMediaCursor): string =>
  Buffer.from(JSON.stringify([cursor.createdAt, cursor.id])).toString("base64url")

const decodeCursor = (raw: string | null): WorkspaceMediaCursor | undefined => {
  if (raw === null) return undefined
  try {
    const parsed: unknown = JSON.parse(Buffer.from(raw, "base64url").toString("utf8"))
    if (
      Array.isArray(parsed) &&
      parsed.length === 2 &&
      typeof parsed[0] === "string" &&
      typeof parsed[1] === "string"
    ) {
      return { createdAt: parsed[0], id: parsed[1] }
    }
  } catch {}
  throw new HttpFailure(400, "Invalid before cursor")
}

const workspacePhotos = async (
  services: CodevisorServerServices,
  workspaceId: string,
  before: WorkspaceMediaCursor | undefined,
  limit: number
): Promise<WorkspacePhotoPage> => {
  const rows = await run(services.db.listWorkspacePhotos(workspaceId, before, limit + 1))
  const photos = rows.slice(0, limit)
  const last = photos.at(-1)
  return rows.length > limit && last !== undefined
    ? {
        photos,
        nextBefore: encodeCursor({ createdAt: last.createdAt, id: last.attachment.fileId })
      }
    : { photos }
}

const workspaceLinks = async (
  services: CodevisorServerServices,
  workspaceId: string,
  before: WorkspaceMediaCursor | undefined,
  limit: number
): Promise<WorkspaceLinkPage> => {
  const links: Array<WorkspaceLink> = []
  const seen = new Set<string>()
  let cursor = before
  for (;;) {
    const messages = await run(
      services.db.listWorkspaceMessageTexts(workspaceId, cursor, messageScanSize)
    )
    if (messages.length === 0) return { links }
    for (const message of messages) {
      for (const link of markdownLinks(message.text)) {
        if (seen.has(link.url)) continue
        seen.add(link.url)
        links.push({
          ...link,
          sessionId: message.sessionId,
          itemId: message.itemId,
          createdAt: message.createdAt
        })
      }
      cursor = { createdAt: message.createdAt, id: message.itemId }
      if (links.length >= limit) {
        return { links, nextBefore: encodeCursor(cursor) }
      }
    }
  }
}

export const routeWorkspaceMedia = async (
  services: CodevisorServerServices,
  findWorkspace: (workspaceId: string) => Promise<unknown>,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (request.method !== "GET") return false
  const photosRoute = matchRouteParams(url.pathname, "/v1/workspaces/:workspaceId/photos")
  const linksRoute = matchRouteParams(url.pathname, "/v1/workspaces/:workspaceId/links")
  const route = photosRoute ?? linksRoute
  if (route === undefined) return false
  const workspaceId = routeParam(route, "workspaceId")
  if ((await findWorkspace(workspaceId)) === undefined) {
    throw new HttpFailure(404, `Workspace not found: ${workspaceId}`)
  }
  const before = decodeCursor(url.searchParams.get("before"))
  const limit = url.searchParams.get("limit")
  writeJson(
    response,
    200,
    photosRoute === undefined
      ? await workspaceLinks(services, workspaceId, before, pageLimit(limit, 100))
      : await workspacePhotos(services, workspaceId, before, pageLimit(limit, 60))
  )
  return true
}
