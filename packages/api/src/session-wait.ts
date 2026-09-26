import { Schema } from "effect"

import { QuestionPayload } from "./session-updates.js"
import { SessionSidebarState } from "./sessions.js"

export const DEFAULT_SESSION_WAIT_UNTIL: ReadonlyArray<SessionSidebarState> = [
  "idle",
  "waitingForUser",
  "errored"
]
export const DEFAULT_SESSION_WAIT_TIMEOUT_MS = 60_000
export const MAX_SESSION_WAIT_TIMEOUT_MS = 300_000

/// Long-poll until any listed session is in one of the `until` states.
export const WaitForSessionsRequest = Schema.Struct({
  ids: Schema.Array(Schema.String),
  until: Schema.optional(Schema.Array(SessionSidebarState)),
  timeoutMs: Schema.optional(Schema.Number)
})
export type WaitForSessionsRequest = typeof WaitForSessionsRequest.Type

export const WaitedSession = Schema.Struct({
  id: Schema.String,
  sidebarState: SessionSidebarState,
  actionRequiredKind: Schema.optional(Schema.Literals(["question", "planApproval"])),
  pendingQuestion: Schema.optional(QuestionPayload)
})
export type WaitedSession = typeof WaitedSession.Type

export const WaitForSessionsResponse = Schema.Struct({
  sessions: Schema.Array(WaitedSession),
  timedOut: Schema.Boolean
})
export type WaitForSessionsResponse = typeof WaitForSessionsResponse.Type
