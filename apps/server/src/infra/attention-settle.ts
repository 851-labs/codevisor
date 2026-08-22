import type { CodevisorDatabaseService } from "@codevisor/db"
import { appendAndPublish, run, swallowError, type EventFanout } from "../server-context.js"

export interface AttentionSettleScheduler {
  /// Re-arms every parked finish left behind by a previous process (or by the
  /// revision-counter migration). Runs after startup reconciliation has
  /// already cleared stale background-task snapshots, so nothing recovered
  /// here can still be held — each row settles once its grace elapses.
  readonly recover: () => Promise<void>
  readonly close: () => void
}

/// The event-driven half of deferred attention settling. Projections inside
/// packages/db are synchronous SQLite transactions and cannot own timers, so
/// they only persist a `settle_due_at` deadline; this scheduler watches the
/// fanout for anything that could move a session's deadline and fires
/// `settleSessionAttention` when it elapses. Settling is idempotent and
/// re-validated in-transaction, so a race with a turn that restarted after
/// the timer was armed is harmless. The db-side re-evaluation also settles
/// expired deadlines opportunistically on the next inbound event — this
/// scheduler just makes the flip prompt.
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
    /* v8 ignore next -- shutdown race: a settle resolving as close() runs. */
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
    /* v8 ignore next -- shutdown race: close() during the settle round-trip. */
    if (closed) return
    if (result.settled) {
      // The settle happened outside any inbound runtime event, so the fanout
      // must be told explicitly — the exact mechanism the read/unread routes
      // use. Clients see the flip from inProgress to unread here.
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
          // No deadline yet (migrated pending epochs, holds released while
          // the old process was dying). settle() arms the grace deadline
          // in-transaction and hands back when to fire.
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
