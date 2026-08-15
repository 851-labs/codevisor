import { Effect } from "effect"
import { describe, expect, it } from "vitest"
import { makeDatabase } from "./index.js"
import { run, tempDatabase } from "./test-support.js"

describe("@codevisor/db", () => {
  it("persists cross-device unread cursors and intrinsic action-required state", async () => {
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
      unreadCount: 1
    })

    await run(db.markSessionRead(session.id, 1))
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      lastSeenAttentionSequence: 1,
      unreadCount: 0
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
    // A client actively viewing the session can omit the cursor to
    // atomically acknowledge the server's current tip.
    await run(db.markSessionRead(session.id))
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      latestAttentionSequence: 2,
      lastSeenAttentionSequence: 2,
      unreadCount: 0
    })

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
      latestAttentionSequence: 3,
      unreadCount: 1
    })

    // Reading is shared but does not resolve the underlying blocking action.
    await run(db.markSessionRead(session.id, 3))
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      actionRequired: true,
      unreadCount: 0
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

    await run(db.markSessionUnread(session.id))
    expect((await run(db.getSessionSummary(session.id))).unreadCount).toBe(1)
    await Effect.runPromise(db.close)
  })

  it("advances native sidebar ordering only when the visible state changes", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/sidebar-state" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    const initial = await run(db.getSessionSummary(session.id))
    expect(initial).toMatchObject({
      sidebarState: "idle",
      sidebarStateChangedAt: initial.createdAt
    })

    await new Promise((resolve) => setTimeout(resolve, 2))
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

    await new Promise((resolve) => setTimeout(resolve, 2))
    await run(db.appendEvent("session.updated", session.id, { backgroundTasks: [] }))
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

    await new Promise((resolve) => setTimeout(resolve, 2))
    await run(db.markSessionRead(session.id))
    const idle = await run(db.getSessionSummary(session.id))
    expect(idle.sidebarState).toBe("idle")
    expect(idle.sidebarStateChangedAt).not.toBe(unread.sidebarStateChangedAt)

    await Effect.runPromise(db.close)
  })

  it("waits for agent continuations and normalizes unknown runtime states", async () => {
    const db = await run(makeDatabase({ filename: tempDatabase(), serverId: "local" }))
    const project = await run(db.createProject({ folderPath: "/tmp/continued-attention" }))
    const session = await run(db.createSession({ projectId: project.id, harnessId: "codex" }))

    // A terminal callback with no user-owned epoch is only continuation
    // bookkeeping. It must not invent unread attention.
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "agent",
        stopReason: "end_turn",
        turnId: "orphan-continuation",
        turnState: "ended"
      })
    )
    expect((await run(db.getSessionSummary(session.id))).unreadCount).toBe(0)

    await run(
      db.appendEvent("session.updated", session.id, {
        runtimeState: "running",
        turnId: "user-turn",
        turnState: "started"
      })
    )
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "user",
        stopReason: "end_turn",
        turnId: "user-turn",
        turnState: "ended"
      })
    )
    expect((await run(db.getSessionSummary(session.id))).unreadCount).toBe(0)

    // Agent-owned terminal events preserve the pending user epoch while the
    // harness is still running. Unknown future runtime values degrade to idle,
    // which safely releases that epoch instead of leaving it stuck forever.
    await run(
      db.appendEvent("session.updated", session.id, {
        initiatedBy: "agent",
        stopReason: "end_turn",
        turnId: "agent-continuation",
        turnState: "ended"
      })
    )
    expect((await run(db.getSessionSummary(session.id))).unreadCount).toBe(0)
    await run(
      db.appendEvent("session.updated", session.id, {
        runtimeState: "future-runtime-state"
      })
    )
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      latestAttentionSequence: 1,
      unreadCount: 1
    })

    // An agent-initiated failure is independently noteworthy even when there
    // is no pending user epoch.
    await run(
      db.appendEvent("session.error", session.id, {
        initiatedBy: "agent",
        message: "Continuation failed"
      })
    )
    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      latestAttentionSequence: 2,
      unreadCount: 2
    })

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
    await run(first.markSessionRead(session.id, 1))
    await Effect.runPromise(first.close)

    const reopened = await run(makeDatabase({ filename, serverId: "local" }))
    expect(await run(reopened.getSessionSummary(session.id))).toMatchObject({
      actionRequired: true,
      actionRequiredKind: "question",
      latestAttentionSequence: 1,
      lastSeenAttentionSequence: 1,
      unreadCount: 0
    })
    expect(await run(reopened.getSessionDetail(session.id))).toMatchObject({
      pendingQuestion: { questionId: "question-after-restart" }
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

    expect(await run(db.getSessionSummary(session.id))).toMatchObject({
      actionRequired: true,
      actionRequiredKind: "planApproval",
      pendingPlanApproval: true,
      unreadCount: 1
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
