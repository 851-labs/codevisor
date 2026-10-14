import type { CodevisorDatabaseService } from "@codevisor/db"

import { appendAndPublish, run, swallowError, type EventFanout } from "../server-context.js"

export interface AttentionSettleScheduler {
  readonly recover: () => Promise<void>
  readonly close: () => void
}

export const makeAttentionSettleScheduler = (
  db: CodevisorDatabaseService,
  fanout: EventFanout
): AttentionSettleScheduler => {
  const timers = new Map<string, ReturnType<typeof setTimeout>>()
  let closed = false

  const disarm = (sessionId: string): void => {
    const timer = timers.get(sessionId)
    if (timer === undefined) return
    clearTimeout(timer)
    timers.delete(sessionId)
  }

  const arm = (sessionId: string, dueAt: string): void => {
    /* v8 ignore next */
    if (closed) return
    disarm(sessionId)
    const delay = Math.max(0, Date.parse(dueAt) - Date.now())
    const timer = setTimeout(() => {
      timers.delete(sessionId)
      void settle(sessionId).catch(swallowError)
    }, delay)
    timer.unref()
    timers.set(sessionId, timer)
  }

  const settle = async (sessionId: string): Promise<void> => {
    const result = await run(db.settleSessionAttention(sessionId))
    /* v8 ignore next */
    if (closed) return
    if (result.settled) {
      const summary = await run(db.getSessionSummary(sessionId))
      await appendAndPublish(db, fanout, "session.attention.updated", sessionId, summary)
      return
    }
    if (result.nextDueAt !== undefined) arm(sessionId, result.nextDueAt)
  }

  const evaluate = async (sessionId: string): Promise<void> => {
    const dueAt = await run(db.getAttentionSettleDeadline(sessionId))
    if (dueAt === undefined) {
      disarm(sessionId)
      return
    }
    arm(sessionId, dueAt)
  }

  const unsubscribe = fanout.subscribe((event) => {
    if (
      event.kind !== "session.output" &&
      event.kind !== "session.updated" &&
      event.kind !== "session.error" &&
      event.kind !== "session.queue.updated" &&
      event.kind !== "session.attention.updated"
    ) {
      return
    }
    void evaluate(event.subjectId).catch(swallowError)
  })

  return {
    recover: async () => {
      const pending = await run(db.listPendingAttentionSettles)
      for (const row of pending) {
        if (row.dueAt !== null) {
          arm(row.sessionId, row.dueAt)
        } else {
          await settle(row.sessionId).catch(swallowError)
        }
      }
    },
    close: () => {
      closed = true
      unsubscribe()
      for (const timer of timers.values()) clearTimeout(timer)
      timers.clear()
    }
  }
}
