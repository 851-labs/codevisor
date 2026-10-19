import {
  run,
  sessionIsArchived,
  swallowError,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { conversationalBotForSession } from "./bot-turns.js"
import { drainPromptQueue, hasLiveTurn } from "./prompt-queue.js"
import { combinedEventText, type SessionEventMessage } from "./session-event-messages.js"

export interface PendingSessionEvent {
  readonly message: SessionEventMessage
  readonly sourceSessionId: string
  readonly stale?: () => boolean
}

export interface SessionEventOutbox {
  readonly deliver: (subscriberId: string, event: PendingSessionEvent) => Promise<void>
  readonly flushHeld: (subscriberId: string) => Promise<void>
  readonly wokenBy: (sessionId: string) => ReadonlySet<string>
  readonly forgetWake: (sessionId: string) => void
}

export const makeSessionEventOutbox = (
  services: CodevisorServerServices,
  fanout: EventFanout,
  routeState: RouteState,
  serverId: string
): SessionEventOutbox => {
  const held = new Map<string, Map<string, PendingSessionEvent>>()
  const chains = new Map<string, Promise<void>>()
  const wakes = new Map<string, Set<string>>()

  const serialized = (subscriberId: string, step: () => Promise<void>): Promise<void> => {
    const next = (chains.get(subscriberId) ?? Promise.resolve()).then(step).catch(swallowError)
    chains.set(subscriberId, next)
    return next
  }

  const hold = (subscriberId: string, event: PendingSessionEvent): void => {
    const events = held.get(subscriberId) ?? new Map<string, PendingSessionEvent>()
    events.delete(event.message.key)
    events.set(event.message.key, event)
    held.set(subscriberId, events)
  }

  const take = (subscriberId: string): ReadonlyArray<PendingSessionEvent> => {
    /* v8 ignore next */
    const events = [...(held.get(subscriberId)?.values() ?? [])]
    held.delete(subscriberId)
    return events.filter((event) => event.stale?.() !== true)
  }

  const noteWake = (subscriberId: string, events: ReadonlyArray<PendingSessionEvent>): void => {
    const sources = wakes.get(subscriberId) ?? new Set<string>()
    for (const event of events) sources.add(event.sourceSessionId)
    wakes.set(subscriberId, sources)
  }

  const flush = async (subscriberId: string): Promise<void> => {
    const events = take(subscriberId)
    if (events.length === 0) return
    if (!(await acceptsEvents(services, subscriberId))) return

    noteWake(subscriberId, events)
    await run(
      services.db.createPromptQueueItem(
        subscriberId,
        combinedEventText(events.map((event) => event.message)),
        [],
        undefined,
        undefined,
        "system"
      )
    )
    void drainPromptQueue(services, fanout, routeState, serverId, subscriberId).catch(swallowError)
  }

  const mustWait = async (subscriberId: string): Promise<boolean> => {
    if (!hasLiveTurn(routeState, subscriberId)) return false
    return (await conversationalBotForSession(services, subscriberId)) === undefined
  }

  const flushWhenFree = async (subscriberId: string): Promise<void> => {
    if (await mustWait(subscriberId)) return
    await flush(subscriberId)
  }

  return {
    deliver: (subscriberId, event) => {
      hold(subscriberId, event)
      return serialized(subscriberId, () => flushWhenFree(subscriberId))
    },
    flushHeld: (subscriberId) => {
      if (!held.has(subscriberId)) return Promise.resolve()
      return serialized(subscriberId, () => flush(subscriberId))
    },
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
