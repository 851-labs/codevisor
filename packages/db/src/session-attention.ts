import type { SessionSidebarState } from "@codevisor/api"
import type Database from "better-sqlite3"
import { sessionGoalSnapshot } from "./chat-items.js"
import type { JsonRecord } from "./event-payloads.js"
import { backgroundTasksFromRaw, conversationEventPayload, jsonRecord } from "./event-payloads.js"
import type { SessionEventRow } from "./rows.js"

export const ensureSessionAttentionState = (sqlite: Database.Database, sessionId: string): void => {
  sqlite
    .prepare("insert into session_attention_state (session_id) values (?) on conflict do nothing")
    .run(sessionId)
}

const appendSessionAttention = (
  sqlite: Database.Database,
  event: SessionEventRow,
  kind: "finished" | "action_required",
  hasError: boolean
): void => {
  const next = sqlite
    .prepare(
      "select coalesce(max(sequence), 0) + 1 as sequence from session_attention_events where session_id = ?"
    )
    .get(event.session_id) as { readonly sequence: number }
  sqlite
    .prepare(
      `insert into session_attention_events (
         session_id, sequence, source_revision, kind, has_error, created_at
       ) values (?, ?, ?, ?, ?, ?)
       on conflict(session_id, source_revision, kind) do nothing`
    )
    .run(event.session_id, next.sequence, event.revision, kind, hasError ? 1 : 0, event.created_at)
}

const sessionHasActiveGoal = (sqlite: Database.Database, sessionId: string): boolean =>
  sessionGoalSnapshot(sqlite, sessionId)?.status === "active"

const releasePendingSessionAttention = (
  sqlite: Database.Database,
  event: SessionEventRow
): void => {
  const state = sqlite
    .prepare("select * from session_attention_state where session_id = ?")
    .get(event.session_id) as
    | {
        readonly pending_epoch: number
        readonly pending_error: number
        readonly turn_active: number
        readonly runtime_state: string
        readonly has_runtime_state: number
        readonly pending_plan_approval: number
      }
    | undefined
  if (
    state === undefined ||
    state.pending_epoch !== 1 ||
    state.turn_active === 1 ||
    state.pending_plan_approval === 1 ||
    sessionHasActiveGoal(sqlite, event.session_id)
  ) {
    return
  }
  const session = sqlite
    .prepare("select background_tasks, pending_question from sessions where id = ?")
    .get(event.session_id) as {
    readonly background_tasks: string
    readonly pending_question: string | null
  }
  const tasks = JSON.parse(session.background_tasks) as unknown
  if (
    (Array.isArray(tasks) && tasks.length > 0) ||
    session.pending_question !== null ||
    (state.has_runtime_state === 1 && state.runtime_state !== "idle")
  ) {
    return
  }
  appendSessionAttention(sqlite, event, "finished", state.pending_error === 1)
  sqlite
    .prepare(
      "update session_attention_state set pending_epoch = 0, pending_error = 0 where session_id = ?"
    )
    .run(event.session_id)
}

const terminalAttentionError = (event: SessionEventRow, payload: JsonRecord): boolean =>
  event.kind === "session.error" ||
  typeof payload.stopDetail === "string" ||
  (typeof payload.stopReason === "string" &&
    payload.stopReason !== "end_turn" &&
    payload.stopReason !== "cancelled")

/// Projects the append-only runtime log into durable, cross-device attention
/// state. This runs in the same SQLite transaction as the source event, so a
/// reconnect cannot observe a terminal/question event without its unread or
/// action-required consequence.
export const projectSessionAttention = (
  sqlite: Database.Database,
  event: SessionEventRow
): void => {
  const payload = jsonRecord(JSON.parse(event.payload))
  if (payload === undefined) return
  ensureSessionAttentionState(sqlite, event.session_id)

  if (event.kind === "session.updated" && typeof payload.modeId === "string") {
    sqlite
      .prepare(
        `update session_attention_state set current_mode_id = ?,
           pending_plan_approval = case when ? = 'plan' then pending_plan_approval else 0 end
         where session_id = ?`
      )
      .run(payload.modeId, payload.modeId, event.session_id)
  }
  if (event.kind === "session.updated" && typeof payload.runtimeState === "string") {
    const state =
      payload.runtimeState === "running" ||
      payload.runtimeState === "idle" ||
      payload.runtimeState === "requires_action"
        ? payload.runtimeState
        : "idle"
    sqlite
      .prepare(
        `update session_attention_state
         set runtime_state = ?, has_runtime_state = 1 where session_id = ?`
      )
      .run(state, event.session_id)
  }
  if (event.kind === "session.updated" && payload.turnState === "started") {
    sqlite
      .prepare("update session_attention_state set turn_active = 1 where session_id = ?")
      .run(event.session_id)
  }

  const conversation =
    event.kind === "session.output" ? conversationEventPayload(payload) : undefined
  if (conversation?.role === "user") {
    sqlite
      .prepare("update session_attention_state set pending_plan_approval = 0 where session_id = ?")
      .run(event.session_id)
  }

  const update = typeof payload.sessionUpdate === "string" ? payload.sessionUpdate : undefined
  if (
    event.kind === "session.output" &&
    update === "question" &&
    typeof payload.questionId === "string" &&
    Array.isArray(payload.questions)
  ) {
    appendSessionAttention(sqlite, event, "action_required", false)
  }

  const terminal =
    event.kind === "session.error" ||
    (event.kind === "session.updated" &&
      (payload.turnState === "ended" || typeof payload.stopReason === "string"))
  if (terminal) {
    const initiatedBy = payload.initiatedBy === "agent" ? "agent" : "user"
    const failed = terminalAttentionError(event, payload)
    sqlite
      .prepare("update session_attention_state set turn_active = 0 where session_id = ?")
      .run(event.session_id)

    const state = sqlite
      .prepare(
        `select ast.current_mode_id, s.harness_id
         from session_attention_state ast join sessions s on s.id = ast.session_id
         where ast.session_id = ?`
      )
      .get(event.session_id) as {
      readonly current_mode_id: string | null
      readonly harness_id: string
    }
    // The terminal event is routed to the assistant item it completed by the
    // chat projection immediately above. Only a plan produced by that turn
    // should raise approval; an older plan elsewhere in the transcript must
    // not make every later plan-mode turn actionable.
    const completedTurnPlan = sqlite
      .prepare(
        `select 1 from session_events se
         join chat_parts cp on cp.item_id = se.chat_item_id and cp.kind = 'plan'
         where se.session_id = ? and se.revision = ?
           and cp.text is not null and length(cp.text) > 0
         limit 1`
      )
      .get(event.session_id, event.revision)
    const needsPlanApproval =
      initiatedBy === "user" &&
      state.harness_id === "codex" &&
      state.current_mode_id === "plan" &&
      completedTurnPlan !== undefined

    if (needsPlanApproval) {
      sqlite
        .prepare(
          `update session_attention_state set pending_plan_approval = 1,
             pending_epoch = 0, pending_error = 0 where session_id = ?`
        )
        .run(event.session_id)
      appendSessionAttention(sqlite, event, "action_required", failed)
    } else if (initiatedBy === "user") {
      sqlite
        .prepare(
          `update session_attention_state set pending_epoch = 1,
             pending_error = max(pending_error, ?) where session_id = ?`
        )
        .run(failed ? 1 : 0, event.session_id)
    } else {
      const current = sqlite
        .prepare("select pending_epoch from session_attention_state where session_id = ?")
        .get(event.session_id) as { readonly pending_epoch: number }
      if (current.pending_epoch === 1 || failed) {
        sqlite
          .prepare(
            `update session_attention_state set pending_epoch = 1,
               pending_error = max(pending_error, ?) where session_id = ?`
          )
          .run(failed ? 1 : 0, event.session_id)
      }
    }
  }

  releasePendingSessionAttention(sqlite, event)
}

/** Computes the one mutually exclusive state rendered by native sidebars.
 *  Classification mirrors the native icon precedence. In particular, unread
 *  activity buffered behind a still-running turn remains `inProgress` until
 *  the overall activity epoch settles. */
const sessionSidebarState = (sqlite: Database.Database, sessionId: string): SessionSidebarState => {
  const state = sqlite
    .prepare(
      `select s.pending_question, s.background_tasks,
         coalesce(ast.turn_active, 0) as turn_active,
         coalesce(ast.runtime_state, 'idle') as runtime_state,
         coalesce(ast.has_runtime_state, 0) as has_runtime_state,
         coalesce(ast.pending_plan_approval, 0) as pending_plan_approval,
         coalesce(rs.last_seen_sequence, 0) as last_seen_sequence,
         coalesce(rs.manually_unread, 0) as manually_unread
       from sessions s
       left join session_attention_state ast on ast.session_id = s.id
       left join session_read_state rs
         on rs.session_id = s.id and rs.reader_id = 'owner'
       where s.id = ?`
    )
    .get(sessionId) as {
    readonly pending_question: string | null
    readonly background_tasks: string
    readonly turn_active: number
    readonly runtime_state: string
    readonly has_runtime_state: number
    readonly pending_plan_approval: number
    readonly last_seen_sequence: number
    readonly manually_unread: number
  }

  const unread = sqlite
    .prepare(
      `select count(*) as count,
         coalesce(max(case when has_error = 1 then 1 else 0 end), 0) as has_error
       from session_attention_events
       where session_id = ? and sequence > ?`
    )
    .get(sessionId, state.last_seen_sequence) as {
    readonly count: number
    readonly has_error: number
  }
  if (unread.has_error === 1) return "errored"
  if (state.pending_question !== null || state.pending_plan_approval === 1) {
    return "waitingForUser"
  }
  const waitingOnBackgroundTasks = backgroundTasksFromRaw(state.background_tasks).some(
    (task) => task.terminalKey === undefined
  )
  if (
    state.turn_active === 1 ||
    waitingOnBackgroundTasks ||
    (state.has_runtime_state === 1 && state.runtime_state === "running")
  ) {
    return "inProgress"
  }
  if (state.manually_unread === 1 || unread.count > 0) return "unread"
  return "idle"
}

/** Advances the ordering clock only when the visible native-sidebar state
 *  actually changes. Callers run this in the same transaction as event
 *  projections, so a snapshot cannot expose the new state with an old clock. */
export const projectSessionSidebarState = (
  sqlite: Database.Database,
  sessionId: string,
  changedAt: string
): boolean => {
  const next = sessionSidebarState(sqlite, sessionId)
  const current = sqlite
    .prepare("select sidebar_state from sessions where id = ?")
    .get(sessionId) as { readonly sidebar_state: SessionSidebarState }
  if (current.sidebar_state === next) return false
  sqlite
    .prepare("update sessions set sidebar_state = ?, sidebar_state_changed_at = ? where id = ?")
    .run(next, changedAt, sessionId)
  return true
}
