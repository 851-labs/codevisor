import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("@codevisor/db", () => {
  it("tracks unread as a revision cursor with intrinsic action-required state", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/session-attention" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      actionRequired: false,
      latestAttentionSequence: 0,
      lastSeenAttentionSequence: 0,
      unreadCount: 0
    })

    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        turnId: "turn-1",
        turnState: "started"
      })
    )
    expect((await run(db.getSessionSummary(session.id))).sidebarState).toBe("inProgress")
    await run(
      db.appendEvent("session.output", session.id, {
        role: "assistant",
        text: "The completed response",
        turnId: "turn-1"
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
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      latestAttentionSequence: 1,
      lastSeenAttentionSequence: 0,
      unreadCount: 1,
      sidebarState: "unread"
    })

    await run(db.markSessionRead(session.id, 1))
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      lastSeenAttentionSequence: 1,
      unreadCount: 0,
      sidebarState: "idle"
    })

    // A stale client may acknowledge only what it rendered. That must not
    // accidentally consume newer attention produced before its request lands.
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        turnId: "turn-2",
        turnState: "started"
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        stopReason: "end_turn",
        turnId: "turn-2",
        turnState: "ended"
      })
    )
    await run(db.markSessionRead(session.id, 1))
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      latestAttentionSequence: 2,
      lastSeenAttentionSequence: 1,
      unreadCount: 1
    })
    // Overshooting clamps to the newest revision instead of running ahead.
    await run(db.markSessionRead(session.id, 99))
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      latestAttentionSequence: 2,
      lastSeenAttentionSequence: 2,
      unreadCount: 0
    })

    // A question is intrinsic blocking state, not unread: no revision bump,
    // and reading the chat does not resolve it.
    const question = {
      questionId: "question-1",
      questions: [
        {
          id: "choice",
          question: "Continue?",
          options: [{ label: "Yes" }],
          allowsOther: false
        }
      ],
      sessionUpdate: "question"
    }
    await run(db.appendEvent("session.output", session.id, question))
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      actionRequired: true,
      actionRequiredKind: "question",
      latestAttentionSequence: 2,
      unreadCount: 0,
      sidebarState: "waitingForUser"
    })
    await run(db.markSessionRead(session.id, 2))
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      actionRequired: true,
      sidebarState: "waitingForUser"
    })
    await run(
      db.appendEvent("session.output", session.id, {
        outcome: "answered",
        questionId: question.questionId,
        questions: question.questions,
        sessionUpdate: "question_resolved"
      })
    )
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      actionRequired: false,
      unreadCount: 0
    })

    // A manual unread reads as at least one until the next mark-read.
    await run(db.markSessionUnread(session.id))
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      unreadCount: 1,
      sidebarState: "unread"
    })
    await run(db.markSessionRead(session.id, 2))
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      unreadCount: 0,
      sidebarState: "idle"
    })
    await Effect.runPromise(db.close)
  })

  it("counts a turn ended with only background shells as finished", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/shell-finish" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "claude-code" }))

    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        turnId: "turn-1",
        turnState: "started"
      })
    )
    // A dev server left running for the user: a terminal-backed shell and a
    // codex-style shell task. Neither holds the finish — whatever the agent
    // left running is FOR the user to look at.
    await run(
      db.appendEvent("session.updated", session.id, {
        backgroundTasks: [
          {
            id: "dev-server",
            description: "bun run dev",
            status: "running",
            taskType: "task",
            terminalKey: "session:bg:tool-1"
          },
          {
            id: "checks",
            description: "Run checks",
            status: "running",
            taskType: "shell"
          }
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
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      latestAttentionSequence: 1,
      unreadCount: 1,
      sidebarState: "unread"
    })
    await Effect.runPromise(db.close)
  })

  it("holds a finished turn while a subagent runs and settles it exactly once", async () => {
    const db = await run(
      makeDatabase({ filename: tempDatabase(), serverId: "local", attentionSettleGraceMs: 0 })
    )
    const project = await run(db.createProject({ folderPath: "/tmp/subagent-hold" }))
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
    // The main loop yields while the subagent runs: not ready for the user.
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        stopReason: "end_turn",
        turnId: "turn-1",
        turnState: "ended"
      })
    )
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      latestAttentionSequence: 0,
      unreadCount: 0,
      sidebarState: "inProgress"
    })

    // Subagent completes; the harness re-invokes the agent before the grace
    // elapses. The parked finish survives the continuation without bumping.
    await run(db.appendEvent("session.updated", session.id, { backgroundTasks: [] }))
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "agent",
        turnId: "turn-2",
        turnState: "started"
      })
    )
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      latestAttentionSequence: 0,
      sidebarState: "inProgress"
    })

    // Second subagent in the chain, then the final clean end.
    await run(
      db.appendEvent("session.updated", session.id, {
        backgroundTasks: [
          { id: "agent-2", description: "Verify", status: "running", taskType: "subagent" }
        ]
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "agent",
        stopReason: "end_turn",
        turnId: "turn-2",
        turnState: "ended"
      })
    )
    expect((await run(db.getSessionSummary(session.id))).sidebarState).toBe("inProgress")
    await run(db.appendEvent("session.updated", session.id, { backgroundTasks: [] }))

    // The grace elapsed (zero in this test) with no re-invocation: the whole
    // chain settles into exactly one unread revision.
    const settled = await run(db.settleSessionAttention(session.id))
    expect(settled.settled).toBe(true)
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      latestAttentionSequence: 1,
      unreadCount: 1,
      sidebarState: "unread"
    })
    // Settling is idempotent.
    expect((await run(db.settleSessionAttention(session.id))).settled).toBe(false)
    await Effect.runPromise(db.close)
  })

  it("defers a released hold until its grace deadline", async () => {
    const db = await run(
      makeDatabase({ filename: tempDatabase(), serverId: "local", attentionSettleGraceMs: 60_000 })
    )
    const project = await run(db.createProject({ folderPath: "/tmp/settle-grace" }))
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

    // The hold released moments ago: the settle is armed but not due yet.
    const early = await run(db.settleSessionAttention(session.id))
    expect(early.settled).toBe(false)
    expect(early.nextDueAt).toBeDefined()
    expect(await run(db.getAttentionSettleDeadline(session.id))).toBe(early.nextDueAt)
    expect((await run(db.getSessionSummary(session.id))).sidebarState).toBe("inProgress")
    expect(await run(db.listPendingAttentionSettles)).toEqual([
      { sessionId: session.id, dueAt: early.nextDueAt }
    ])

    // A new turn cancels the deadline but keeps the parked finish.
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "agent",
        turnId: "turn-2",
        turnState: "started"
      })
    )
    expect(await run(db.getAttentionSettleDeadline(session.id))).toBeUndefined()
    expect((await run(db.getSessionSummary(session.id))).latestAttentionSequence).toBe(0)
    await Effect.runPromise(db.close)
  })

  it("marks errored turns action-required until read or user activity", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/errored-attention" }))
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
        initiatedBy: "user",
        stopReason: "failed",
        stopDetail: "The provider crashed",
        turnId: "turn-1",
        turnState: "ended"
      })
    )
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      hasUnreadError: true,
      latestAttentionSequence: 1,
      unreadCount: 1,
      sidebarState: "errored"
    })

    // An error is the urgent flavor of unread: reading through the latest
    // revision acknowledges it.
    await run(db.markSessionRead(session.id, 1))
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      hasUnreadError: false,
      unreadCount: 0,
      sidebarState: "idle"
    })

    // A second error clears when the user acts in the chat instead.
    await run(
      db.appendEvent("session.error", session.id, {
        initiatedBy: "agent",
        message: "Continuation failed"
      })
    )
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      hasUnreadError: true,
      latestAttentionSequence: 2,
      sidebarState: "errored"
    })
    // A stale mark-read from before the error must not acknowledge it.
    await run(db.markSessionRead(session.id, 1))
    expect((await run(db.getSessionSummary(session.id))).hasUnreadError).toBe(true)
    await run(
      db.appendEvent("session.output", session.id, {
        role: "user",
        text: "try again"
      })
    )
    expect((await run(db.getSessionSummary(session.id))).hasUnreadError).toBe(false)
    await Effect.runPromise(db.close)
  })

  it("bumps the revision for agent-initiated completions", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/agent-completion" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "claude-code" }))

    // Autonomous work that finishes is something new to look at. Ping noise
    // is the client's problem (edge-triggered notifications), not a reason to
    // hide the badge.
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "agent",
        turnId: "cron-1",
        turnState: "started"
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "agent",
        stopReason: "end_turn",
        turnId: "cron-1",
        turnState: "ended"
      })
    )
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      latestAttentionSequence: 1,
      unreadCount: 1,
      sidebarState: "unread"
    })
    await Effect.runPromise(db.close)
  })
})
