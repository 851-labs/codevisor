import type { EventEnvelope } from "@codevisor/api"

import { swallowError } from "../server-context.js"
import { isUpdatePause } from "../update-pauses.js"

export const HELD_TURN_END_GRACE_MS = 12_000

export type ReleaseTurnEnd = (sessionId: string, stopReason: string | undefined) => Promise<void>

export interface TurnEndHolds {
  readonly track: (event: EventEnvelope, payload: Record<string, unknown>) => void
  readonly isHeld: (sessionId: string) => boolean
}

interface HeldTurnEnd {
  readonly stopReason: string | undefined
}

export const makeTurnEndHolds = (
  release: ReleaseTurnEnd,
  isIdle: (sessionId: string) => boolean
): TurnEndHolds => {
  const working = new Set<string>()
  const held = new Map<string, HeldTurnEnd>()
  const timers = new Map<string, ReturnType<typeof setTimeout>>()

  const disarm = (sessionId: string): void => {
    clearTimeout(timers.get(sessionId))
    timers.delete(sessionId)
  }

  const releaseAfterGrace = (sessionId: string): void => {
    const timer = setTimeout(() => {
      timers.delete(sessionId)
      void releaseIfStillHeld(sessionId).catch(swallowError)
    }, HELD_TURN_END_GRACE_MS)
    timer.unref()
    timers.set(sessionId, timer)
  }

  const releaseIfStillHeld = async (sessionId: string): Promise<void> => {
    const hold = held.get(sessionId)!
    if (!isIdle(sessionId)) return
    await release(sessionId, hold.stopReason)
    if (held.get(sessionId) === hold) held.delete(sessionId)
  }

  const drop = (sessionId: string): void => {
    disarm(sessionId)
    held.delete(sessionId)
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
      held.set(sessionId, { stopReason })
      return
    }
    held.delete(sessionId)
  }

  return {
    track: (event, payload) => {
      if (supersedesTurnEnd(event, payload)) return drop(event.subjectId)
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

const supersedesTurnEnd = (event: EventEnvelope, payload: Record<string, unknown>): boolean =>
  event.kind === "session.error" ||
  (event.kind === "session.attention.updated" && payload.actionRequiredKind !== undefined)

const endsTurn = (payload: Record<string, unknown>): boolean =>
  payload.turnState === "ended" && !isUpdatePause(payload)
