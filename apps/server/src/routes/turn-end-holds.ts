import type { EventEnvelope } from "@codevisor/api"

import { isUpdatePause } from "../update-pauses.js"

export const HELD_TURN_END_GRACE_MS = 12_000
export const HELD_TURN_END_ATTEMPTS = 5

export type ReleaseTurnEnd = (
  sessionId: string,
  stopReason: string | undefined,
  stale: () => boolean
) => Promise<void>

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
  const generations = new Map<string, number>()

  const advance = (sessionId: string): void => {
    clearTimeout(timers.get(sessionId))
    timers.delete(sessionId)
    generations.set(sessionId, (generations.get(sessionId) ?? 0) + 1)
  }

  const releaseAfterGrace = (sessionId: string, attempt: number): void => {
    const hold = held.get(sessionId)!
    const generation = generations.get(sessionId)
    const stale = (): boolean =>
      held.get(sessionId) !== hold || generations.get(sessionId) !== generation
    const timer = setTimeout(() => {
      timers.delete(sessionId)
      void attemptRelease(sessionId, hold, stale, attempt)
    }, HELD_TURN_END_GRACE_MS)
    timer.unref()
    timers.set(sessionId, timer)
  }

  const attemptRelease = async (
    sessionId: string,
    hold: HeldTurnEnd,
    stale: () => boolean,
    attempt: number
  ): Promise<void> => {
    if (stale() || !isIdle(sessionId)) return
    try {
      await release(sessionId, hold.stopReason, stale)
    } catch {
      if (!stale() && attempt + 1 < HELD_TURN_END_ATTEMPTS)
        releaseAfterGrace(sessionId, attempt + 1)
      return
    }
    if (!stale()) held.delete(sessionId)
  }

  const noteTasks = (sessionId: string, tasks: ReadonlyArray<unknown>): void => {
    advance(sessionId)
    if (tasks.length > 0) {
      working.add(sessionId)
      return
    }

    working.delete(sessionId)
    if (held.has(sessionId) && isIdle(sessionId)) releaseAfterGrace(sessionId, 0)
  }

  const noteTurnEnd = (sessionId: string, stopReason: string | undefined): void => {
    advance(sessionId)
    if (working.has(sessionId)) {
      held.set(sessionId, { stopReason })
      return
    }
    held.delete(sessionId)
  }

  const drop = (sessionId: string): void => {
    advance(sessionId)
    held.delete(sessionId)
  }

  return {
    track: (event, payload) => {
      if (supersedesTurnEnd(event, payload)) return drop(event.subjectId)
      if (event.kind !== "session.updated") return

      const sessionId = event.subjectId
      if (Array.isArray(payload.backgroundTasks)) noteTasks(sessionId, payload.backgroundTasks)
      if (payload.turnState === "started") advance(sessionId)
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
