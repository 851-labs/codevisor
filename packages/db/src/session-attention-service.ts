import { isoTimestamp } from "@codevisor/api"

import { revisionRows } from "./common-rows.js"
import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"
import {
  attentionSettleDeadline,
  ensureSessionAttentionState,
  listPendingAttentionSettles,
  projectSessionSidebarState,
  settleSessionAttention
} from "./session-attention.js"
import { finishedTurn, listFinishedTurns, markTurnAnnounced } from "./turn-finish.js"

export const makeSessionAttentionService = (
  sqlite: ServiceContext["sqlite"],
  getSession: ServiceContext["getSession"]
): Pick<
  CodevisorDatabaseService,
  | "markSessionRead"
  | "markSessionUnread"
  | "clearSessionPlanApproval"
  | "settleSessionAttention"
  | "listPendingAttentionSettles"
  | "getAttentionSettleDeadline"
  | "getFinishedTurn"
  | "listFinishedTurns"
  | "markTurnAnnounced"
> => ({
  markSessionRead: (rawId, throughSequence) =>
    attempt("markSessionRead", () => {
      const id = canonicalUuid(rawId)
      getSession(id)
      const latest = readLatestAttentionRevision(sqlite, id)
      const requested = Math.max(0, Math.min(latest, Math.trunc(throughSequence)))
      const changedAt = isoTimestamp()
      sqlite.transaction(() => {
        advanceSessionReadCursor(sqlite, id, requested, changedAt)
        acknowledgeReadAttentionError(sqlite, id, requested)
        projectSessionSidebarState(sqlite, id, changedAt)
      })()
      return getSession(id)
    }),
  markSessionUnread: (rawId) =>
    attempt("markSessionUnread", () => {
      const id = canonicalUuid(rawId)
      getSession(id)
      const changedAt = isoTimestamp()
      sqlite.transaction(() => {
        sqlite.prepare(readStateSql.markUnread).run(id, changedAt)
        projectSessionSidebarState(sqlite, id, changedAt)
      })()
      return getSession(id)
    }),
  clearSessionPlanApproval: (rawId) =>
    attempt("clearSessionPlanApproval", () => {
      const id = canonicalUuid(rawId)
      getSession(id)
      const changedAt = isoTimestamp()
      sqlite.transaction(() => {
        ensureSessionAttentionState(sqlite, id)
        sqlite.prepare(attentionSql.clearPlanApproval).run(id)
        projectSessionSidebarState(sqlite, id, changedAt)
      })()
      return getSession(id)
    }),
  settleSessionAttention: (rawId) =>
    attempt("settleSessionAttention", () => {
      const id = canonicalUuid(rawId)
      return sqlite.transaction(() => settleSessionAttention(sqlite, id, isoTimestamp()))()
    }),
  listPendingAttentionSettles: attempt("listPendingAttentionSettles", () =>
    listPendingAttentionSettles(sqlite)
  ),
  getAttentionSettleDeadline: (rawId) =>
    attempt("getAttentionSettleDeadline", () =>
      attentionSettleDeadline(sqlite, canonicalUuid(rawId))
    ),
  getFinishedTurn: (rawId) =>
    attempt("getFinishedTurn", () => finishedTurn(sqlite, canonicalUuid(rawId))),
  listFinishedTurns: attempt("listFinishedTurns", () => listFinishedTurns(sqlite)),
  markTurnAnnounced: (rawId, revision) =>
    attempt("markTurnAnnounced", () => markTurnAnnounced(sqlite, canonicalUuid(rawId), revision))
})

const readLatestAttentionRevision = (sqlite: ServiceContext["sqlite"], id: string): number => {
  return revisionRows.one(sqlite.prepare(attentionSql.latestRevision).get(id)).revision
}

const advanceSessionReadCursor = (
  sqlite: ServiceContext["sqlite"],
  id: string,
  requested: number,
  changedAt: string
): void => {
  sqlite.prepare(readStateSql.advance).run(id, requested, changedAt)
}

const acknowledgeReadAttentionError = (
  sqlite: ServiceContext["sqlite"],
  id: string,
  requested: number
): void => {
  sqlite.prepare(attentionSql.acknowledgeError).run(id, requested)
}

const readStateSql = {
  markUnread: `insert into session_read_state (
                 session_id, reader_id, last_seen_sequence, manually_unread, updated_at
               ) values (?, 'owner', 0, 1, ?)
               on conflict(session_id, reader_id) do update set
                 manually_unread = 1,
                 updated_at = excluded.updated_at`,
  advance: `insert into session_read_state (
                 session_id, reader_id, last_seen_sequence, manually_unread, updated_at
               ) values (?, 'owner', ?, 0, ?)
               on conflict(session_id, reader_id) do update set
                 last_seen_sequence = max(last_seen_sequence, excluded.last_seen_sequence),
                 manually_unread = 0,
                 updated_at = excluded.updated_at`
}

const attentionSql = {
  clearPlanApproval: "update session_attention set pending_plan_approval = 0 where session_id = ?",
  latestRevision:
    "select coalesce((select attention_revision from session_attention where session_id = ?), 0) as revision",
  acknowledgeError:
    "update session_attention set errored = 0 where session_id = ? and attention_revision <= ?"
}
