import type { EventEnvelope } from "@codevisor/api"
import type Database from "better-sqlite3"

import { cursorRows, nameRows } from "./common-rows.js"
import { eventFromRow, sessionEventFromRow } from "./row-mappers.js"
import { integer, rowReader } from "./row-reader.js"
import { eventRows, sessionEventRows } from "./rows.js"

export interface SyncBatch {
  readonly events: ReadonlyArray<EventEnvelope>
  readonly cursor: number
  readonly requiresSnapshot: boolean
}

const maxJournalBytes = 4 * 1024 * 1024
const maxJournalRows = 2048
const trimInterval = 64
const maxReplayBytes = 512 * 1024
const maxReplayRows = 512

export const trimSyncJournal = (
  db: Database.Database,
  addedBytes: number,
  sequence: number,
  sessionId?: string
): void => {
  const journal = journalFor(db, sessionId)
  const journalBytes = addWatermarkBytes(db, journal.subject, addedBytes)
  if (trimCanWait(journalBytes, sequence)) return

  const tail = retainedTail(journal.newestSizes(maxJournalRows + trimInterval))
  if (tail.floor === 0) return

  journal.deleteThrough(tail.floor)
  raiseWatermarkFloor(db, journal.subject, tail.floor, tail.bytes)
}

export const readSyncBatch = (
  db: Database.Database,
  since: number,
  sessionId?: string
): SyncBatch =>
  db.transaction(() => {
    const journal = journalFor(db, sessionId)
    const window = journal.replayWindow()
    if (outsideWindow(window, since)) return snapshotRequired(window.cursor)

    const pending = journal.sizesAfter(since, maxReplayRows + 1)
    if (tooBigToReplay(pending)) return snapshotRequired(window.cursor)

    return replay(journal.eventsAfter(since, maxReplayRows), window.cursor)
  })()

export const activateSyncJournals = (db: Database.Database): void => {
  const globalCursor = latestEventId(db)

  dropNavigationTriggers(db)
  db.exec(recreateJournalTablesSql)

  db.exec(seedSessionWatermarksSql)
  db.prepare(seedEventSequenceSql).run(globalCursor)
  db.prepare(seedGlobalWatermarkSql).run(globalCursor)
}

interface ReplayWindow {
  readonly floor: number
  readonly cursor: number
}

interface EventSize {
  readonly sequence: number
  readonly bytes: number
}

interface RetainedTail {
  readonly floor: number
  readonly bytes: number
}

interface SyncJournal {
  readonly subject: string
  readonly replayWindow: () => ReplayWindow
  readonly newestSizes: (limit: number) => ReadonlyArray<EventSize>
  readonly sizesAfter: (since: number, limit: number) => ReadonlyArray<EventSize>
  readonly eventsAfter: (since: number, limit: number) => ReadonlyArray<EventEnvelope>
  readonly deleteThrough: (sequence: number) => void
}

const journalFor = (db: Database.Database, sessionId?: string): SyncJournal => {
  if (sessionId === undefined) return globalJournal(db)
  return sessionJournal(db, sessionId)
}

const globalJournal = (db: Database.Database): SyncJournal => ({
  subject: "global",
  replayWindow: () => {
    const floor = watermarkFloor(db, "global")
    return { floor, cursor: Math.max(floor, latestEventId(db)) }
  },
  newestSizes: (limit) => eventSizeRows.all(db.prepare(globalSql.newestSizes).all(limit)),
  sizesAfter: (since, limit) =>
    eventSizeRows.all(db.prepare(globalSql.sizesAfter).all(since, limit)),
  eventsAfter: (since, limit) =>
    eventRows.all(db.prepare(globalSql.eventsAfter).all(since, limit)).map(eventFromRow),
  deleteThrough: (sequence) => db.prepare(globalSql.deleteThrough).run(sequence)
})

const sessionJournal = (db: Database.Database, sessionId: string): SyncJournal => {
  const subject = `session:${sessionId}`
  return {
    subject,
    replayWindow: () => ({
      floor: watermarkFloor(db, subject),
      cursor: sessionRevision(db, sessionId)
    }),
    newestSizes: (limit) =>
      eventSizeRows.all(db.prepare(sessionSql.newestSizes).all(sessionId, limit)),
    sizesAfter: (since, limit) =>
      eventSizeRows.all(db.prepare(sessionSql.sizesAfter).all(sessionId, since, limit)),
    eventsAfter: (since, limit) =>
      sessionEventRows
        .all(db.prepare(sessionSql.eventsAfter).all(sessionId, since, limit))
        .map(sessionEventFromRow),
    deleteThrough: (sequence) => db.prepare(sessionSql.deleteThrough).run(sessionId, sequence)
  }
}

const trimCanWait = (journalBytes: number, sequence: number): boolean =>
  journalBytes <= maxJournalBytes && sequence % trimInterval !== 0

const retainedTail = (newestFirst: ReadonlyArray<EventSize>): RetainedTail => {
  let bytes = 0
  let kept = 0
  for (const event of newestFirst) {
    if (kept >= maxJournalRows || bytes + event.bytes > maxJournalBytes) {
      return { floor: event.sequence, bytes }
    }
    bytes += event.bytes
    kept += 1
  }
  return { floor: 0, bytes }
}

const outsideWindow = (window: ReplayWindow, since: number): boolean =>
  since < window.floor || since > window.cursor

const tooBigToReplay = (pending: ReadonlyArray<EventSize>): boolean =>
  pending.length > maxReplayRows || totalBytes(pending) > maxReplayBytes

const totalBytes = (events: ReadonlyArray<EventSize>): number =>
  events.reduce((sum, event) => sum + event.bytes, 0)

const snapshotRequired = (cursor: number): SyncBatch => ({
  events: [],
  cursor,
  requiresSnapshot: true
})

const replay = (events: ReadonlyArray<EventEnvelope>, cursor: number): SyncBatch => ({
  events,
  cursor,
  requiresSnapshot: false
})

const addWatermarkBytes = (db: Database.Database, subject: string, bytes: number): number =>
  bytesRows.one(db.prepare(addWatermarkBytesSql).get(subject, bytes)).bytes

const watermarkFloor = (db: Database.Database, subject: string): number =>
  floorRows.maybe(db.prepare(watermarkFloorSql).get(subject))?.floor ?? 0

const raiseWatermarkFloor = (
  db: Database.Database,
  subject: string,
  floor: number,
  bytes: number
): void => {
  db.prepare(raiseWatermarkFloorSql).run(floor, bytes, subject)
}

const latestEventId = (db: Database.Database): number =>
  cursorRows.one(db.prepare(latestEventIdSql).get()).cursor

const sessionRevision = (db: Database.Database, sessionId: string): number =>
  cursorRows.maybe(db.prepare(sessionRevisionSql).get(sessionId))?.cursor ?? 0

const dropNavigationTriggers = (db: Database.Database): void => {
  for (const trigger of nameRows.all(db.prepare(navigationTriggersSql).all())) {
    db.exec(dropTriggerSql(trigger.name))
  }
}

const dropTriggerSql = (name: string): string => `drop trigger ${quotedIdentifier(name)}`

const quotedIdentifier = (name: string): string => `"${name.replaceAll('"', '""')}"`

const globalSql = {
  newestSizes: `
    select id as sequence, length(cast(payload as blob)) as bytes
    from events order by id desc limit ?`,
  sizesAfter: `
    select id as sequence, length(cast(payload as blob)) as bytes
    from events where id > ? order by id limit ?`,
  eventsAfter: "select * from events where id > ? order by id limit ?",
  deleteThrough: "delete from events where id <= ?"
}

const sessionSql = {
  newestSizes: `
    select revision as sequence, length(cast(payload as blob)) as bytes
    from session_events where session_id = ? order by revision desc limit ?`,
  sizesAfter: `
    select revision as sequence, length(cast(payload as blob)) as bytes
    from session_events where session_id = ? and revision > ? order by revision limit ?`,
  eventsAfter: `
    select * from session_events
    where session_id = ? and revision > ? order by revision limit ?`,
  deleteThrough: "delete from session_events where session_id = ? and revision <= ?"
}

const addWatermarkBytesSql = `
  insert into sync_watermarks (subject_id, bytes) values (?, ?)
  on conflict(subject_id) do update set bytes = bytes + excluded.bytes
  returning bytes`

const watermarkFloorSql = "select floor from sync_watermarks where subject_id = ?"

const raiseWatermarkFloorSql =
  "update sync_watermarks set floor = max(floor, ?), bytes = ? where subject_id = ?"

const latestEventIdSql = "select coalesce(max(id), 0) as cursor from events"

const sessionRevisionSql = "select revision as cursor from sessions where id = ?"

const navigationTriggersSql =
  "select name from sqlite_master where type = 'trigger' and name glob 'navigation_*'"

const recreateJournalTablesSql = `
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
  create index delivery_events_item on session_events(session_id, chat_item_id, revision);`

const seedSessionWatermarksSql = `
  insert into sync_watermarks (subject_id, floor)
  select 'session:' || id, revision from sessions where true
  on conflict(subject_id) do update set floor = excluded.floor, bytes = 0`

const seedEventSequenceSql = "insert into sqlite_sequence (name, seq) values ('events', ?)"

const seedGlobalWatermarkSql = `
  insert into sync_watermarks (subject_id, floor) values ('global', ?)
  on conflict(subject_id) do update set floor = excluded.floor, bytes = 0`

const bytesRows = rowReader({ bytes: integer })

const floorRows = rowReader({ floor: integer })

const eventSizeRows = rowReader({ sequence: integer, bytes: integer })
