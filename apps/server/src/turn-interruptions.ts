import type { RuntimeEvent } from "@codevisor/agent-runtime"

import type { CodevisorServerServices } from "./server-context.js"

const interruptedSessions = new WeakMap<CodevisorServerServices, Set<string>>()

export const markTurnInterrupted = (services: CodevisorServerServices, sessionId: string): void => {
  const sessions = interruptedSessions.get(services) ?? new Set<string>()
  sessions.add(sessionId)
  interruptedSessions.set(services, sessions)
}

export const forgetTurnInterruptions = (services: CodevisorServerServices): void => {
  interruptedSessions.delete(services)
}

export const withInterruptedStop = (
  services: CodevisorServerServices,
  sessionId: string,
  event: RuntimeEvent,
  payload: Readonly<Record<string, unknown>>
): RuntimeEvent => {
  if (!interruptedSessions.get(services)?.has(sessionId)) return event
  if (payload.stopKind !== undefined) return event
  return { ...event, payload: { ...payload, stopKind: "interrupted" } }
}
