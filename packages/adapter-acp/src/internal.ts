// Shared internals for the split ACP provider modules.
import type { RuntimeEvent } from "@codevisor/agent-runtime"

export const turnLifecycleEvent = (
  sessionId: string,
  turnId: string,
  turnState: "started" | "ended",
  stopReason?: string,
  stopDetail?: string,
  retryable?: boolean
): RuntimeEvent => ({
  kind: "session.updated",
  subjectId: sessionId,
  payload: {
    initiatedBy: "user",
    turnId,
    turnState,
    ...(stopReason === undefined ? {} : { stopReason }),
    ...(stopDetail === undefined ? {} : { stopDetail }),
    ...(retryable === true ? { retryable: true } : {})
  }
})

/* v8 ignore start -- stdio ACP adapter is exercised by integration/packaging smoke tests. */
/// The ACP SDK's placeholder rejection for a connection that ended without a
/// specific reason (`@agentclientprotocol/sdk`'s `jsonrpc` close path). It
/// carries no diagnostic value, so callers substitute the child's stderr.
export const isGenericConnectionClose = (message: string): boolean =>
  /^acp connection closed\.?$/i.test(message.trim())
/* v8 ignore stop */
