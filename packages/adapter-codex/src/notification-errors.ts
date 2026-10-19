import { codexErrorDetails, codexRetryStatus, codexSignedOutDetail } from "./errors.js"
import { isRecord } from "./internal.js"
import type { CodexSession } from "./session.js"

const signedOutError = {
  message: codexSignedOutDetail,
  retryable: false,
  stopKind: "authRequired" as const
}

export const confirmSignedOut = async (
  session: CodexSession,
  status: string,
  error: CodexSession["pendingTurnError"],
  sharedAuthRejected: boolean
): Promise<CodexSession["pendingTurnError"]> => {
  if (status !== "failed" || error === undefined || error.stopKind !== undefined) return error
  if (sharedAuthRejected) return signedOutError
  try {
    const result = await session.client.request<unknown>("account/read", { refreshToken: false })
    return isRecord(result) && result.account === null && result.requiresOpenaiAuth === true
      ? signedOutError
      : error
  } catch {
    return error
  }
}

export const rejectsReasoningSummaries = (message: string): boolean =>
  /reasoning summar/i.test(message) && /verif/i.test(message)

export const handleNotificationError = (
  session: CodexSession,
  payload: Record<string, unknown>
): void => {
  const terminalError = codexErrorDetails(payload)
  if (terminalError.stopKind === "authRequired" && session.activeTurnId !== undefined) {
    if (session.pendingTurnError?.stopKind !== "authRequired") {
      session.pendingTurnError = terminalError
      void session.client
        .request("turn/interrupt", { threadId: session.threadId, turnId: session.activeTurnId })
        .catch(() => undefined)
    }
    return
  }
  if (payload.willRetry === true) {
    const heldOrActiveTurnId = session.heldTurnId ?? session.activeTurnId
    void session.emit({
      kind: "session.updated",
      payload: {
        retrying: codexRetryStatus(payload),
        ...(heldOrActiveTurnId === undefined ? {} : { turnId: heldOrActiveTurnId })
      },
      subjectId: session.key
    })
    return
  }
  if (session.activeTurnId !== undefined) {
    session.pendingTurnError = terminalError
    return
  }
  void session.emit({
    kind: "session.error",
    payload: { message: terminalError.message },
    subjectId: session.key
  })
}
