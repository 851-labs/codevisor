import type { EventEnvelope } from "@codevisor/api"
import { makeDatabase } from "@codevisor/db"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { appendAndPublish, makeEventFanout, run } from "../server-context.js"
import { publishPromptQueue } from "../routes/prompt-queue.js"
import { makeAttentionSettleScheduler } from "./attention-settle.js"

describe("queue completion notifications", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date", "setTimeout", "clearTimeout"] })
    vi.setSystemTime(new Date("2026-01-01T00:00:00Z"))
  })
  afterEach(() => vi.useRealTimers())

  it.each([false, true])(
    "publishes one unread edge after the queue drains (subagent: %s)",
    async (hasSubagent) => {
      const db = await run(makeDatabase({ filename: ":memory:", serverId: "local" }))
      const fanout = await run(makeEventFanout)
      const scheduler = makeAttentionSettleScheduler(db, fanout)
      const attention: Array<EventEnvelope> = []
      const unsubscribe = fanout.subscribe((event) => {
        if (event.kind === "session.attention.updated") attention.push(event)
      })
      try {
        const project = await run(db.createProject({ folderPath: "/tmp/queue-notifications" }))
        const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
        const items = [
          await run(db.createPromptQueueItem(session.id, "first")),
          await run(db.createPromptQueueItem(session.id, "last"))
        ]
        for (const item of items) {
          await run(db.claimPromptQueueItem(session.id))
          await publishPromptQueue(db, fanout, session.id)
          await appendAndPublish(db, fanout, "session.updated", session.id, {
            turnId: item.id,
            turnState: "started"
          })
          if (hasSubagent) {
            await appendAndPublish(db, fanout, "session.updated", session.id, {
              backgroundTasks: [
                { id: "child", description: "Check", status: "running", taskType: "subagent" }
              ]
            })
          }
          await appendAndPublish(db, fanout, "session.updated", session.id, {
            turnId: item.id,
            turnState: "ended",
            stopReason: "end_turn"
          })
          if (hasSubagent) {
            await appendAndPublish(db, fanout, "session.updated", session.id, {
              backgroundTasks: []
            })
          }
          // Finish delivery precedes the provider returning and releasing its
          // claim. Even an expired timer must not notify in this interval.
          await vi.advanceTimersByTimeAsync(24_000)
          expect((await run(db.getSessionSummary(session.id))).unreadCount).toBe(0)
          await run(db.completePromptQueueItem(session.id, item.id))
        }
        expect(
          attention.some((event) => (event.payload as { unreadCount: number }).unreadCount > 0)
        ).toBe(false)
        await publishPromptQueue(db, fanout, session.id)
        if (hasSubagent) {
          // Releasing the queue must arm the remaining subagent grace even
          // when no further runtime events arrive.
          await vi.advanceTimersByTimeAsync(11_999)
          expect((await run(db.getSessionSummary(session.id))).unreadCount).toBe(0)
          await vi.advanceTimersByTimeAsync(1)
        }
        expect(await run(db.getSessionSummary(session.id))).toMatchObject({
          sidebarState: "unread",
          latestAttentionSequence: 1,
          unreadCount: 1
        })
        expect(
          attention.filter((event) => (event.payload as { unreadCount: number }).unreadCount > 0)
        ).toHaveLength(1)
        await publishPromptQueue(db, fanout, session.id)
        await vi.advanceTimersByTimeAsync(24_000)
        expect(
          attention.filter((event) => (event.payload as { unreadCount: number }).unreadCount > 0)
        ).toHaveLength(1)
      } finally {
        unsubscribe()
        scheduler.close()
        await run(db.close)
      }
    }
  )
})
