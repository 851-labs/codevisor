import { Effect } from "effect"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("@codevisor/db", () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ["Date"] })
    vi.setSystemTime(new Date("2026-01-01T00:00:00Z"))
  })
  afterEach(() => vi.useRealTimers())
  it("re-arms and disarms the settle deadline as holds come and go", async () => {
    const db = await run(
      makeDatabase({ filename: tempDatabase(), serverId: "local", attentionSettleGraceMs: 60_000 })
    )
    const project = await run(db.createProject({ folderPath: "/tmp/settle-rearm" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "claude-code" }))
    const subagentSnapshot = {
      backgroundTasks: [
        { id: "agent-1", description: "Research", status: "running", taskType: "subagent" }
      ]
    }

    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        turnId: "turn-1",
        turnState: "started"
      })
    )
    await run(db.appendEvent("session.updated", session.id, subagentSnapshot))
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        stopReason: "end_turn",
        turnId: "turn-1",
        turnState: "ended"
      })
    )
    // Settling while still held is a no-op (a raced timer, a stale recovery).
    expect(await run(db.settleSessionAttention(session.id))).toEqual({ settled: false })

    // The hold releases (deadline armed), then a new subagent appears before
    // any turn starts: the deadline disarms and the finish stays parked.
    await run(db.appendEvent("session.updated", session.id, { backgroundTasks: [] }))
    expect(await run(db.getAttentionSettleDeadline(session.id))).toBeDefined()
    // Events inside the grace window leave the armed deadline untouched.
    await run(db.appendEvent("session.output", session.id, { role: "assistant", text: "late" }))
    expect((await run(db.getSessionSummary(session.id))).latestAttentionSequence).toBe(0)
    await run(db.appendEvent("session.updated", session.id, subagentSnapshot))
    expect(await run(db.getAttentionSettleDeadline(session.id))).toBeUndefined()
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      latestAttentionSequence: 0,
      sidebarState: "inProgress"
    })
    await Effect.runPromise(db.close)
  })

  it("settles an expired deadline in-transaction with the next event", async () => {
    const db = await run(
      makeDatabase({ filename: tempDatabase(), serverId: "local", attentionSettleGraceMs: 0 })
    )
    const project = await run(db.createProject({ folderPath: "/tmp/settle-inline" }))
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
    // Hold release arms the (zero) grace; the projection itself converges on
    // the next inbound event even if the server-side timer never fires.
    await run(db.appendEvent("session.updated", session.id, { backgroundTasks: [] }))
    vi.setSystemTime(Date.now() + 2)
    await run(db.appendEvent("session.output", session.id, { role: "assistant", text: "done" }))
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      latestAttentionSequence: 1,
      unreadCount: 1,
      sidebarState: "unread"
    })
    await Effect.runPromise(db.close)
  })

  it("normalizes runtime state and holds inProgress while running", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/runtime-state" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "claude-code" }))

    await run(db.appendEvent("session.updated", session.id, { runtimeState: "running" }))
    expect((await run(db.getSessionSummary(session.id))).sidebarState).toBe("inProgress")
    // Unknown future runtime values degrade to idle instead of pinning the
    // sidebar in progress forever.
    await run(db.appendEvent("session.updated", session.id, { runtimeState: "future-state" }))
    expect((await run(db.getSessionSummary(session.id))).sidebarState).toBe("idle")
    await Effect.runPromise(db.close)
  })

  it("advances native sidebar ordering only when the visible state changes", async () => {
    const db = await run(
      makeDatabase({ filename: tempDatabase(), serverId: "local", attentionSettleGraceMs: 0 })
    )
    const project = await run(db.createProject({ folderPath: "/tmp/sidebar-state" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    const initial = await run(db.getSessionSummary(session.id))
    expect(initial).toMatchObject({
      sidebarState: "idle",
      sidebarStateChangedAt: initial.createdAt
    })

    vi.setSystemTime(Date.now() + 2)
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        turnId: "turn-1",
        turnState: "started"
      })
    )
    const started = await run(db.getSessionSummary(session.id))
    expect(started.sidebarState).toBe("inProgress")
    expect(started.sidebarStateChangedAt).not.toBe(initial.sidebarStateChangedAt)

    await run(
      db.appendEvent("session.output", session.id, {
        role: "assistant",
        text: "streaming"
      })
    )
    expect((await run(db.getSessionSummary(session.id))).sidebarStateChangedAt).toBe(
      started.sidebarStateChangedAt
    )

    await run(
      db.appendEvent("session.updated", session.id, {
        backgroundTasks: [
          {
            id: "subagent-1",
            description: "Investigate",
            status: "running",
            taskType: "subagent"
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
    const waitingOnBackground = await run(db.getSessionSummary(session.id))
    expect(waitingOnBackground.sidebarState).toBe("inProgress")
    expect(waitingOnBackground.sidebarStateChangedAt).toBe(started.sidebarStateChangedAt)

    vi.setSystemTime(Date.now() + 2)
    await run(db.appendEvent("session.updated", session.id, { backgroundTasks: [] }))
    await run(db.settleSessionAttention(session.id))
    const unread = await run(db.getSessionSummary(session.id))
    expect(unread.sidebarState).toBe("unread")
    expect(unread.sidebarStateChangedAt).not.toBe(started.sidebarStateChangedAt)

    await run(
      db.appendEvent("session.output", session.id, {
        role: "assistant",
        text: "late detail"
      })
    )
    expect((await run(db.getSessionSummary(session.id))).sidebarStateChangedAt).toBe(
      unread.sidebarStateChangedAt
    )

    vi.setSystemTime(Date.now() + 2)
    await run(db.markSessionRead(session.id, unread.latestAttentionSequence ?? 0))
    const idle = await run(db.getSessionSummary(session.id))
    expect(idle.sidebarState).toBe("idle")
    expect(idle.sidebarStateChangedAt).not.toBe(unread.sidebarStateChangedAt)

    await Effect.runPromise(db.close)
  })

  it("restores attention and shared read state after a server restart", async () => {
    const filename = tempDatabase()
    const first = await run(makeDatabase({ filename, serverId: "local" }))
    const project = await run(first.createProject({ folderPath: "/tmp/restart-attention" }))
    const session = await run(
      first.createSession({ projectId: project.id, harnessId: "claude-code" })
    )
    await run(
      first.appendEvent("session.output", session.id, {
        questionId: "question-after-restart",
        questions: [
          {
            id: "choice",
            question: "Continue?",
            options: [{ label: "Yes" }],
            allowsOther: false
          }
        ],
        sessionUpdate: "question"
      })
    )
    // A parked finish in a second session survives the restart for the
    // settle scheduler's recovery pass to drain.
    const held = await run(first.createSession({ projectId: project.id, harnessId: "claude-code" }))
    await run(
      first.appendEvent("session.updated", held.id, {
        initiatedBy: "user",
        turnId: "turn-1",
        turnState: "started"
      })
    )
    await run(
      first.appendEvent("session.updated", held.id, {
        backgroundTasks: [
          { id: "agent-1", description: "Research", status: "running", taskType: "subagent" }
        ]
      })
    )
    await run(
      first.appendEvent("session.updated", held.id, {
        initiatedBy: "user",
        stopReason: "end_turn",
        turnId: "turn-1",
        turnState: "ended"
      })
    )
    await run(first.markSessionRead(session.id, 0))
    await Effect.runPromise(first.close)

    const reopened = await run(
      makeDatabase({ filename, serverId: "local", attentionSettleGraceMs: 0 })
    )
    expect(await run(reopened.getSessionSummary(session.id))).toMatchObject({
      actionRequired: true,
      actionRequiredKind: "question",
      latestAttentionSequence: 0,
      unreadCount: 0
    })
    expect(await run(reopened.getSessionDetail(session.id))).toMatchObject({
      pendingQuestion: { questionId: "question-after-restart" }
    })
    expect(await run(reopened.listPendingAttentionSettles)).toEqual([
      { sessionId: held.id, dueAt: null }
    ])
    // Startup reconciliation clears the stale subagent snapshot, then
    // recovery settles the stranded finish.
    await run(reopened.appendEvent("session.updated", held.id, { backgroundTasks: [] }))
    expect((await run(reopened.settleSessionAttention(held.id))).settled).toBe(true)
    expect(await run(reopened.getSessionSummary(held.id))).toMatchObject({
      latestAttentionSequence: 1,
      unreadCount: 1,
      sidebarState: "unread"
    })
    await Effect.runPromise(reopened.close)
  })

  it("persists Codex plan approval as a server-owned action", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/plan-attention" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    await run(db.appendEvent("session.updated", session.id, { modeId: "plan" }))
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        turnId: "turn-plan",
        turnState: "started"
      })
    )
    await run(
      db.appendEvent("session.output", session.id, {
        markdown: "# Plan\n\nBuild it.",
        sessionUpdate: "plan_document"
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        stopReason: "end_turn",
        turnId: "turn-plan",
        turnState: "ended"
      })
    )

    // Approval is blocking state, not unread: the user's answer settles the
    // turn they are already looking at.
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      actionRequired: true,
      actionRequiredKind: "planApproval",
      pendingPlanApproval: true,
      unreadCount: 0,
      sidebarState: "waitingForUser"
    })
    expect(await run(db.getTranscriptPage(session.id, undefined, 8))).toMatchObject({
      pendingPlanApproval: true
    })

    await run(db.clearSessionPlanApproval(session.id))
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      actionRequired: false,
      pendingPlanApproval: false
    })
    expect(await run(db.getSessionDetail(session.id))).toMatchObject({
      pendingPlanApproval: false
    })
    expect(await run(db.getTranscriptPage(session.id, undefined, 8))).toMatchObject({
      pendingPlanApproval: false
    })
    await Effect.runPromise(db.close)
  })

  it("snapshots a pending question with the session cursor and clears it terminally", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/pending-question" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))
    const question = {
      sessionUpdate: "question" as const,
      questionId: "question-1",
      questions: [
        {
          id: "choice",
          question: "Continue?",
          options: [{ label: "Yes" }, { label: "No" }],
          allowsOther: false
        }
      ]
    }

    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        turnId: "turn-1",
        turnState: "started"
      })
    )
    await run(db.appendEvent("session.output", session.id, question))

    expect(await run(db.getTranscriptPage(session.id, undefined, 8))).toMatchObject({
      eventCursor: 2,
      pendingQuestion: question
    })
    expect((await run(db.getSessionDetail(session.id))).pendingQuestion).toEqual(question)
    const backgroundTasks = [
      {
        id: "task-1",
        description: "Run checks",
        status: "running",
        taskType: "shell"
      }
    ]
    await run(db.appendEvent("session.updated", session.id, { backgroundTasks }))
    expect(await run(db.getTranscriptPage(session.id, undefined, 8))).toMatchObject({
      pendingQuestion: question,
      backgroundTasks
    })
    expect((await run(db.getSessionDetail(session.id))).backgroundTasks).toEqual(backgroundTasks)
    // A stale resolution must not release a newer pending continuation.
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "question_resolved",
        questionId: "different-question",
        outcome: "cancelled",
        questions: []
      })
    )
    expect((await run(db.getTranscriptPage(session.id, undefined, 8))).pendingQuestion).toEqual(
      question
    )

    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "question_resolved",
        questionId: question.questionId,
        outcome: "answered",
        questions: question.questions
      })
    )
    expect(
      (await run(db.getTranscriptPage(session.id, undefined, 8))).pendingQuestion
    ).toBeUndefined()
    // Resolution delivery is idempotent even after the blocking snapshot has
    // already been cleared.
    await run(
      db.appendEvent("session.output", session.id, {
        sessionUpdate: "question_resolved",
        questionId: question.questionId,
        outcome: "answered",
        questions: question.questions
      })
    )
    await run(db.appendEvent("session.output", session.id, question))

    await run(db.appendEvent("session.updated", session.id, { backgroundTasks: [] }))
    expect((await run(db.getTranscriptPage(session.id, undefined, 8))).backgroundTasks).toEqual([])

    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        turnId: "turn-1",
        turnState: "ended",
        stopReason: "interrupted"
      })
    )
    expect(
      (await run(db.getTranscriptPage(session.id, undefined, 8))).pendingQuestion
    ).toBeUndefined()
    expect((await run(db.getSessionDetail(session.id))).pendingQuestion).toBeUndefined()
    await Effect.runPromise(db.close)
  })
})
