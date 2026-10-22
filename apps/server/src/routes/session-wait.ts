import {
  DEFAULT_SESSION_WAIT_TIMEOUT_MS,
  DEFAULT_SESSION_WAIT_UNTIL,
  MAX_SESSION_WAIT_TIMEOUT_MS,
  type EventEnvelope,
  type QuestionPayload,
  type SessionSidebarState,
  type SessionSummary,
  type WaitedSession,
  type WaitForSessionsRequest,
  type WaitForSessionsResponse
} from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"

import { HttpFailure, run } from "../server-context.js"
import type { EventFanout } from "../server-context.js"

const wakingKinds: ReadonlySet<EventEnvelope["kind"]> = new Set([
  "session.attention.updated",
  "session.queue.updated",
  "session.updated",
  "session.deleted"
])

/* v8 ignore next */
const sidebarStateOf = (session: SessionSummary): SessionSidebarState =>
  session.sidebarState ?? "idle"

const settledIn = async (
  db: CodevisorDatabaseService,
  session: SessionSummary,
  until: ReadonlySet<SessionSidebarState>
): Promise<boolean> => {
  const state = sidebarStateOf(session)
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
  let pendingQuestion: QuestionPayload | undefined
  if (session.actionRequiredKind === "question") {
    pendingQuestion = await run(db.getSessionPendingQuestion(session.id))
  }
  return {
    id: session.id,
    sidebarState: sidebarStateOf(session),
    ...(session.actionRequiredKind === undefined
      ? {}
      : { actionRequiredKind: session.actionRequiredKind }),
    ...(pendingQuestion === undefined ? {} : { pendingQuestion })
  }
}

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
  let failure: { readonly error: unknown } | undefined
  let checks: Promise<void> = Promise.resolve()
  const woke = Promise.withResolvers<void>()
  const wake = (): void => {
    woken = true
    woke.resolve()
  }
  const check = (id: string): Promise<void> =>
    (checks = checks
      .then(async () => {
        if (woken) return
        const session = await run(db.getSessionSummary(id)).catch(() => undefined)
        if (session === undefined || (await settledIn(db, session, until))) {
          changed = true
          wake()
        }
      })
      .catch((error: unknown) => {
        failure ??= { error }
        wake()
      }))

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
    if (failure !== undefined) throw failure.error
    const current = await Promise.all(
      ids.map((id) => run(db.getSessionSummary(id)).catch(() => undefined))
    )
    return {
      sessions: await Promise.all(
        current.flatMap((session) => {
          if (session === undefined) return []
          return [waitedSession(db, session)]
        })
      ),
      timedOut: !changed
    }
  } finally {
    clearTimeout(timer)
    signal.removeEventListener("abort", wake)
    unsubscribe()
  }
}
