import type Database from "better-sqlite3"

import {
  isBotConversation,
  isTurnEnd,
  projectBotConversationAttention
} from "./bot-conversation-attention.js"
import { sessionGoalSnapshot } from "./chat-items.js"
import type { JsonRecord } from "./event-payloads.js"
import { backgroundTasksFromRaw, conversationEventPayload, jsonRecord } from "./event-payloads.js"
import { integer, nullable, rowReader, text } from "./row-reader.js"
import type { SessionEventRow } from "./rows.js"
import { holdsInProgress, projectSessionSidebarState } from "./session-sidebar-state.js"

export { projectSessionSidebarState } from "./session-sidebar-state.js"

export const ATTENTION_SETTLE_GRACE_MS = 12_000

export const ensureSessionAttentionState = (sqlite: Database.Database, sessionId: string): void => {
  sqlite
    .prepare("insert into session_attention (session_id) values (?) on conflict do nothing")
    .run(sessionId)
}

const attentionRows = rowReader({
  attention_revision: integer,
  turn_active: integer,
  runtime_state: text,
  has_runtime_state: integer,
  current_mode_id: nullable(text),
  pending_plan_approval: integer,
  errored: integer,
  pending_finish: integer,
  settle_due_at: nullable(text)
})

const backgroundTaskRows = rowReader({ background_tasks: text })

const settleRows = rowReader({ session_id: text, settle_due_at: nullable(text) })

const settleDueRows = rowReader({ settle_due_at: nullable(text) })

const modeRows = rowReader({ current_mode_id: nullable(text), harness_id: text })

const attentionRow = (sqlite: Database.Database, sessionId: string) =>
  attentionRows.maybe(
    sqlite.prepare("select * from session_attention where session_id = ?").get(sessionId)
  )

const sessionHasActiveGoal = (sqlite: Database.Database, sessionId: string): boolean =>
  sessionGoalSnapshot(sqlite, sessionId)?.status === "active"

const sessionIsHeld = (sqlite: Database.Database, sessionId: string): boolean => {
  const session = backgroundTaskRows.maybe(
    sqlite.prepare("select background_tasks from sessions where id = ?").get(sessionId)
  )
  /* v8 ignore next */
  if (session === undefined) return false
  return (
    backgroundTasksFromRaw(session.background_tasks).some(holdsInProgress) ||
    sessionHasActiveGoal(sqlite, sessionId)
  )
}

const sessionHasQueuedPrompts = (sqlite: Database.Database, sessionId: string): boolean =>
  sqlite.prepare("select 1 from prompt_queue_items where session_id = ? limit 1").get(sessionId) !==
  undefined

const bumpAttentionRevision = (sqlite: Database.Database, sessionId: string): void => {
  sqlite
    .prepare(
      `update session_attention set attention_revision = attention_revision + 1,
         pending_finish = 0, settle_due_at = null where session_id = ?`
    )
    .run(sessionId)
}

const terminalAttentionError = (event: SessionEventRow, payload: JsonRecord): boolean =>
  event.kind === "session.error" ||
  typeof payload.stopDetail === "string" ||
  (typeof payload.stopReason === "string" &&
    payload.stopReason !== "end_turn" &&
    payload.stopReason !== "cancelled")

const reevaluatePendingFinish = (
  sqlite: Database.Database,
  sessionId: string,
  now: string
): void => {
  const state = attentionRow(sqlite, sessionId)
  if (state === undefined || state.pending_finish !== 1 || state.turn_active === 1) return
  if (sessionIsHeld(sqlite, sessionId)) {
    if (state.settle_due_at !== null) {
      sqlite
        .prepare("update session_attention set settle_due_at = null where session_id = ?")
        .run(sessionId)
    }
    return
  }
  if (sessionHasQueuedPrompts(sqlite, sessionId)) return
  if (state.settle_due_at === null) {
    const dueAt = new Date(Date.parse(now) + ATTENTION_SETTLE_GRACE_MS).toISOString()
    sqlite
      .prepare("update session_attention set settle_due_at = ? where session_id = ?")
      .run(dueAt, sessionId)
    return
  }
  if (state.settle_due_at <= now) {
    bumpAttentionRevision(sqlite, sessionId)
  }
}

export const settleSessionAttention = (
  sqlite: Database.Database,
  sessionId: string,
  now: string
): { readonly settled: boolean; readonly nextDueAt?: string } => {
  const state = attentionRow(sqlite, sessionId)
  if (state === undefined || state.pending_finish !== 1 || state.turn_active === 1) {
    return { settled: false }
  }
  if (sessionIsHeld(sqlite, sessionId)) {
    sqlite
      .prepare("update session_attention set settle_due_at = null where session_id = ?")
      .run(sessionId)
    return { settled: false }
  }
  if (sessionHasQueuedPrompts(sqlite, sessionId)) return { settled: false }
  const dueAt =
    state.settle_due_at ?? new Date(Date.parse(now) + ATTENTION_SETTLE_GRACE_MS).toISOString()
  if (state.settle_due_at === null) {
    sqlite
      .prepare("update session_attention set settle_due_at = ? where session_id = ?")
      .run(dueAt, sessionId)
  }
  if (dueAt > now) return { settled: false, nextDueAt: dueAt }
  bumpAttentionRevision(sqlite, sessionId)
  projectSessionSidebarState(sqlite, sessionId, now)
  return { settled: true }
}

export const listPendingAttentionSettles = (
  sqlite: Database.Database
): ReadonlyArray<{ readonly sessionId: string; readonly dueAt: string | null }> =>
  settleRows
    .all(
      sqlite
        .prepare("select session_id, settle_due_at from session_attention where pending_finish = 1")
        .all()
    )
    .map((row) => ({ sessionId: row.session_id, dueAt: row.settle_due_at }))

export const attentionSettleDeadline = (
  sqlite: Database.Database,
  sessionId: string
): string | undefined => {
  if (sessionHasQueuedPrompts(sqlite, sessionId)) return undefined
  const row = settleDueRows.maybe(
    sqlite
      .prepare(
        "select settle_due_at from session_attention where session_id = ? and pending_finish = 1 and turn_active = 0"
      )
      .get(sessionId)
  )
  return row?.settle_due_at ?? undefined
}

export const projectSessionAttention = (
  sqlite: Database.Database,
  event: SessionEventRow
): void => {
  const payload = jsonRecord(JSON.parse(event.payload))
  if (payload === undefined) return
  ensureSessionAttentionState(sqlite, event.session_id)

  projectAttentionMode(sqlite, event, payload)
  projectAttentionRuntime(sqlite, event, payload)
  projectAttentionTurnStart(sqlite, event, payload)
  projectUserConversationAttention(sqlite, event, payload)
  if (isBotConversation(sqlite, event.session_id)) {
    projectBotConversationAttention(sqlite, event, payload)
    return
  }
  projectTerminalAttention(sqlite, event, payload)

  reevaluatePendingFinish(sqlite, event.session_id, event.created_at)
}

const projectAttentionMode = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord
): void => {
  if (event.kind === "session.updated" && typeof payload.modeId === "string") {
    sqlite
      .prepare(
        `update session_attention set current_mode_id = ?,
           pending_plan_approval = case when ? = 'plan' then pending_plan_approval else 0 end
         where session_id = ?`
      )
      .run(payload.modeId, payload.modeId, event.session_id)
  }
}

const projectAttentionRuntime = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord
): void => {
  if (event.kind === "session.updated" && typeof payload.runtimeState === "string") {
    const state =
      payload.runtimeState === "running" ||
      payload.runtimeState === "idle" ||
      payload.runtimeState === "requires_action"
        ? payload.runtimeState
        : "idle"
    sqlite
      .prepare(
        `update session_attention
         set runtime_state = ?, has_runtime_state = 1 where session_id = ?`
      )
      .run(state, event.session_id)
  }
}

const projectAttentionTurnStart = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord
): void => {
  if (event.kind === "session.updated" && payload.turnState === "started") {
    sqlite
      .prepare(
        `update session_attention set turn_active = 1, settle_due_at = null,
           errored = case when ? = 'user' then 0 else errored end
         where session_id = ?`
      )
      .run(payload.initiatedBy === "agent" ? "agent" : "user", event.session_id)
  }
}

const projectUserConversationAttention = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord
): void => {
  const conversation =
    event.kind === "session.output" ? conversationEventPayload(payload) : undefined
  if (conversation?.role === "user") {
    sqlite
      .prepare(
        `update session_attention set pending_plan_approval = 0, errored = 0,
           turn_active = case when ? then 1 else turn_active end,
           settle_due_at = case when ? then null else settle_due_at end
         where session_id = ?`
      )
      .run(
        payload.startsTurn === true ? 1 : 0,
        payload.startsTurn === true ? 1 : 0,
        event.session_id
      )
  }
}

const completedTurnNeedsPlanApproval = (
  sqlite: Database.Database,
  event: SessionEventRow,
  initiatedBy: "agent" | "user"
): boolean => {
  const state = modeRows.one(
    sqlite
      .prepare(
        `select sa.current_mode_id, s.harness_id
         from session_attention sa join sessions s on s.id = sa.session_id
         where sa.session_id = ?`
      )
      .get(event.session_id)
  )
  const completedTurnPlan = sqlite
    .prepare(
      `select 1 from session_events se
         join chat_parts cp on cp.item_id = se.chat_item_id and cp.kind = 'plan'
         where se.session_id = ? and se.revision = ?
           and cp.text is not null and length(cp.text) > 0
         limit 1`
    )
    .get(event.session_id, event.revision)
  return (
    initiatedBy === "user" &&
    state.harness_id === "codex" &&
    state.current_mode_id === "plan" &&
    completedTurnPlan !== undefined
  )
}

const projectTerminalAttention = (
  sqlite: Database.Database,
  event: SessionEventRow,
  payload: JsonRecord
): void => {
  if (isTurnEnd(event, payload)) {
    const initiatedBy = payload.initiatedBy === "agent" ? "agent" : "user"
    const failed = terminalAttentionError(event, payload)
    sqlite
      .prepare("update session_attention set turn_active = 0 where session_id = ?")
      .run(event.session_id)

    const needsPlanApproval = completedTurnNeedsPlanApproval(sqlite, event, initiatedBy)

    if (failed) {
      sqlite
        .prepare("update session_attention set errored = 1 where session_id = ?")
        .run(event.session_id)
      bumpAttentionRevision(sqlite, event.session_id)
    } else if (needsPlanApproval) {
      sqlite
        .prepare(
          `update session_attention set pending_plan_approval = 1,
             pending_finish = 0, settle_due_at = null where session_id = ?`
        )
        .run(event.session_id)
    } else if (sessionIsHeld(sqlite, event.session_id)) {
      sqlite
        .prepare(
          "update session_attention set pending_finish = 1, settle_due_at = null where session_id = ?"
        )
        .run(event.session_id)
    } else if (sessionHasQueuedPrompts(sqlite, event.session_id)) {
      sqlite
        .prepare(
          "update session_attention set pending_finish = 1, settle_due_at = ? where session_id = ?"
        )
        .run(event.created_at, event.session_id)
    } else {
      bumpAttentionRevision(sqlite, event.session_id)
    }
  }
}
