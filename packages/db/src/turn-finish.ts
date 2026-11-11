import type Database from "better-sqlite3"

import type { JsonRecord } from "./event-payloads.js"
import { integer, nullable, rowReader, text } from "./row-reader.js"
import type { SessionEventRow } from "./rows.js"

export interface FinishedTurn {
  readonly sessionId: string
  readonly revision: number
  readonly stopReason?: string
}

const finishedTurnRows = rowReader({
  session_id: text,
  turn_end_revision: integer,
  turn_end_stop_reason: nullable(text)
})

const turnActivityRows = rowReader({ turn_active: integer, pending_finish: integer })

export const endsAnnouncedTurn = (event: SessionEventRow, payload: JsonRecord): boolean =>
  event.kind === "session.updated" &&
  (payload.turnState === "ended" || typeof payload.stopReason === "string") &&
  !isUpdatePause(payload)

export const isUpdatePause = (payload: JsonRecord): boolean =>
  payload.stopKind === "pausedForUpdate"

export const turnWasRunning = (sqlite: Database.Database, sessionId: string): boolean => {
  const row = turnActivityRows.one(sqlite.prepare(turnFinishSql.activity).get(sessionId))
  return row.turn_active === 1 || row.pending_finish === 1
}

export const recordTurnEnd = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord
): void => {
  const turnId = typeof payload.turnId === "string" ? payload.turnId : null
  sqlite
    .prepare(turnFinishSql.recordEnd)
    .run(
      event.revision,
      typeof payload.stopReason === "string" ? payload.stopReason : null,
      event.session_id,
      turnId,
      event.session_id,
      event.session_id,
      event.created_at,
      event.session_id
    )
}

export const announceFinishedTurn = (sqlite: Database.Database, sessionId: string): void => {
  sqlite.prepare(turnFinishSql.markFinished).run(sessionId)
}

export const finishedTurn = (
  sqlite: Database.Database,
  sessionId: string
): FinishedTurn | undefined => {
  const row = finishedTurnRows.maybe(sqlite.prepare(turnFinishSql.finished).get(sessionId))
  return row === undefined ? undefined : finishedTurnFromRow(row)
}

export const listFinishedTurns = (sqlite: Database.Database): ReadonlyArray<FinishedTurn> =>
  finishedTurnRows.all(sqlite.prepare(turnFinishSql.allFinished).all()).map(finishedTurnFromRow)

export const markTurnAnnounced = (
  sqlite: Database.Database,
  sessionId: string,
  revision: number
): void => {
  sqlite.prepare(turnFinishSql.markAnnounced).run(sessionId, revision)
}

const finishedTurnFromRow = (row: {
  readonly session_id: string
  readonly turn_end_revision: number
  readonly turn_end_stop_reason: string | null
}): FinishedTurn => ({
  sessionId: row.session_id,
  revision: row.turn_end_revision,
  ...(row.turn_end_stop_reason === null ? {} : { stopReason: row.turn_end_stop_reason })
})

const turnFinishSql = {
  activity: "select turn_active, pending_finish from session_attention where session_id = ?",
  recordEnd: `update session_attention set turn_end_state = 'ended', turn_end_revision = ?,
         turn_end_stop_reason = ?,
         turn_end_item_id = coalesce(
           (select item_id from chat_item_routes where session_id = ? and route_key = 'turn:' || ?),
           (select current_item_id from session_chat_state where session_id = ?),
           (select id from chat_items where session_id = ? and role = 'assistant'
              and status = 'streaming' order by position desc limit 1)
         ),
         turn_end_at = ?
       where session_id = ?`,
  markFinished: `update session_attention set turn_end_state = 'finished'
       where session_id = ? and turn_end_state = 'ended'`,
  finished: `select session_id, turn_end_revision, turn_end_stop_reason from session_attention
       where session_id = ? and turn_end_state = 'finished'`,
  allFinished: `select session_id, turn_end_revision, turn_end_stop_reason from session_attention
       where turn_end_state = 'finished'`,
  markAnnounced: `update session_attention set turn_end_state = null
       where session_id = ? and turn_end_state = 'finished' and turn_end_revision = ?`
}
