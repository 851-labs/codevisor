import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { Effect } from "effect"

import {
  reportServerError,
  serverDiagnosticsInstalled
} from "../infra/diagnostics/server-diagnostics.js"

export interface TurnFailure {
  readonly cause: unknown
  readonly stopKind: string
}

export class HarnessTurnError extends Error {
  override readonly name = "HarnessTurnError"
}

export const turnFailureOf = (event: RuntimeEvent): TurnFailure | undefined => {
  const payload = isRecord(event.payload) ? event.payload : {}
  if (event.kind === "session.error" && typeof payload.message === "string") {
    return { cause: new HarnessTurnError(payload.message), stopKind: stopKindOf(payload) }
  }
  if (endedInHarnessFailure(event, payload)) {
    const detail = typeof payload.stopDetail === "string" ? payload.stopDetail : "Turn failed"
    return { cause: new HarnessTurnError(detail), stopKind: "harnessFailed" }
  }
  return undefined
}

export interface SessionHarnessLookup {
  readonly getSessionSummary: (
    sessionId: string
  ) => Effect.Effect<{ readonly harnessId: string }, unknown>
}

export const reportTurnFailure = async (
  db: SessionHarnessLookup,
  sessionId: string,
  failure: TurnFailure
): Promise<void> => {
  if (!serverDiagnosticsInstalled() || !reportedStopKinds.has(failure.stopKind)) return

  const harnessId = await sessionHarnessId(db, sessionId)
  reportServerError(failure.cause, {
    component: "turn",
    groupBy: groupingText(failure.cause),
    tags: { stop_kind: failure.stopKind, harness_id: harnessId ?? "unknown" }
  })
}

const reportedStopKinds = new Set(["harnessFailed"])
const groupingLength = 120

const isRecord = (value: unknown): value is Readonly<Record<string, unknown>> =>
  typeof value === "object" && value !== null

const stopKindOf = (payload: Readonly<Record<string, unknown>>): string =>
  typeof payload.stopKind === "string" ? payload.stopKind : "harnessFailed"

const endedInHarnessFailure = (
  event: RuntimeEvent,
  payload: Readonly<Record<string, unknown>>
): boolean =>
  event.kind === "session.updated" &&
  payload.turnState === "ended" &&
  payload.stopKind === "harnessFailed"

const groupingText = (cause: unknown): string => {
  const message = cause instanceof Error ? cause.message : String(cause)
  return message.replaceAll(/\d+/g, "#").slice(0, groupingLength)
}

const sessionHarnessId = async (
  db: SessionHarnessLookup,
  sessionId: string
): Promise<string | undefined> => {
  try {
    return (await Effect.runPromise(db.getSessionSummary(sessionId))).harnessId
  } catch {
    return undefined
  }
}
