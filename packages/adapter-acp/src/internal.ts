import type { RuntimeEvent } from "@codevisor/agent-runtime"

import type { AcpPromptResult } from "./connection.js"

export const turnLifecycleEvent = (
  sessionId: string,
  turnId: string,
  turnState: "started" | "ended",
  stop: Partial<AcpPromptResult> = {}
): RuntimeEvent => ({
  kind: "session.updated",
  subjectId: sessionId,
  payload: {
    initiatedBy: "user",
    turnId,
    turnState,
    ...(stop.stopReason === undefined ? {} : { stopReason: stop.stopReason }),
    ...(stop.stopDetail === undefined ? {} : { stopDetail: stop.stopDetail }),
    ...(stop.stopKind === undefined ? {} : { stopKind: stop.stopKind }),
    ...(stop.resetsAt === undefined ? {} : { resetsAt: stop.resetsAt }),
    ...(stop.retryable === true ? { retryable: true } : {})
  }
})

/* v8 ignore start */
export const isGenericConnectionClose = (message: string): boolean =>
  /^acp connection closed\.?$/i.test(message.trim())
/* v8 ignore stop */
