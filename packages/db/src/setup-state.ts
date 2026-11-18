import type { TranscriptBodyPage } from "@codevisor/api"
import type Database from "better-sqlite3"

import { jsonRecord } from "./event-payloads.js"
import { parseJsonObject } from "./json-column.js"
import { renderableChatItem } from "./renderable-chat-item.js"
import { integer, nullable, rowReader, text } from "./row-reader.js"

const nextPositionRows = rowReader({ n: integer })

const setupRows = rowReader({
  subject_id: text,
  kind: text,
  revision: integer,
  created_at: text,
  text_length: integer,
  payload: text
})

const setupChunkRows = rowReader({ position: integer, text })

const restoreRows = rowReader({
  id: text,
  started_at: text,
  completed_at: text,
  log: text,
  after_item_id: nullable(text)
})

export const projectSetupState = (
  db: Database.Database,
  subject: string,
  kind: string,
  revision: number,
  createdAt: string,
  raw: unknown
): void => {
  if (kind !== "worktree.setup" && kind !== "project.setup") return
  const payload = jsonRecord(raw)
  if (payload === undefined) return
  const line =
    typeof payload.line === "string"
      ? `[${typeof payload.stream === "string" ? payload.stream : "stdout"}] ${payload.line}\n`
      : ""
  const metadata = { ...payload, line: undefined }
  db.prepare(setupSql.upsert).run(subject, kind, revision, createdAt, JSON.stringify(metadata))
  let position = nextChunkPosition(db, subject, kind)
  for (let offset = 0; offset < line.length;) {
    let end = Math.min(offset + 8192, line.length)
    if (
      end < line.length &&
      line.charCodeAt(end - 1) >= 0xd800 &&
      line.charCodeAt(end - 1) <= 0xdbff
    )
      end--
    db.prepare(setupSql.insertChunk).run(subject, kind, position++, line.slice(offset, end))
    offset = end
  }
  db.prepare(setupSql.growTextLength).run(line.length, subject, kind)
}

export const sessionSetupState = (db: Database.Database, sessionId: string): unknown[] => [
  ...setupActivities(db, sessionId),
  ...sandboxRestores(db, sessionId)
]

const sandboxRestores = (db: Database.Database, sessionId: string): unknown[] =>
  restoreRows.all(db.prepare(setupSql.sandboxRestores).all(sessionId)).map((row) => ({
    id: `sandbox.restore:${row.id}`,
    kind: "sandbox.restore",
    subjectId: row.id,
    state: "completed",
    createdAt: row.started_at,
    durationMs: Date.parse(row.completed_at) - Date.parse(row.started_at),
    lines: row.log === "" ? [] : row.log.split("\n"),
    ...(row.after_item_id === null ? {} : { afterItemId: row.after_item_id })
  }))

const setupActivities = (db: Database.Database, sessionId: string): unknown[] => {
  const rows = accessibleSetupRows(db, sessionId)
  return rows.map((row) => ({
    ...parseJsonObject(row.payload),
    id: `${row.kind}:${row.subject_id}`,
    kind: row.kind,
    subjectId: row.subject_id,
    createdAt: row.created_at,
    ...(row.text_length === 0
      ? {}
      : {
          resource: {
            itemId: `setup:${row.subject_id}`,
            entryKey: row.kind,
            fields: [
              { name: "text", revision: 0, encoding: "text", sizeBytes: row.text_length * 2 }
            ]
          }
        })
  }))
}

export const readSetupBodyPage = (
  db: Database.Database,
  sessionId: string,
  itemId: string,
  key: string,
  position: number
): TranscriptBodyPage | undefined => {
  const subject = itemId.slice(6)
  if (!setupIsAccessible(db, sessionId, subject, key)) return undefined

  const rows = setupChunksFrom(db, subject, key, position)
  if (rows[0] === undefined) return undefined
  return {
    revision: 0,
    encoding: "text",
    ...rows[0],
    ...(rows[1] === undefined ? {} : { nextPosition: rows[1].position })
  }
}

const nextChunkPosition = (db: Database.Database, subject: string, kind: string): number =>
  nextPositionRows.one(db.prepare(setupSql.nextChunkPosition).get(subject, kind)).n

const accessibleSetupRows = (db: Database.Database, sessionId: string) =>
  setupRows.all(db.prepare(accessibleSetup).all(sessionId))

const setupIsAccessible = (
  db: Database.Database,
  sessionId: string,
  subject: string,
  kind: string
): boolean => db.prepare(setupSql.accessibleSubject).get(sessionId, subject, kind) !== undefined

const setupChunksFrom = (db: Database.Database, subject: string, kind: string, position: number) =>
  setupChunkRows.all(db.prepare(setupSql.chunksFrom).all(subject, kind, position))

const accessibleSetup = `select setup.* from setup_state setup join sessions s on s.id = ?
  where setup.subject_id = s.id or (setup.kind = 'project.setup' and setup.subject_id = s.project_id)
    or (setup.kind = 'worktree.setup' and setup.subject_id in (
      select worktree_id from checkouts where checkouts.id = s.checkout_id))`

const setupSql = {
  upsert: `insert into setup_state(subject_id, kind, revision, created_at, payload) values (?, ?, ?, ?, ?)
    on conflict(subject_id, kind) do update set revision = excluded.revision,
      payload = case when json_extract(excluded.payload, '$.state') = 'log' then setup_state.payload else excluded.payload end`,
  nextChunkPosition:
    "select coalesce(max(position), -1) + 1 as n from setup_text_chunks where subject_id = ? and kind = ?",
  insertChunk:
    "insert into setup_text_chunks(subject_id, kind, position, text) values (?, ?, ?, ?)",
  growTextLength:
    "update setup_state set text_length = text_length + ? where subject_id = ? and kind = ?",
  accessibleSubject: `select 1 from (${accessibleSetup}) where subject_id = ? and kind = ?`,
  sandboxRestores: `select item.id, item.started_at, item.completed_at,
      coalesce((select text from chat_parts where item_id = item.id order by position limit 1), '') as log,
      (select case when earlier.role = 'user' and earlier.message_id is not null
          then earlier.message_id else earlier.id end
        from chat_items earlier
        where earlier.session_id = item.session_id and earlier.position < item.position
          and earlier.role in ('user', 'assistant') and ${renderableChatItem("earlier")}
        order by earlier.position desc limit 1) as after_item_id
    from chat_items item
    where item.session_id = ? and item.role = 'system' and item.origin = 'sandbox-restore'
      and item.started_at is not null and item.completed_at is not null
    order by item.position`,
  chunksFrom:
    "select position, text from setup_text_chunks where subject_id = ? and kind = ? and position >= ? order by position limit 2"
}
