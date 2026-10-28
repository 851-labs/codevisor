import {
  run,
  sessionIsArchived,
  swallowError,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { drainPromptQueue } from "./prompt-queue.js"
import type { SessionEventMessage } from "./session-event-messages.js"

export interface PendingSessionEvent {
  readonly message: SessionEventMessage
  readonly sourceSessionId: string
}

export interface SessionEventOutbox {
  readonly deliver: (subscriberId: string, event: PendingSessionEvent) => Promise<void>
  readonly wokenBy: (sessionId: string) => ReadonlySet<string>
  readonly forgetWake: (sessionId: string) => void
}

export const makeSessionEventOutbox = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string
): SessionEventOutbox => {
  const chains = new Map<string, Promise<void>>()
  const wakes = new Map<string, Set<string>>()

  const serialized = (subscriberId: string, step: () => Promise<void>): Promise<void> => {
    const next = (chains.get(subscriberId) ?? Promise.resolve()).then(step).catch(swallowError)
    chains.set(subscriberId, next)
    return next
  }

  const noteWake = (subscriberId: string, sourceSessionId: string): void => {
    const sources = wakes.get(subscriberId) ?? new Set<string>()
    sources.add(sourceSessionId)
    wakes.set(subscriberId, sources)
  }

  const enqueue = async (subscriberId: string, event: PendingSessionEvent): Promise<void> => {
    if (!(await acceptsEvents(services, subscriberId))) return

    noteWake(subscriberId, event.sourceSessionId)
    await run(
      services.db.createPromptQueueItem(
        subscriberId,
        event.message.text,
        [],
        undefined,
        undefined,
        "system"
      )
    )
    void drainPromptQueue(services, fanout, routeState, serverId, subscriberId).catch(swallowError)
  }

  return {
    deliver: (subscriberId, event) => serialized(subscriberId, () => enqueue(subscriberId, event)),
    wokenBy: (sessionId) => wakes.get(sessionId) ?? new Set(),
    forgetWake: (sessionId) => {
      wakes.delete(sessionId)
    }
  }
}

const acceptsEvents = async (
  services: CodevisorServerServices,
  sessionId: string
): Promise<boolean> => {
  const session = await run(services.db.getSessionSummary(sessionId))
  return !(await sessionIsArchived(services, session))
}
