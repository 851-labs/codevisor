import type { BackgroundTask, SessionSidebarState } from "@codevisor/api"
import type Database from "better-sqlite3"
import { sessionGoalSnapshot } from "./chat-items.js"
import type { JsonRecord } from "./event-payloads.js"
import { backgroundTasksFromRaw, conversationEventPayload, jsonRecord } from "./event-payloads.js"
import type { SessionEventRow } from "./rows.js"

/// How long a released hold (subagent finished, goal cleared) may sit quiet
/// before the turn counts as finished and the unread revision advances. The
/// Claude harness re-invokes the agent via a task notification seconds after a
/// subagent completes; this grace absorbs that gap (and gaps between
/// sequential subagents) so a chain of agent turns settles exactly once.
export const ATTENTION_SETTLE_GRACE_MS = 12_000

export const ensureSessionAttentionState = (sqlite: Database.Database, sessionId: string): void => {
  sqlite
    .prepare("insert into session_attention (session_id) values (?) on conflict do nothing")
    .run(sessionId)
}

interface AttentionRow {
  readonly attention_revision: number
  readonly turn_active: number
  readonly runtime_state: string
  readonly has_runtime_state: number
  readonly current_mode_id: string | null
  readonly pending_plan_approval: number
  readonly errored: number
  readonly pending_finish: number
  readonly settle_due_at: string | null
}

const attentionRow = (sqlite: Database.Database, sessionId: string): AttentionRow | undefined =>
  sqlite.prepare("select * from session_attention where session_id = ?").get(sessionId) as
    | AttentionRow
    | undefined

const sessionHasActiveGoal = (sqlite: Database.Database, sessionId: string): boolean =>
  sessionGoalSnapshot(sqlite, sessionId)?.status === "active"

/// Only work that verifiably completes AND re-invokes the agent holds a
/// finished turn in `inProgress`: running subagents. Background shells
/// (`terminalKey` mirrors, codex/acp `shell` tasks) deliberately do not — a
/// dev server left running must not pin a chat in progress forever. If a
/// shell exit later re-invokes the agent, that continuation is its own turn
/// and settles into one more unread revision.
const holdsInProgress = (task: BackgroundTask): boolean => task.taskType === "subagent"

const sessionIsHeld = (sqlite: Database.Database, sessionId: string): boolean => {
  const session = sqlite
    .prepare("select background_tasks from sessions where id = ?")
    .get(sessionId) as { readonly background_tasks: string } | undefined
  /* v8 ignore next -- attention rows cascade with their session; a missing
     session row here is unreachable outside FK-disabled surgery. */
  if (session === undefined) return false
  return (
    backgroundTasksFromRaw(session.background_tasks).some(holdsInProgress) ||
    sessionHasActiveGoal(sqlite, sessionId)
  )
}

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

/// Re-evaluates a deferred finish. Runs at the end of every projection so the
/// state converges even without the server-side timer: a hold re-appearing
/// disarms the deadline, a released hold arms it, and an expired deadline
/// settles in-transaction with whatever event happened to arrive next. The
/// scheduler in apps/server only makes expiry prompt.
const reevaluatePendingFinish = (
  sqlite: Database.Database,
  sessionId: string,
  now: string,
  graceMs: number
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
  if (state.settle_due_at === null) {
    const dueAt = new Date(Date.parse(now) + graceMs).toISOString()
    sqlite
      .prepare("update session_attention set settle_due_at = ? where session_id = ?")
      .run(dueAt, sessionId)
    return
  }
  if (state.settle_due_at <= now) {
    bumpAttentionRevision(sqlite, sessionId)
  }
}

/// Attempts to settle a deferred finish into an unread revision bump. Called
/// by the server's settle scheduler when a grace deadline fires; idempotent
/// and re-validating, so a race with a turn that started (or a hold that
/// re-appeared) after the timer was armed is harmless.
export const settleSessionAttention = (
  sqlite: Database.Database,
  sessionId: string,
  now: string,
  graceMs: number = ATTENTION_SETTLE_GRACE_MS
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
  const dueAt = state.settle_due_at ?? new Date(Date.parse(now) + graceMs).toISOString()
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

/// Sessions with a finish waiting to settle, for restart recovery. Startup
/// reconciliation has already cleared stale background-task snapshots by the
/// time recovery runs, so these settle (after their grace) rather than hang.
export const listPendingAttentionSettles = (
  sqlite: Database.Database
): ReadonlyArray<{ readonly sessionId: string; readonly dueAt: string | null }> =>
  (
    sqlite
      .prepare("select session_id, settle_due_at from session_attention where pending_finish = 1")
      .all() as ReadonlyArray<{
      readonly session_id: string
      readonly settle_due_at: string | null
    }>
  ).map((row) => ({ sessionId: row.session_id, dueAt: row.settle_due_at }))

export const attentionSettleDeadline = (
  sqlite: Database.Database,
  sessionId: string
): string | undefined => {
  const row = sqlite
    .prepare(
      "select settle_due_at from session_attention where session_id = ? and pending_finish = 1 and turn_active = 0"
    )
    .get(sessionId) as { readonly settle_due_at: string | null } | undefined
  return row?.settle_due_at ?? undefined
}

/// Projects the append-only runtime log into durable, cross-device attention
/// state. This runs in the same SQLite transaction as the source event, so a
/// reconnect cannot observe a terminal event without its unread consequence.
///
/// The model: one monotonic `attention_revision` per session (unread =
/// revision ahead of the shared read cursor), plus intrinsic flags for the
/// action-required tier (`errored` here; question/plan-approval live on the
/// session row). There is no event ledger and no receipt target — reading is
/// a cursor advance, performed by clients when the chat is focused.
export const projectSessionAttention = (
  sqlite: Database.Database,
  event: SessionEventRow,
  graceMs: number = ATTENTION_SETTLE_GRACE_MS
): void => {
  const payload = jsonRecord(JSON.parse(event.payload))
  if (payload === undefined) return
  ensureSessionAttentionState(sqlite, event.session_id)

  if (event.kind === "session.updated" && typeof payload.modeId === "string") {
    sqlite
      .prepare(
        `update session_attention set current_mode_id = ?,
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
        `update session_attention
         set runtime_state = ?, has_runtime_state = 1 where session_id = ?`
      )
      .run(state, event.session_id)
  }
  if (event.kind === "session.updated" && payload.turnState === "started") {
    // A new turn cancels any armed grace deadline but keeps `pending_finish`:
    // a chain of agent continuations settles once, at the end of the chain.
    // A user-initiated turn is the user acting in this chat — it clears the
    // errored flag (the user has unblocked it).
    sqlite
      .prepare(
        `update session_attention set turn_active = 1, settle_due_at = null,
           errored = case when ? = 'user' then 0 else errored end
         where session_id = ?`
      )
      .run(payload.initiatedBy === "agent" ? "agent" : "user", event.session_id)
  }

  const conversation =
    event.kind === "session.output" ? conversationEventPayload(payload) : undefined
  if (conversation?.role === "user") {
    sqlite
      .prepare(
        "update session_attention set pending_plan_approval = 0, errored = 0 where session_id = ?"
      )
      .run(event.session_id)
  }

  const terminal =
    event.kind === "session.error" ||
    (event.kind === "session.updated" &&
      (payload.turnState === "ended" || typeof payload.stopReason === "string"))
  if (terminal) {
    const initiatedBy = payload.initiatedBy === "agent" ? "agent" : "user"
    const failed = terminalAttentionError(event, payload)
    sqlite
      .prepare("update session_attention set turn_active = 0 where session_id = ?")
      .run(event.session_id)

    const state = sqlite
      .prepare(
        `select sa.current_mode_id, s.harness_id
         from session_attention sa join sessions s on s.id = sa.session_id
         where sa.session_id = ?`
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

    if (failed) {
      // Errors are the urgent flavor of unread: they rank in the
      // action-required tier until acknowledged, and the revision bump makes
      // the turn read normally once the errored flag clears.
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
      // Waiting on a subagent (or an active goal): the agent will continue.
      // Not ready for the user yet — stay inProgress with the finish parked.
      sqlite
        .prepare(
          "update session_attention set pending_finish = 1, settle_due_at = null where session_id = ?"
        )
        .run(event.session_id)
    } else {
      // Finished — user- and agent-initiated turns alike. A turn that ends
      // with only background shells running counts as finished: whatever the
      // agent left running (a dev server) is FOR the user to look at.
      bumpAttentionRevision(sqlite, event.session_id)
    }
  }

  reevaluatePendingFinish(sqlite, event.session_id, event.created_at, graceMs)
}

/** Computes the one mutually exclusive state rendered by native sidebars.
 *  Precedence: actionRequired (errored, then waitingForUser) > inProgress >
 *  unread > idle. A parked finish (`pending_finish`) renders as inProgress so
 *  the settle grace never flashes idle between agent continuations. */
const sessionSidebarState = (sqlite: Database.Database, sessionId: string): SessionSidebarState => {
  const state = sqlite
    .prepare(
      `select s.pending_question, s.background_tasks,
         coalesce(sa.attention_revision, 0) as attention_revision,
         coalesce(sa.turn_active, 0) as turn_active,
         coalesce(sa.runtime_state, 'idle') as runtime_state,
         coalesce(sa.has_runtime_state, 0) as has_runtime_state,
         coalesce(sa.pending_plan_approval, 0) as pending_plan_approval,
         coalesce(sa.errored, 0) as errored,
         coalesce(sa.pending_finish, 0) as pending_finish,
         coalesce(rs.last_seen_sequence, 0) as last_seen_sequence,
         coalesce(rs.manually_unread, 0) as manually_unread
       from sessions s
       left join session_attention sa on sa.session_id = s.id
       left join session_read_state rs
         on rs.session_id = s.id and rs.reader_id = 'owner'
       where s.id = ?`
    )
    .get(sessionId) as {
    readonly pending_question: string | null
    readonly background_tasks: string
    readonly attention_revision: number
    readonly turn_active: number
    readonly runtime_state: string
    readonly has_runtime_state: number
    readonly pending_plan_approval: number
    readonly errored: number
    readonly pending_finish: number
    readonly last_seen_sequence: number
    readonly manually_unread: number
  }

  if (state.errored === 1) return "errored"
  if (state.pending_question !== null || state.pending_plan_approval === 1) {
    return "waitingForUser"
  }
  const held = backgroundTasksFromRaw(state.background_tasks).some(holdsInProgress)
  if (
    state.turn_active === 1 ||
    state.pending_finish === 1 ||
    held ||
    (state.has_runtime_state === 1 && state.runtime_state === "running")
  ) {
    return "inProgress"
  }
  if (state.manually_unread === 1 || state.attention_revision > state.last_seen_sequence) {
    return "unread"
  }
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
