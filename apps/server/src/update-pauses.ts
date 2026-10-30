import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { isAgentQuestion } from "@codevisor/db"

import type { CodevisorServerServices } from "./server-context.js"

const pausingSessions = new WeakMap<CodevisorServerServices, Set<string>>()

export const markPausingForUpdate = (
  services: CodevisorServerServices,
  sessionId: string
): void => {
  const sessions = pausingSessions.get(services) ?? new Set<string>()
  sessions.add(sessionId)
  pausingSessions.set(services, sessions)
}

export const forgetUpdatePauses = (services: CodevisorServerServices): void => {
  pausingSessions.delete(services)
}

export const forgetUpdatePause = (services: CodevisorServerServices, sessionId: string): void => {
  pausingSessions.get(services)?.delete(sessionId)
}

export const parksQuestionForUpdate = (
  services: CodevisorServerServices,
  sessionId: string,
  payload: Readonly<Record<string, unknown>>
): boolean =>
  pausingSessions.get(services)?.has(sessionId) === true &&
  payload.sessionUpdate === "question_resolved" &&
  payload.outcome === "cancelled" &&
  isAgentQuestion(payload)

export const withUpdatePauseStop = (
  services: CodevisorServerServices,
  sessionId: string,
  event: RuntimeEvent,
  payload: Readonly<Record<string, unknown>>
): RuntimeEvent => {
  if (pausingSessions.get(services)?.has(sessionId) !== true) return event
  if (payload.stopKind !== undefined) return event
  return { ...event, payload: { ...payload, stopKind: "pausedForUpdate" } }
}
