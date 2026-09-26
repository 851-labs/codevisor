import {
  DEFAULT_SESSION_WAIT_TIMEOUT_MS,
  DEFAULT_SESSION_WAIT_UNTIL,
  MAX_SESSION_WAIT_TIMEOUT_MS,
  type EventEnvelope,
  type SessionSidebarState,
  type SessionSummary,
  type WaitedSession,
  type WaitForSessionsRequest,
  type WaitForSessionsResponse
} from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"

import { HttpFailure, run } from "../server-context.js"
import type { EventFanout } from "../server-context.js"

/// Events after which a watched session's sidebar state or queue may differ.
const wakingKinds: ReadonlySet<EventEnvelope["kind"]> = new Set([
  "session.attention.updated",
  "session.queue.updated",
  "session.updated",
  "session.deleted"
])

/// Whether a session is in one of the requested states. A finished turn
/// nobody has read yet shows as `unread`, which is `idle` with news, so it
/// satisfies `idle`. A session with prompts still queued or starting is
/// not idle even before its turn has begun, so `prompt` then `wait` never
/// resolves on the stale pre-turn state.
const settledIn = async (
  db: CodevisorDatabaseService,
  session: SessionSummary,
  until: ReadonlySet<SessionSidebarState>
): Promise<boolean> => {
  // Local summaries always carry the projected state (optional only on the wire).
  const state = session.sidebarState as SessionSidebarState
  if (state !== "idle" && state !== "unread") return until.has(state)
  if (!until.has(state) && !until.has("idle")) return false
  const queued = await run(db.listPromptQueue(session.id))
  const processing = await run(db.listProcessingPromptQueue(session.id))
  return queued.length === 0 && processing.length === 0
}

const waitedSession = async (
  db: CodevisorDatabaseService,
  session: SessionSummary
): Promise<WaitedSession> => {
  const pendingQuestion =
    session.actionRequiredKind === "question"
      ? await run(db.getSessionPendingQuestion(session.id))
      : undefined
  return {
    id: session.id,
    sidebarState: session.sidebarState as SessionSidebarState,
    ...(session.actionRequiredKind === undefined
      ? {}
      : { actionRequiredKind: session.actionRequiredKind }),
    ...(pendingQuestion === undefined ? {} : { pendingQuestion })
  }
}

/// Long-polls until ANY listed session is in an `until` state (checked
/// immediately), the timeout passes, or `signal` aborts. A session deleted
/// mid-wait wakes it too and is omitted from the result.
export const waitForSessions = async (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  request: WaitForSessionsRequest,
  signal: AbortSignal
): Promise<WaitForSessionsResponse> => {
  const ids = [...new Set(request.ids.map((id) => id.toLowerCase()))]
  if (ids.length === 0) throw new HttpFailure(400, "ids must name at least one session")
  const until = new Set(request.until ?? DEFAULT_SESSION_WAIT_UNTIL)
  const timeoutMs = Math.min(
    Math.max(0, request.timeoutMs ?? DEFAULT_SESSION_WAIT_TIMEOUT_MS),
    MAX_SESSION_WAIT_TIMEOUT_MS
  )
  const known = new Set((await run(db.listSessions)).map((session) => session.id))
  const missing = ids.filter((id) => !known.has(id))
  if (missing.length > 0) throw new HttpFailure(404, `Session not found: ${missing.join(", ")}`)

  let woken = false
  let changed = false
  let checks: Promise<void> = Promise.resolve()
  const woke = Promise.withResolvers<void>()
  const wake = (): void => {
    woken = true
    woke.resolve()
  }
  // Re-evaluate one session. Checks run one at a time and stop once woken.
  const check = (id: string): Promise<void> =>
    (checks = checks.then(async () => {
      if (woken) return
      const session = await run(db.getSessionSummary(id)).catch(() => undefined)
      if (session === undefined || (await settledIn(db, session, until))) {
        changed = true
        wake()
      }
    }))

  // Subscribe before the first check so no transition slips between them.
  const unsubscribe = fanout.subscribe((event) => {
    if (wakingKinds.has(event.kind) && ids.includes(event.subjectId)) void check(event.subjectId)
  })
  signal.addEventListener("abort", wake)
  let timer: ReturnType<typeof setTimeout> | undefined
  try {
    await Promise.all(ids.map(check))
    timer = setTimeout(wake, timeoutMs)
    await woke.promise
    await checks
    const current = await Promise.all(
      ids.map((id) => run(db.getSessionSummary(id)).catch(() => undefined))
    )
    return {
      sessions: await Promise.all(
        current.flatMap((session) => (session === undefined ? [] : [waitedSession(db, session)]))
      ),
      timedOut: !changed
    }
  } finally {
    clearTimeout(timer)
    signal.removeEventListener("abort", wake)
    unsubscribe()
  }
}
