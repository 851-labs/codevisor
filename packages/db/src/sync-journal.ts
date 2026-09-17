import type { EventEnvelope } from "@codevisor/api"
import type Database from "better-sqlite3"

import { eventFromRow, sessionEventFromRow } from "./row-mappers.js"
import type { EventRow, SessionEventRow } from "./rows.js"

export interface SyncBatch {
  readonly events: ReadonlyArray<EventEnvelope>
  readonly cursor: number
  readonly requiresSnapshot: boolean
}
const maxJournalBytes = 4 * 1024 * 1024
const maxJournalRows = 2048
const maxReplayBytes = 512 * 1024
const maxReplayRows = 512

/** Retention applies only to delivery records; transcript entities and media
 * are independent and never deleted by this function. */
export const trimSyncJournal = (
  db: Database.Database,
  addedBytes: number,
  sequence: number,
  sessionId?: string
): void => {
  const subject = sessionId === undefined ? "global" : `session:${sessionId}`
  const state = db
    .prepare(
      `insert into sync_watermarks (subject_id, bytes) values (?, ?)
    on conflict(subject_id) do update set bytes = bytes + excluded.bytes returning bytes`
    )
    .get(subject, addedBytes) as { bytes: number }
  if (state.bytes <= maxJournalBytes && sequence % 64 !== 0) return
  const rows = (
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
  ) as Array<{ sequence: number; bytes: number }>
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
      (
        db.prepare("select floor from sync_watermarks where subject_id = ?").get(subject) as
          | { floor: number }
          | undefined
      )?.floor ?? 0
    const cursor =
      sessionId === undefined
        ? Math.max(
            floor,
            (
              db.prepare("select coalesce(max(id), 0) as cursor from events").get() as {
                cursor: number
              }
            ).cursor
          )
        : ((
            db.prepare("select revision as cursor from sessions where id = ?").get(sessionId) as
              | { cursor: number }
              | undefined
          )?.cursor ?? 0)
    const reset = (): SyncBatch => ({ events: [], cursor, requiresSnapshot: true })
    if (since < floor || since > cursor) return reset()
    const metadata = (
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
    ) as Array<{ id: number; bytes: number }>
    if (
      metadata.length > maxReplayRows ||
      metadata.reduce((sum, row) => sum + row.bytes, 0) > maxReplayBytes
    )
      return reset()
    const events =
      sessionId === undefined
        ? (
            db
              .prepare("select * from events where id > ? order by id limit ?")
              .all(since, maxReplayRows) as EventRow[]
          ).map(eventFromRow)
        : (
            db
              .prepare(
                "select * from session_events where session_id = ? and revision > ? order by revision limit ?"
              )
              .all(sessionId, since, maxReplayRows) as SessionEventRow[]
          ).map(sessionEventFromRow)
    return { events, cursor, requiresSnapshot: false }
  })()

/** Atomic cutover after verification. Keep old source tables as an upgrade
 * backup, but create empty delivery journals which runtime readers alone use. */
export const activateSyncJournals = (db: Database.Database): void => {
  const global = (
    db.prepare("select coalesce(max(id), 0) as cursor from events").get() as { cursor: number }
  ).cursor
  for (const row of db
    .prepare("select name from sqlite_master where type = 'trigger' and name glob 'navigation_*'")
    .all() as Array<{ name: string }>) {
    db.exec(`drop trigger "${row.name.replaceAll('"', '""')}"`)
  }
  db.exec(`
    alter table events rename to legacy_events;
    alter table session_events rename to legacy_session_events;
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
