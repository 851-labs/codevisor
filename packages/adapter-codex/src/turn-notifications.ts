import { randomUUID } from "node:crypto"

import { codexErrorDetails } from "./errors.js"
import { flushPendingGoalSnapshot } from "./goals.js"
import { isRecord } from "./internal.js"
import { confirmSignedOut, rejectsReasoningSummaries } from "./notification-errors.js"
import { cancelPendingQuestions } from "./questions.js"
import { refreshCodexSessionTitle } from "./session-title.js"
import type { CodexSession } from "./session.js"
import { exhaustedWindowReset } from "./usage.js"

type TurnError = CodexSession["pendingTurnError"]

type PendingPrompt = CodexSession["pendingPrompt"]

interface TurnOutcome {
  readonly status: string
  readonly stopReason: "cancelled" | "end_turn"
  readonly reportedError: TurnError
}

interface UsageLimitReset {
  readonly resetsAt?: string
}

interface TurnEnding extends TurnOutcome {
  readonly sharedAuthRejected: boolean
  readonly turnId: string
  readonly pending: PendingPrompt
}

export const startNotificationTurn = (
  session: CodexSession,
  payload: Record<string, unknown>
): void => {
  const turn = isRecord(payload.turn) ? payload.turn : {}
  session.activeTurnId = typeof turn.id === "string" ? turn.id : randomUUID()
  session.pendingTurnError = undefined
  if (session.heldTurnId !== undefined) return

  void session.emit({
    kind: "session.updated",
    payload: {
      initiatedBy: session.pendingPrompt === undefined ? "agent" : "user",
      turnId: session.activeTurnId,
      turnState: "started"
    },
    subjectId: session.key
  })
}

export const completeNotificationTurn = (
  session: CodexSession,
  payload: Record<string, unknown>
): void => {
  const outcome = turnOutcome(session, payload)
  noteRejectedReasoningSummaries(session, outcome.reportedError)
  const sharedAuthRejected = session.client.authRejected?.() === true

  const turnId = endingTurnId(session)
  clearActiveTurn(session)
  if (awaitsAsyncAnswer(session, outcome)) {
    session.heldTurnId = turnId
    return
  }

  session.heldTurnId = undefined
  const pending = takePendingPrompt(session)
  cancelPendingQuestions(session)
  announceTurnEnd(session, { ...outcome, sharedAuthRejected, turnId, pending })
}

const turnOutcome = (session: CodexSession, payload: Record<string, unknown>): TurnOutcome => {
  const turn = isRecord(payload.turn) ? payload.turn : {}
  const status = typeof turn.status === "string" ? turn.status : "completed"
  const signedOut = signedOutMidTurn(session)
  return {
    status,
    stopReason: cancelledTurn(session, status, signedOut) ? "cancelled" : "end_turn",
    reportedError: reportedTurnError(session, turn, status, signedOut)
  }
}

const signedOutMidTurn = (session: CodexSession): boolean =>
  !session.interruptRequested && session.pendingTurnError?.stopKind === "authRequired"

const cancelledTurn = (session: CodexSession, status: string, signedOut: boolean): boolean =>
  !signedOut && (status === "interrupted" || session.interruptRequested)

const reportedTurnError = (
  session: CodexSession,
  turn: Record<string, unknown>,
  status: string,
  signedOut: boolean
): TurnError => {
  const completedError = failedTurnError(session, turn, status)
  if (signedOut) return session.pendingTurnError

  return completedError ?? session.pendingTurnError
}

const failedTurnError = (
  session: CodexSession,
  turn: Record<string, unknown>,
  status: string
): TurnError => {
  if (!failedOnItsOwn(session, turn, status)) return undefined

  return codexErrorDetails({ error: turn.error })
}

const failedOnItsOwn = (
  session: CodexSession,
  turn: Record<string, unknown>,
  status: string
): boolean => status === "failed" && !session.interruptRequested && isRecord(turn.error)

const noteRejectedReasoningSummaries = (session: CodexSession, error: TurnError): void => {
  if (error === undefined || !rejectsReasoningSummaries(error.message)) return

  session.reasoningSummariesRejected = true
}

const endingTurnId = (session: CodexSession): string =>
  session.heldTurnId ?? session.activeTurnId ?? randomUUID()

const clearActiveTurn = (session: CodexSession): void => {
  session.activeTurnId = undefined
  session.interruptRequested = false
  session.pendingTurnError = undefined
}

const awaitsAsyncAnswer = (session: CodexSession, outcome: TurnOutcome): boolean =>
  outcome.status === "completed" &&
  outcome.stopReason === "end_turn" &&
  outcome.reportedError === undefined &&
  session.asyncQuestion !== undefined

const takePendingPrompt = (session: CodexSession): PendingPrompt => {
  const pending = session.pendingPrompt
  session.pendingPrompt = undefined
  return pending
}

const announceTurnEnd = (session: CodexSession, ending: TurnEnding): void => {
  void refreshCodexSessionTitle(session)
    .then(() => flushPendingGoalSnapshot(session))
    .then(() =>
      confirmSignedOut(session, ending.status, ending.reportedError, ending.sharedAuthRejected)
    )
    .then((terminalError) => classifiedFailure(ending, terminalError))
    .then((terminalError) => emitTurnEnded(session, ending, terminalError))
    .then((terminalError) => {
      settlePendingPrompt(session, ending, terminalError)
    })
}

const classifiedFailure = (ending: TurnEnding, error: TurnError): TurnError => {
  if (!unclassifiedFailure(ending, error)) return error

  return { ...error, stopKind: "harnessFailed" }
}

const unclassifiedFailure = (
  ending: TurnEnding,
  error: TurnError
): error is NonNullable<TurnError> =>
  error !== undefined && error.stopKind === undefined && ending.stopReason === "end_turn"

const emitTurnEnded = async (
  session: CodexSession,
  ending: TurnEnding,
  terminalError: TurnError
): Promise<TurnError> => {
  await session.emit({
    kind: "session.updated",
    payload: {
      initiatedBy: ending.pending === undefined ? "agent" : "user",
      stopReason: ending.stopReason,
      ...(terminalError === undefined ? {} : { stopDetail: terminalError.message }),
      ...(terminalError?.stopKind === undefined ? {} : { stopKind: terminalError.stopKind }),
      ...usageLimitReset(session, terminalError),
      ...(terminalError?.retryable === true ? { retryable: true } : {}),
      turnId: ending.turnId,
      turnState: "ended"
    },
    subjectId: session.key
  })
  return terminalError
}

const usageLimitReset = (session: CodexSession, error: TurnError): UsageLimitReset => {
  if (error?.stopKind !== "usageLimit") return {}

  const resetsAt = exhaustedWindowReset(session.latestUsageLimits)
  return resetsAt === undefined ? {} : { resetsAt }
}

const settlePendingPrompt = (
  session: CodexSession,
  ending: TurnEnding,
  terminalError: TurnError
): void => {
  ending.pending?.resolve({ stopReason: ending.stopReason })
  if (!userTurnSucceeded(ending, terminalError)) return

  void session.titleGenerator?.onTurnCompleted()
}

const userTurnSucceeded = (ending: TurnEnding, terminalError: TurnError): boolean =>
  ending.pending !== undefined && ending.status === "completed" && terminalError === undefined
