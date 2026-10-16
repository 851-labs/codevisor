import type { RuntimeEvent } from "@codevisor/agent-runtime"
import type { TurnStopKind } from "@codevisor/api"

export const turnLifecycleEvent = (
  sessionId: string,
  turnId: string,
  turnState: "started" | "ended",
  stopReason?: string,
  stopDetail?: string,
  retryable?: boolean,
  stopKind?: TurnStopKind
): RuntimeEvent => ({
  kind: "session.updated",
  subjectId: sessionId,
  payload: {
    initiatedBy: "user",
    turnId,
    turnState,
    ...(stopReason === undefined ? {} : { stopReason }),
    ...(stopDetail === undefined ? {} : { stopDetail }),
    ...(stopKind === undefined ? {} : { stopKind }),
    ...(retryable === true ? { retryable: true } : {})
  }
})

/* v8 ignore start */
export const isGenericConnectionClose = (message: string): boolean =>
  /^acp connection closed\.?$/i.test(message.trim())
/* v8 ignore stop */
