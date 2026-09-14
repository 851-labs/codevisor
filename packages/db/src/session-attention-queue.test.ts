import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { makeDatabase } from "./index.js"
import { ATTENTION_SETTLE_GRACE_MS } from "./session-attention.js"
import { run } from "./test-support.js"

describe("queued prompt attention", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(new Date("2026-01-01T00:00:00Z"))
  })
  afterEach(() => vi.useRealTimers())

  const fixture = async () => {
    const db = await run(makeDatabase({ filename: ":memory:", serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/queue-attention" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    return {
      db,
      session,
      summary: () => run(db.getSessionSummary(session.id)),
      start: (turnId: string) =>
        run(db.appendEvent("session.updated", session.id, { turnId, turnState: "started" })),
      finish: (turnId: string) =>
        run(
          db.appendEvent("session.updated", session.id, {
            turnId,
            turnState: "ended",
            stopReason: "end_turn"
          })
        ),
      publishQueue: async () =>
        run(
          db.appendEvent("session.queue.updated", session.id, {
            queue: await run(db.listPromptQueue(session.id))
          })
        )
    }
  }

  it("counts an entire drain once, including the claimed last prompt", async () => {
    const { db, session, summary, start, finish, publishQueue } = await fixture()
    try {
      const first = await run(db.createPromptQueueItem(session.id, "first"))
      const last = await run(db.createPromptQueueItem(session.id, "last"))
      await run(db.claimPromptQueueItem(session.id))
      await start("first")
      await finish("first")
      expect(await summary()).toMatchObject({
        sidebarState: "inProgress",
        latestAttentionSequence: 0,
        unreadCount: 0
      })
      vi.setSystemTime(Date.now() + ATTENTION_SETTLE_GRACE_MS * 2)
      expect(await run(db.settleSessionAttention(session.id))).toEqual({ settled: false })
      expect(await run(db.getAttentionSettleDeadline(session.id))).toBeUndefined()

      await run(db.completePromptQueueItem(session.id, first.id))
      await run(db.claimPromptQueueItem(session.id))
      // The public queue is empty before the final turn even starts.
      await publishQueue()
      expect(await run(db.listPromptQueue(session.id))).toEqual([])
      expect(await summary()).toMatchObject({ latestAttentionSequence: 0, unreadCount: 0 })
      await start("last")
      await finish("last")
      await publishQueue()
      expect(await summary()).toMatchObject({ latestAttentionSequence: 0, unreadCount: 0 })

      await run(db.completePromptQueueItem(session.id, last.id))
      await publishQueue()
      expect(await summary()).toMatchObject({
        sidebarState: "unread",
        latestAttentionSequence: 1,
        unreadCount: 1
      })
      await publishQueue()
      expect(await run(db.settleSessionAttention(session.id))).toEqual({ settled: false })
      expect((await summary()).latestAttentionSequence).toBe(1)
    } finally {
      await run(db.close)
    }
  })

  it("settles when the user deletes the last pending prompt", async () => {
    const { db, session, summary, start, finish, publishQueue } = await fixture()
    try {
      await start("autonomous")
      const pending = await run(db.createPromptQueueItem(session.id, "follow-up"))
      await finish("autonomous")
      await run(db.deletePromptQueueItem(session.id, pending.id))
      await publishQueue()
      expect(await summary()).toMatchObject({
        sidebarState: "unread",
        latestAttentionSequence: 1,
        unreadCount: 1
      })
    } finally {
      await run(db.close)
    }
  })

  it("revalidates a released subagent deadline against newly queued work", async () => {
    const { db, session, summary, start, finish, publishQueue } = await fixture()
    try {
      await start("parent")
      await run(
        db.appendEvent("session.updated", session.id, {
          backgroundTasks: [
            { id: "child", description: "Check", status: "running", taskType: "subagent" }
          ]
        })
      )
      await finish("parent")
      await run(db.appendEvent("session.updated", session.id, { backgroundTasks: [] }))
      expect(await run(db.getAttentionSettleDeadline(session.id))).toBeDefined()
      const pending = await run(db.createPromptQueueItem(session.id, "follow-up"))
      vi.setSystemTime(Date.now() + ATTENTION_SETTLE_GRACE_MS)
      expect(await run(db.settleSessionAttention(session.id))).toEqual({ settled: false })
      await publishQueue()
      expect(await summary()).toMatchObject({ latestAttentionSequence: 0, unreadCount: 0 })
      await run(db.deletePromptQueueItem(session.id, pending.id))
      await publishQueue()
      expect((await summary()).latestAttentionSequence).toBe(1)
    } finally {
      await run(db.close)
    }
  })

  it("recovers an acknowledged final claim without waiting for another event", async () => {
    const { db, session, summary, start, finish } = await fixture()
    try {
      const item = await run(db.createPromptQueueItem(session.id, "last"))
      await run(db.claimPromptQueueItem(session.id))
      await start("last")
      await finish("last")
      expect(await run(db.listPendingAttentionSettles)).toHaveLength(1)
      expect(await run(db.settleSessionAttention(session.id))).toEqual({ settled: false })
      await run(db.completePromptQueueItem(session.id, item.id))
      expect(await run(db.settleSessionAttention(session.id))).toEqual({ settled: true })
      expect(await summary()).toMatchObject({ latestAttentionSequence: 1, unreadCount: 1 })
    } finally {
      await run(db.close)
    }
  })
})
