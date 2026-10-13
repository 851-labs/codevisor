import type { BackgroundTask, SessionSidebarState } from "@codevisor/api"
import type Database from "better-sqlite3"

import { backgroundTasksFromRaw } from "./event-payloads.js"

/// Only work that verifiably completes AND re-invokes the agent holds a
/// finished turn in `inProgress`: running subagents. Background shells and
/// watchers (codex/acp `shell` tasks, Claude's
/// `Monitor`/`local_bash`) deliberately do not — a dev server or a `tail -f`
/// that never fires must not pin a chat in progress until its timeout. If
/// one later re-invokes the agent, that continuation is its own turn and
/// settles into one more unread revision. The native clients apply the same
/// rule to the transcript's "Waiting on…" line
/// (`SessionModel.waitingBackgroundTasks`), so the two surfaces agree.
export const holdsInProgress = (task: BackgroundTask): boolean => task.taskType === "subagent"

const readSidebarState = (sqlite: Database.Database, sessionId: string) => {
  return sqlite
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
}

/** Computes the one mutually exclusive state rendered by native sidebars.
 *  Precedence: actionRequired (errored, then waitingForUser) > inProgress >
 *  unread > idle. A parked finish (`pending_finish`) renders as inProgress so
 *  the settle grace never flashes idle between agent continuations. */
const sidebarStateFromRow = (state: ReturnType<typeof readSidebarState>): SessionSidebarState => {
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
  const next = sidebarStateFromRow(readSidebarState(sqlite, sessionId))
  const current = sqlite
    .prepare("select sidebar_state from sessions where id = ?")
    .get(sessionId) as { readonly sidebar_state: SessionSidebarState }
  if (current.sidebar_state === next) return false
  sqlite
    .prepare("update sessions set sidebar_state = ?, sidebar_state_changed_at = ? where id = ?")
    .run(next, changedAt, sessionId)
  return true
}
