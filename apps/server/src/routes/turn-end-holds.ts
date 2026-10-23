import type { EventEnvelope } from "@codevisor/api"

import { swallowError } from "../server-context.js"
import { isUpdatePause } from "../update-pauses.js"

export const HELD_TURN_END_GRACE_MS = 12_000

export type ReleaseTurnEnd = (sessionId: string, stopReason: string | undefined) => Promise<void>

export interface TurnEndHolds {
  readonly track: (event: EventEnvelope, payload: Record<string, unknown>) => void
  readonly isHeld: (sessionId: string) => boolean
}

export const makeTurnEndHolds = (
  release: ReleaseTurnEnd,
  isIdle: (sessionId: string) => boolean
): TurnEndHolds => {
  const working = new Set<string>()
  const held = new Map<string, string | undefined>()
  const timers = new Map<string, ReturnType<typeof setTimeout>>()

  const disarm = (sessionId: string): void => {
    clearTimeout(timers.get(sessionId))
    timers.delete(sessionId)
  }

  const releaseAfterGrace = (sessionId: string): void => {
    const timer = setTimeout(() => {
      timers.delete(sessionId)
      const stopReason = held.get(sessionId)
      held.delete(sessionId)
      void release(sessionId, stopReason).catch(swallowError)
    }, HELD_TURN_END_GRACE_MS)
    timer.unref()
    timers.set(sessionId, timer)
  }

  const noteTasks = (sessionId: string, tasks: ReadonlyArray<unknown>): void => {
    disarm(sessionId)
    if (tasks.length > 0) {
      working.add(sessionId)
      return
    }

    working.delete(sessionId)
    if (held.has(sessionId) && isIdle(sessionId)) releaseAfterGrace(sessionId)
  }

  const noteTurnEnd = (sessionId: string, stopReason: string | undefined): void => {
    disarm(sessionId)
    if (working.has(sessionId)) {
      held.set(sessionId, stopReason)
      return
    }
    held.delete(sessionId)
  }

  return {
    track: (event, payload) => {
      if (event.kind !== "session.updated") return

      const sessionId = event.subjectId
      if (Array.isArray(payload.backgroundTasks)) noteTasks(sessionId, payload.backgroundTasks)
      if (payload.turnState === "started") disarm(sessionId)
      if (endsTurn(payload)) noteTurnEnd(sessionId, stopReasonOf(payload))
    },
    isHeld: (sessionId) => held.has(sessionId)
  }
}

export const stopReasonOf = (payload: Record<string, unknown>): string | undefined =>
  typeof payload.stopReason === "string" ? payload.stopReason : undefined

const endsTurn = (payload: Record<string, unknown>): boolean =>
  payload.turnState === "ended" && !isUpdatePause(payload)
