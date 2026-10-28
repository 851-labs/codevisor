import { BackgroundTask, type EventEnvelope } from "@codevisor/api"
import { Schema } from "effect"

import { isUpdatePause } from "../update-pauses.js"

export const HELD_TURN_END_GRACE_MS = 12_000
export const HELD_TURN_END_MAX_MS = 3 * 60_000
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
  readonly epoch: number
}

export const makeTurnEndHolds = (
  release: ReleaseTurnEnd,
  isIdle: (sessionId: string) => boolean,
  heldSessions: Set<string>
): TurnEndHolds => {
  const working = new Map<string, ReadonlySet<string>>()
  const outlasted = new Map<string, ReadonlySet<string>>()
  const held = new Map<string, HeldTurnEnd>()
  const timers = new Map<string, ReturnType<typeof setTimeout>>()
  const deadlines = new Map<string, ReturnType<typeof setTimeout>>()
  const epochs = new Map<string, number>()

  const hold = (sessionId: string, turnEnd: HeldTurnEnd): void => {
    held.set(sessionId, turnEnd)
    heldSessions.add(sessionId)
  }

  const unhold = (sessionId: string): void => {
    held.delete(sessionId)
    heldSessions.delete(sessionId)
    clearTimeout(deadlines.get(sessionId))
    deadlines.delete(sessionId)
  }

  const advance = (sessionId: string): void => {
    clearTimeout(timers.get(sessionId))
    timers.delete(sessionId)
  }

  const nextEpoch = (sessionId: string): number => {
    const epoch = (epochs.get(sessionId) ?? 0) + 1
    epochs.set(sessionId, epoch)
    return epoch
  }

  const releaseAfterGrace = (sessionId: string, attempt: number): void => {
    const turnEnd = held.get(sessionId)!
    const timer = setTimeout(() => {
      timers.delete(sessionId)
      void attemptRelease(sessionId, turnEnd, attempt)
    }, HELD_TURN_END_GRACE_MS)
    timer.unref()
    timers.set(sessionId, timer)
  }

  const releaseAtDeadline = (sessionId: string, turnEnd: HeldTurnEnd): void => {
    const timer = setTimeout(() => {
      deadlines.delete(sessionId)
      outlasted.set(sessionId, new Set(working.get(sessionId)))
      void attemptRelease(sessionId, turnEnd, 0)
    }, HELD_TURN_END_MAX_MS)
    timer.unref()
    deadlines.set(sessionId, timer)
  }

  const attemptRelease = async (
    sessionId: string,
    turnEnd: HeldTurnEnd,
    attempt: number
  ): Promise<void> => {
    const stale = (): boolean => epochs.get(sessionId) !== turnEnd.epoch
    if (stale() || !isIdle(sessionId)) return
    try {
      await release(sessionId, turnEnd.stopReason, stale)
    } catch {
      if (!stale() && attempt + 1 < HELD_TURN_END_ATTEMPTS)
        releaseAfterGrace(sessionId, attempt + 1)
      return
    }
    if (!stale() && held.get(sessionId) === turnEnd) unhold(sessionId)
  }

  const noteTasks = (sessionId: string, tasks: ReadonlyArray<unknown>): void => {
    advance(sessionId)
    const ids = taskIds(tasks)
    outlasted.set(sessionId, intersection(outlasted.get(sessionId), ids))
    if (ids.size > 0) {
      working.set(sessionId, ids)
      return
    }

    working.delete(sessionId)
    if (held.has(sessionId) && isIdle(sessionId)) releaseAfterGrace(sessionId, 0)
  }

  const awaitsTasks = (sessionId: string): boolean => {
    const known = outlasted.get(sessionId)
    return [...(working.get(sessionId) ?? [])].some((id) => known?.has(id) !== true)
  }

  const noteTurnEnd = (sessionId: string, stopReason: string | undefined): void => {
    advance(sessionId)
    unhold(sessionId)
    const turnEnd = { stopReason, epoch: nextEpoch(sessionId) }
    if (!awaitsTasks(sessionId)) return
    hold(sessionId, turnEnd)
    releaseAtDeadline(sessionId, turnEnd)
  }

  const noteTurnStart = (sessionId: string): void => {
    advance(sessionId)
    nextEpoch(sessionId)
  }

  const drop = (sessionId: string): void => {
    advance(sessionId)
    nextEpoch(sessionId)
    unhold(sessionId)
  }

  return {
    track: (event, payload) => {
      if (supersedesTurnEnd(event, payload)) return drop(event.subjectId)
      if (event.kind !== "session.updated") return

      const sessionId = event.subjectId
      if (Array.isArray(payload.backgroundTasks)) noteTasks(sessionId, payload.backgroundTasks)
      if (payload.turnState === "started") noteTurnStart(sessionId)
      if (endsTurn(payload)) noteTurnEnd(sessionId, stopReasonOf(payload))
    },
    isHeld: (sessionId) => held.has(sessionId)
  }
}

export const stopReasonOf = (payload: Record<string, unknown>): string | undefined =>
  typeof payload.stopReason === "string" ? payload.stopReason : undefined

const taskIds = (tasks: ReadonlyArray<unknown>): ReadonlySet<string> =>
  new Set(tasks.filter(isBackgroundTask).map((task) => task.id))

const isBackgroundTask = Schema.is(BackgroundTask)

const intersection = (
  known: ReadonlySet<string> | undefined,
  current: ReadonlySet<string>
): ReadonlySet<string> => new Set([...(known ?? [])].filter((id) => current.has(id)))

const supersedesTurnEnd = (event: EventEnvelope, payload: Record<string, unknown>): boolean =>
  event.kind === "session.error" ||
  (event.kind === "session.attention.updated" && payload.actionRequiredKind !== undefined)

const endsTurn = (payload: Record<string, unknown>): boolean =>
  payload.turnState === "ended" && !isUpdatePause(payload)
