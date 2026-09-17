import type Database from "better-sqlite3"

import { projectSetupState } from "./setup-state.js"
import { appendTranscriptText } from "./transcript-state.js"

/** Checkpoints inside a single imported message, as well as between messages.
 * Identity and text blocks commit together; interruption cannot duplicate text.
 * Tests can use smaller batches to exercise recovery without multi-megabyte fixtures. */
export const seedImportedTranscript = (
  db: Database.Database,
  report: () => void,
  blocksPerCheckpoint = 256
): void => {
  if (!Number.isSafeInteger(blocksPerCheckpoint) || blocksPerCheckpoint < 1)
    throw new RangeError("blocksPerCheckpoint must be a positive safe integer")
  const key = "transcript-import-cursor-v1"
  const stored = db.prepare("select value from instance_meta where key = ?").get(key) as
    | { value: string }
    | undefined
  let cursor =
    stored === undefined
      ? { rowid: 0, offset: 0 }
      : (JSON.parse(stored.value) as { rowid: number; offset: number })
  const checkpoint = (): void => {
    db.prepare(
      "insert into instance_meta(key, value) values (?, ?) on conflict(key) do update set value = excluded.value"
    ).run(key, JSON.stringify(cursor))
  }
  while (true) {
    const part = db
      .prepare(
        `select rowid as cursor, item_id, kind, length(text) as size from chat_parts
      where rowid ${cursor.offset > 0 ? ">=" : ">"} ? and kind in ('text', 'plan') order by rowid limit 1`
      )
      .get(cursor.rowid) as
      | { cursor: number; item_id: string; kind: string; size: number }
      | undefined
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
        const block = db
          .prepare("select substr(text, ?, 8192) as text from chat_parts where rowid = ?")
          .get(cursor.offset, part.cursor) as { text: string }
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
  let cursor = Number(
    (
      db.prepare("select value from instance_meta where key = ?").get(key) as
        | { value: string }
        | undefined
    )?.value ?? 0
  )
  while (true) {
    const ids = db
      .prepare(
        `select id, length(cast(payload as blob)) as bytes from events where id > ?
      and kind in ('worktree.setup', 'project.setup') order by id limit 256`
      )
      .all(cursor) as Array<{ id: number; bytes: number }>
    if (ids.length === 0) return
    db.transaction(() => {
      let bytes = 0
      for (const id of ids) {
        if (bytes > 0 && bytes + id.bytes > 2 * 1024 * 1024) break
        const row = db
          .prepare("select subject_id, kind, created_at, payload from events where id = ?")
          .get(id.id) as { subject_id: string; kind: string; created_at: string; payload: string }
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
