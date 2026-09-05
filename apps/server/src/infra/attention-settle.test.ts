import type { EventEnvelope } from "@codevisor/api"
import { makeDatabase } from "@codevisor/db"
import Database from "better-sqlite3"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { appendAndPublish, makeEventFanout } from "../server-context.js"
import { run, tempDirs } from "../test-support.js"
import { makeAttentionSettleScheduler } from "./attention-settle.js"

const makeAttentionDb = async (graceMs: number) => {
  const dir = mkdtempSync(join(tmpdir(), "codevisor-attention-settle-"))
  tempDirs.push(dir)
  const filename = join(dir, "codevisor.sqlite")
  const db = await run(
    makeDatabase({
      filename,
      serverId: "server-a",
      attentionSettleGraceMs: graceMs
    })
  )
  return { db, filename }
}

describe("@codevisor/server attention settle", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date", "setTimeout", "clearTimeout"] })
    vi.setSystemTime(new Date("2026-01-01T00:00:00Z"))
  })
  afterEach(() => vi.useRealTimers())
  it("settles a released subagent hold after the grace and publishes one flip", async () => {
    const { db } = await makeAttentionDb(40)
    const fanout = await run(makeEventFanout)
    const attentionEvents: Array<EventEnvelope> = []
    fanout.subscribe((event) => {
      if (event.kind === "session.attention.updated") attentionEvents.push(event)
    })
    const scheduler = makeAttentionSettleScheduler(db, fanout)

    const project = await run(db.createProject({ folderPath: "/tmp/attention-settle" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "claude-code" }))
    await appendAndPublish(db, fanout, "session.updated", session.id, {
      initiatedBy: "user",
      turnId: "turn-1",
      turnState: "started"
    })
    await appendAndPublish(db, fanout, "session.updated", session.id, {
      backgroundTasks: [
        { id: "agent-1", description: "Research", status: "running", taskType: "subagent" }
      ]
    })
    await appendAndPublish(db, fanout, "session.updated", session.id, {
      initiatedBy: "user",
      stopReason: "end_turn",
      turnId: "turn-1",
      turnState: "ended"
    })
    // Still held: nothing may flip to unread while the subagent runs.
    expect((await run(db.getSessionSummary(session.id))).sidebarState).toBe("inProgress")

    await appendAndPublish(db, fanout, "session.updated", session.id, { backgroundTasks: [] })
    // The hold released; the scheduler owns the grace deadline from here.
    await vi.advanceTimersByTimeAsync(40)
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      latestAttentionSequence: 1,
      unreadCount: 1
    })
    const settleFlips = attentionEvents.filter(
      (event) =>
        typeof event.payload === "object" &&
        event.payload !== null &&
        "sidebarState" in event.payload &&
        event.payload.sidebarState === "unread"
    )
    expect(settleFlips).toHaveLength(1)
    scheduler.close()
    await run(db.close)
  })

  it("cancels the deadline when the agent is re-invoked within the grace", async () => {
    const { db } = await makeAttentionDb(80)
    const fanout = await run(makeEventFanout)
    const scheduler = makeAttentionSettleScheduler(db, fanout)

    const project = await run(db.createProject({ folderPath: "/tmp/attention-reinvoke" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "claude-code" }))
    await appendAndPublish(db, fanout, "session.updated", session.id, {
      initiatedBy: "user",
      turnId: "turn-1",
      turnState: "started"
    })
    await appendAndPublish(db, fanout, "session.updated", session.id, {
      backgroundTasks: [
        { id: "agent-1", description: "Research", status: "running", taskType: "subagent" }
      ]
    })
    await appendAndPublish(db, fanout, "session.updated", session.id, {
      initiatedBy: "user",
      stopReason: "end_turn",
      turnId: "turn-1",
      turnState: "ended"
    })
    await appendAndPublish(db, fanout, "session.updated", session.id, { backgroundTasks: [] })
    // The harness re-invokes before the deadline: the parked finish must ride
    // through the continuation without settling.
    await appendAndPublish(db, fanout, "session.updated", session.id, {
      initiatedBy: "agent",
      turnId: "turn-2",
      turnState: "started"
    })
    await vi.advanceTimersByTimeAsync(160)
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      latestAttentionSequence: 0,
      unreadCount: 0,
      sidebarState: "inProgress"
    })

    // The chain finally ends clean with nothing held: settles once.
    await appendAndPublish(db, fanout, "session.updated", session.id, {
      initiatedBy: "agent",
      stopReason: "end_turn",
      turnId: "turn-2",
      turnState: "ended"
    })
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      latestAttentionSequence: 1,
      unreadCount: 1,
      sidebarState: "unread"
    })
    scheduler.close()
    await run(db.close)
  })

  it("drains parked finishes on recovery after a restart", async () => {
    const { db } = await makeAttentionDb(30)
    const fanout = await run(makeEventFanout)

    // The previous process died between the hold release and the settle:
    // no scheduler heard these events.
    const project = await run(db.createProject({ folderPath: "/tmp/attention-recover" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "claude-code" }))
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        turnId: "turn-1",
        turnState: "started"
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        backgroundTasks: [
          { id: "agent-1", description: "Research", status: "running", taskType: "subagent" }
        ]
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        stopReason: "end_turn",
        turnId: "turn-1",
        turnState: "ended"
      })
    )
    expect((await run(db.getSessionSummary(session.id))).sidebarState).toBe("inProgress")

    // Recovery with the subagent snapshot still stale (no deadline recorded):
    // settling is refused while held, nothing flips early.
    const scheduler = makeAttentionSettleScheduler(db, fanout)
    await scheduler.recover()
    expect((await run(db.getSessionSummary(session.id))).latestAttentionSequence).toBe(0)

    // Startup reconciliation then publishes the empty snapshot; the live loop
    // arms the grace deadline and settles it.
    await appendAndPublish(db, fanout, "session.updated", session.id, { backgroundTasks: [] })
    await vi.advanceTimersByTimeAsync(30)
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      latestAttentionSequence: 1,
      unreadCount: 1
    })
    scheduler.close()
    await run(db.close)
  })

  it("arms recovered deadlines and clears live timers on close", async () => {
    const { db } = await makeAttentionDb(60_000)
    const fanout = await run(makeEventFanout)

    const project = await run(db.createProject({ folderPath: "/tmp/attention-close" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "claude-code" }))
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        turnId: "turn-1",
        turnState: "started"
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        backgroundTasks: [
          { id: "agent-1", description: "Research", status: "running", taskType: "subagent" }
        ]
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        stopReason: "end_turn",
        turnId: "turn-1",
        turnState: "ended"
      })
    )
    await run(db.appendEvent("session.updated", session.id, { backgroundTasks: [] }))
    expect(await run(db.getAttentionSettleDeadline(session.id))).toBeDefined()

    const scheduler = makeAttentionSettleScheduler(db, fanout)
    await scheduler.recover()
    // The far-future deadline is armed; closing tears the timer down without
    // settling anything.
    scheduler.close()
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      latestAttentionSequence: 0,
      sidebarState: "inProgress"
    })
    await run(db.close)
  })

  it("re-arms migrated parked finishes with no recorded deadline", async () => {
    const { db, filename } = await makeAttentionDb(30)
    const fanout = await run(makeEventFanout)

    const project = await run(db.createProject({ folderPath: "/tmp/attention-migrated" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "claude-code" }))
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        turnId: "turn-1",
        turnState: "started"
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        backgroundTasks: [
          { id: "agent-1", description: "Research", status: "running", taskType: "subagent" }
        ]
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        stopReason: "end_turn",
        turnId: "turn-1",
        turnState: "ended"
      })
    )
    await run(db.appendEvent("session.updated", session.id, { backgroundTasks: [] }))
    // The revision-counter migration backfills stuck epochs as parked
    // finishes with no deadline; reproduce that exact durable state.
    const sqlite = new Database(filename)
    sqlite
      .prepare("update session_attention set settle_due_at = null where session_id = ?")
      .run(session.id)
    sqlite.close()

    // Recovery settles it: the grace is armed in-transaction and the
    // returned deadline schedules the flip.
    const scheduler = makeAttentionSettleScheduler(db, fanout)
    await scheduler.recover()
    await vi.advanceTimersByTimeAsync(30)
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      latestAttentionSequence: 1,
      unreadCount: 1
    })
    scheduler.close()
    await run(db.close)
  })
})
