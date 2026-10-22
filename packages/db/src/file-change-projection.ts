import type Database from "better-sqlite3"

import { jsonRecord, type JsonRecord } from "./event-payloads.js"
import type { SessionEventRow } from "./rows.js"

interface FileChange {
  readonly path: string
  readonly added: number
  readonly removed: number
}

const count = (value: unknown): number =>
  typeof value === "number" && Number.isFinite(value) ? Math.max(0, Math.round(value)) : 0

const fileChanges = (value: unknown): ReadonlyArray<FileChange> | undefined => {
  if (!Array.isArray(value)) return undefined
  return value.flatMap((entry) => {
    const stat = jsonRecord(entry)
    return typeof stat?.path === "string" && stat.path.length > 0
      ? [{ path: stat.path, added: count(stat.added), removed: count(stat.removed) }]
      : []
  })
}

export const recordToolFileChanges = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord,
  itemId: string
): void => {
  if (payload.sessionUpdate !== "tool_call" && payload.sessionUpdate !== "tool_call_update") return
  const toolCallId = payload.toolCallId
  if (typeof toolCallId !== "string") return
  const status = typeof payload.status === "string" ? payload.status : undefined
  const changes = fileChanges(payload.diffStats) ?? []
  const upsert = sqlite.prepare(fileChangeSql.upsert)
  for (const change of changes) {
    upsert.run({ itemId, toolCallId, ...change, status: status ?? null, at: event.created_at })
  }
  if (status !== undefined) {
    sqlite
      .prepare(fileChangeSql.setStatus)
      .run(status, event.created_at, itemId, toolCallId, status)
  }
}

const fileChangeSql = {
  upsert: `insert into chat_item_file_changes (
       item_id, tool_call_id, path, added, removed, status, updated_at
     ) values (@itemId, @toolCallId, @path, @added, @removed, coalesce(@status, 'pending'), @at)
     on conflict(item_id, tool_call_id, path) do update set
       added = excluded.added,
       removed = excluded.removed,
       status = coalesce(@status, status),
       updated_at = excluded.updated_at`,
  setStatus: `update chat_item_file_changes set status = ?, updated_at = ?
         where item_id = ? and tool_call_id = ? and status <> ?`
}
