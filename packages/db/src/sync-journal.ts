import type { EventEnvelope } from "@codevisor/api"
import type Database from "better-sqlite3"

import { cursorRows, nameRows } from "./common-rows.js"
import { eventFromRow, sessionEventFromRow } from "./row-mappers.js"
import { integer, rowReader } from "./row-reader.js"
import { eventRows, sessionEventRows } from "./rows.js"

const bytesRows = rowReader({ bytes: integer })

const journalSizeRows = rowReader({ sequence: integer, bytes: integer })

const replaySizeRows = rowReader({ id: integer, bytes: integer })

const floorRows = rowReader({ floor: integer })

export interface SyncBatch {
  readonly events: ReadonlyArray<EventEnvelope>
  readonly cursor: number
  readonly requiresSnapshot: boolean
}
const maxJournalBytes = 4 * 1024 * 1024
const maxJournalRows = 2048
const maxReplayBytes = 512 * 1024
const maxReplayRows = 512

export const trimSyncJournal = (
  db: Database.Database,
  addedBytes: number,
  sequence: number,
  sessionId?: string
): void => {
  const subject = sessionId === undefined ? "global" : `session:${sessionId}`
  const state = bytesRows.one(
    db
      .prepare(
        `insert into sync_watermarks (subject_id, bytes) values (?, ?)
    on conflict(subject_id) do update set bytes = bytes + excluded.bytes returning bytes`
      )
      .get(subject, addedBytes)
  )
  if (state.bytes <= maxJournalBytes && sequence % 64 !== 0) return
  const rows = journalSizeRows.all(
    sessionId === undefined
      ? db
          .prepare(
            "select id as sequence, length(cast(payload as blob)) as bytes from events order by id desc limit ?"
          )
          .all(maxJournalRows + 64)
      : db
          .prepare(
            "select revision as sequence, length(cast(payload as blob)) as bytes from session_events where session_id = ? order by revision desc limit ?"
          )
          .all(sessionId, maxJournalRows + 64)
  )
  let bytes = 0
  let keep = 0
  let floor = 0
  for (const row of rows) {
    if (keep >= maxJournalRows || bytes + row.bytes > maxJournalBytes) {
      floor = row.sequence
      break
    }
    bytes += row.bytes
    keep += 1
  }
  if (floor === 0) return
  if (sessionId === undefined) db.prepare("delete from events where id <= ?").run(floor)
  else
    db.prepare("delete from session_events where session_id = ? and revision <= ?").run(
      sessionId,
      floor
    )
  db.prepare(
    "update sync_watermarks set floor = max(floor, ?), bytes = ? where subject_id = ?"
  ).run(floor, bytes, subject)
}

export const readSyncBatch = (
  db: Database.Database,
  since: number,
  sessionId?: string
): SyncBatch =>
  db.transaction(() => {
    const subject = sessionId === undefined ? "global" : `session:${sessionId}`
    const floor =
      floorRows.maybe(
        db.prepare("select floor from sync_watermarks where subject_id = ?").get(subject)
      )?.floor ?? 0
    const cursor =
      sessionId === undefined
        ? Math.max(
            floor,
            cursorRows.one(db.prepare("select coalesce(max(id), 0) as cursor from events").get())
              .cursor
          )
        : (cursorRows.maybe(
            db.prepare("select revision as cursor from sessions where id = ?").get(sessionId)
          )?.cursor ?? 0)
    const reset = (): SyncBatch => ({ events: [], cursor, requiresSnapshot: true })
    if (since < floor || since > cursor) return reset()
    const metadata = replaySizeRows.all(
      sessionId === undefined
        ? db
            .prepare(
              "select id, length(cast(payload as blob)) as bytes from events where id > ? order by id limit ?"
            )
            .all(since, maxReplayRows + 1)
        : db
            .prepare(
              "select revision as id, length(cast(payload as blob)) as bytes from session_events where session_id = ? and revision > ? order by revision limit ?"
            )
            .all(sessionId, since, maxReplayRows + 1)
    )
    if (
      metadata.length > maxReplayRows ||
      metadata.reduce((sum, row) => sum + row.bytes, 0) > maxReplayBytes
    )
      return reset()
    const events =
      sessionId === undefined
        ? eventRows
            .all(
              db
                .prepare("select * from events where id > ? order by id limit ?")
                .all(since, maxReplayRows)
            )
            .map(eventFromRow)
        : sessionEventRows
            .all(
              db
                .prepare(
                  "select * from session_events where session_id = ? and revision > ? order by revision limit ?"
                )
                .all(sessionId, since, maxReplayRows)
            )
            .map(sessionEventFromRow)
    return { events, cursor, requiresSnapshot: false }
  })()

export const activateSyncJournals = (db: Database.Database): void => {
  const global = cursorRows.one(
    db.prepare("select coalesce(max(id), 0) as cursor from events").get()
  ).cursor
  for (const row of nameRows.all(
    db
      .prepare("select name from sqlite_master where type = 'trigger' and name glob 'navigation_*'")
      .all()
  )) {
    db.exec(`drop trigger "${row.name.replaceAll('"', '""')}"`)
  }
  db.exec(`
    drop table events;
    drop table session_events;
    create table events (
      id integer primary key autoincrement, server_id text not null, kind text not null,
      subject_id text not null, created_at text not null, payload text not null, transcript_item_id text
    );
    create index delivery_events_subject on events(subject_id, id);
    create table session_events (
      session_id text not null references sessions(id) on delete cascade,
      revision integer not null, global_event_id integer unique, server_id text not null,
      kind text not null, created_at text not null, payload text not null, chat_item_id text,
      primary key(session_id, revision)
    );
    create index delivery_events_item on session_events(session_id, chat_item_id, revision);
    insert into sync_watermarks (subject_id, floor)
      select 'session:' || id, revision from sessions where true
      on conflict(subject_id) do update set floor = excluded.floor, bytes = 0;
  `)
  db.prepare("insert into sqlite_sequence (name, seq) values ('events', ?)").run(global)
  db.prepare(
    "insert into sync_watermarks (subject_id, floor) values ('global', ?) on conflict(subject_id) do update set floor = excluded.floor, bytes = 0"
  ).run(global)
}
