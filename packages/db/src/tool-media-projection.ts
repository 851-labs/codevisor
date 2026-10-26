import type Database from "better-sqlite3"

import { isAttachmentRefs, jsonRecord, type JsonRecord } from "./event-payloads.js"
import type { SessionEventRow } from "./rows.js"

const executionImageIds = (payload: JsonRecord): ReadonlyArray<string> => {
  const calls = jsonRecord(jsonRecord(payload._meta)?.codevisorExecution)?.calls
  if (!Array.isArray(calls)) return []
  return calls.flatMap((call) => {
    const files = jsonRecord(call)?.files
    return Array.isArray(files)
      ? files.flatMap((file) => {
          const fileId = jsonRecord(file)?.fileId
          return typeof fileId === "string" ? [fileId] : []
        })
      : []
  })
}

const inlineImageIds = (payload: JsonRecord): ReadonlyArray<string> =>
  isAttachmentRefs(payload.toolImages) ? payload.toolImages.map((image) => image.fileId) : []

export const recordToolMedia = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord,
  itemId: string
): void => {
  if (payload.sessionUpdate !== "tool_call" && payload.sessionUpdate !== "tool_call_update") return
  const fileIds = [...new Set([...executionImageIds(payload), ...inlineImageIds(payload)])]
  if (fileIds.length === 0) return
  const insert = sqlite.prepare(toolMediaSql)
  for (const fileId of fileIds) insert.run(itemId, event.created_at, fileId)
}

export const recordTextMedia = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord,
  itemId: string
): void => {
  if (!isAttachmentRefs(payload.attachments)) return

  const insert = sqlite.prepare(toolMediaSql)
  for (const file of payload.attachments) insert.run(itemId, event.created_at, file.fileId)
}

const toolMediaSql = `insert or ignore into chat_item_media (item_id, file_id, created_at)
      select ?, id, ? from files
      where id = ? and (mime_type like 'image/%' or mime_type like 'video/%')`
