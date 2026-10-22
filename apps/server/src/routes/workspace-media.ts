import type { IncomingMessage, ServerResponse } from "node:http"

import type {
  WorkspaceLink,
  WorkspaceLinkPage,
  WorkspaceMediaItem,
  WorkspaceMediaPage,
  WorkspacePhotoPage
} from "@codevisor/api"
import type { WorkspaceMediaCursor, WorkspaceMediaRow } from "@codevisor/db"

import { videoDurationMs } from "../infra/media-previews.js"
import {
  attachmentDiskFile,
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

const mediaPage = async (
  services: CodevisorServerServices,
  workspaceId: string,
  includeVideos: boolean,
  before: WorkspaceMediaCursor | undefined,
  limit: number
): Promise<{ rows: ReadonlyArray<WorkspaceMediaRow>; nextBefore?: string }> => {
  const rows = await run(
    services.db.listWorkspaceMedia(workspaceId, includeVideos, before, limit + 1)
  )
  const page = rows.slice(0, limit)
  const last = page.at(-1)
  return rows.length > limit && last !== undefined
    ? {
        rows: page,
        nextBefore: encodeCursor({ createdAt: last.createdAt, id: last.attachment.fileId })
      }
    : { rows: page }
}

const photo = ({ attachment, sessionId, itemId, createdAt, source }: WorkspaceMediaRow) => ({
  attachment,
  sessionId,
  itemId,
  createdAt,
  source
})

const workspacePhotos = async (
  services: CodevisorServerServices,
  workspaceId: string,
  before: WorkspaceMediaCursor | undefined,
  limit: number
): Promise<WorkspacePhotoPage> => {
  const { rows, nextBefore } = await mediaPage(services, workspaceId, false, before, limit)
  const photos = rows.map(photo)
  return nextBefore === undefined ? { photos } : { photos, nextBefore }
}

const cachedOrProbedDurationMs = async (
  services: CodevisorServerServices,
  row: WorkspaceMediaRow
): Promise<number | undefined> => {
  if (!row.attachment.mimeType.startsWith("video/")) return undefined
  if (row.durationProbed) return row.durationMs
  try {
    const file = await attachmentDiskFile(services, row.attachment.fileId)
    const probed = await videoDurationMs(file.path)
    await run(services.db.recordMediaDuration(row.sha256, probed))
    return probed
  } catch {
    return undefined
  }
}

const workspaceMedia = async (
  services: CodevisorServerServices,
  workspaceId: string,
  before: WorkspaceMediaCursor | undefined,
  limit: number
): Promise<WorkspaceMediaPage> => {
  const { rows, nextBefore } = await mediaPage(services, workspaceId, true, before, limit)
  const media = await Promise.all(
    rows.map(async (row): Promise<WorkspaceMediaItem> => {
      const ms = await cachedOrProbedDurationMs(services, row)
      return ms === undefined ? photo(row) : { ...photo(row), durationSeconds: ms / 1000 }
    })
  )
  return nextBefore === undefined ? { media } : { media, nextBefore }
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
  const mediaRoute = matchRouteParams(url.pathname, "/v1/workspaces/:workspaceId/media")
  const linksRoute = matchRouteParams(url.pathname, "/v1/workspaces/:workspaceId/links")
  const route = photosRoute ?? mediaRoute ?? linksRoute
  if (route === undefined) return false
  const workspaceId = routeParam(route, "workspaceId")
  if ((await findWorkspace(workspaceId)) === undefined) {
    throw new HttpFailure(404, `Workspace not found: ${workspaceId}`)
  }
  const before = decodeCursor(url.searchParams.get("before"))
  const limit = url.searchParams.get("limit")
  let page: WorkspacePhotoPage | WorkspaceMediaPage | WorkspaceLinkPage
  if (photosRoute !== undefined)
    page = await workspacePhotos(services, workspaceId, before, pageLimit(limit, 60))
  else if (mediaRoute !== undefined)
    page = await workspaceMedia(services, workspaceId, before, pageLimit(limit, 60))
  else page = await workspaceLinks(services, workspaceId, before, pageLimit(limit, 100))
  writeJson(response, 200, page)
  return true
}
