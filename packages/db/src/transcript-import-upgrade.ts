import type Database from "better-sqlite3"
import { Schema } from "effect"

import { readInstanceMeta } from "./common-rows.js"
import { parseJsonColumn } from "./json-column.js"
import { integer, rowReader, text } from "./row-reader.js"
import { projectSetupState } from "./setup-state.js"
import { appendTranscriptText } from "./transcript-state.js"

const ImportCursor = Schema.Struct({ rowid: Schema.Number, offset: Schema.Number })

const importPartRows = rowReader({ cursor: integer, item_id: text, kind: text, size: integer })

const blockRows = rowReader({ text })

const eventSizeRows = rowReader({ id: integer, bytes: integer })

const setupEventRows = rowReader({ subject_id: text, kind: text, created_at: text, payload: text })

export const seedImportedTranscript = (
  db: Database.Database,
  report: () => void,
  blocksPerCheckpoint = 256
): void => {
  if (!Number.isSafeInteger(blocksPerCheckpoint) || blocksPerCheckpoint < 1)
    throw new RangeError("blocksPerCheckpoint must be a positive safe integer")
  const key = "transcript-import-cursor-v1"
  const stored = readInstanceMeta(db, key)
  let cursor: { rowid: number; offset: number } =
    stored === undefined ? { rowid: 0, offset: 0 } : parseJsonColumn(ImportCursor, stored)
  const checkpoint = (): void => {
    db.prepare(
      "insert into instance_meta(key, value) values (?, ?) on conflict(key) do update set value = excluded.value"
    ).run(key, JSON.stringify(cursor))
  }
  while (true) {
    const part = importPartRows.maybe(
      db
        .prepare(
          `select rowid as cursor, item_id, kind, length(text) as size from chat_parts
      where rowid ${cursor.offset > 0 ? ">=" : ">"} ? and kind in ('text', 'plan') order by rowid limit 1`
        )
        .get(cursor.rowid)
    )
    if (part === undefined) return
    const entryKey = part.kind === "plan" ? "plan" : "imported-text"
    db.transaction(() => {
      if (cursor.offset === 0) {
        const exists = db
          .prepare("select 1 from transcript_entries where item_id = ? and category = ? limit 1")
          .get(part.item_id, part.kind)
        cursor = { rowid: part.cursor, offset: 0 }
        if (exists !== undefined || part.size === 0) {
          checkpoint()
          return
        }
        db.prepare(
          `insert into transcript_entries(item_id, entry_key, position, revision, category, payload)
          values (?, ?, 0, 0, ?, ?)`
        ).run(
          part.item_id,
          entryKey,
          part.kind,
          JSON.stringify({
            sessionUpdate: part.kind === "plan" ? "plan_document" : "agent_message_chunk",
            messageId: entryKey
          })
        )
        cursor.offset = 1
      }
      const end = Math.min(part.size + 1, cursor.offset + blocksPerCheckpoint * 8192)
      while (cursor.offset < end) {
        const block = blockRows.one(
          db
            .prepare("select substr(text, ?, 8192) as text from chat_parts where rowid = ?")
            .get(cursor.offset, part.cursor)
        )
        appendTranscriptText(db, part.item_id, entryKey, block.text)
        cursor.offset += 8192
      }
      if (cursor.offset > part.size) cursor.offset = 0
      checkpoint()
    })()
    report()
  }
}

export const migrateSetupState = (db: Database.Database, report: () => void): void => {
  const key = "setup-state-cursor-v1"
  let cursor = Number(readInstanceMeta(db, key) ?? 0)
  while (true) {
    const ids = eventSizeRows.all(
      db
        .prepare(
          `select id, length(cast(payload as blob)) as bytes from events where id > ?
      and kind in ('worktree.setup', 'project.setup') order by id limit 256`
        )
        .all(cursor)
    )
    if (ids.length === 0) return
    db.transaction(() => {
      let bytes = 0
      for (const id of ids) {
        if (bytes > 0 && bytes + id.bytes > 2 * 1024 * 1024) break
        const row = setupEventRows.one(
          db
            .prepare("select subject_id, kind, created_at, payload from events where id = ?")
            .get(id.id)
        )
        projectSetupState(
          db,
          row.subject_id,
          row.kind,
          id.id,
          row.created_at,
          JSON.parse(row.payload)
        )
        bytes += id.bytes
        cursor = id.id
      }
      db.prepare(
        "insert into instance_meta(key, value) values (?, ?) on conflict(key) do update set value = excluded.value"
      ).run(key, String(cursor))
    })()
    report()
  }
}
