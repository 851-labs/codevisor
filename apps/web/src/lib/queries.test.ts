import type { EventEnvelope, SessionDetail } from "@herdman/api"
import { describe, expect, it } from "vitest"

import { replaySessionEvents } from "./queries"

function event(id: number, payload: unknown, kind: EventEnvelope["kind"] = "session.output") {
  return {
    id,
    serverId: "local",
    kind,
    subjectId: "session-1",
    createdAt: `2026-01-01T00:00:0${id}.000Z`,
    payload
  } satisfies EventEnvelope
}

function detail(): SessionDetail {
  return {
    session: {} as SessionDetail["session"],
    conversation: [],
    promptQueue: [],
    eventCursor: 99
  }
}

describe("replaySessionEvents", () => {
  it("preserves retry progress until real content arrives", () => {
    const retrying = replaySessionEvents(detail(), [
      event(1, { retrying: { attempt: 2, of: 5 } }, "session.updated")
    ])
    const retryingAssistant = retrying.conversation.find((item) => item.role === "assistant")
    expect(retryingAssistant?.isGenerating).toBe(true)
    expect(retrying.turnMeta?.[retryingAssistant?.id ?? ""]?.retryStatus).toEqual({
      attempt: 2,
      of: 5
    })

    const recovered = replaySessionEvents(detail(), [
      event(1, { retrying: { attempt: 2, of: 5 } }, "session.updated"),
      event(2, {
        sessionUpdate: "agent_message_chunk",
        messageId: "answer",
        content: { type: "text", text: "Recovered." }
      }),
      event(
        3,
        { stopReason: "max_tokens", stopDetail: "The model reached its token limit." },
        "session.updated"
      )
    ])
    const recoveredAssistant = recovered.conversation.find((item) => item.role === "assistant")
    expect(recoveredAssistant?.isGenerating).toBe(false)
    expect(recovered.turnMeta?.[recoveredAssistant?.id ?? ""]).toMatchObject({
      retryStatus: undefined,
      stopReason: "max_tokens",
      stopDetail: "The model reached its token limit."
    })

    const phaseRecovered = replaySessionEvents(detail(), [
      event(1, {
        sessionUpdate: "agent_message_chunk",
        messageId: "answer",
        phase: "commentary",
        content: { type: "text", text: "Checking." }
      }),
      event(2, { retrying: { attempt: 1, of: 3 } }, "session.updated"),
      event(3, {
        sessionUpdate: "agent_message_chunk",
        messageId: "answer",
        phase: "final",
        content: { type: "text", text: "" }
      })
    ])
    const phaseAssistant = phaseRecovered.conversation.find((item) => item.role === "assistant")
    expect(phaseRecovered.turnMeta?.[phaseAssistant?.id ?? ""]?.retryStatus).toBeUndefined()
  })

  it("rebuilds a rich transcript from raw session history", () => {
    const replayed = replaySessionEvents(detail(), [
      event(1, {
        sessionUpdate: "user_message_chunk",
        messageId: "u1",
        content: { type: "text", text: "please patch it" }
      }),
      event(2, {
        sessionUpdate: "tool_call",
        toolCallId: "edit-1",
        kind: "edit",
        status: "in_progress",
        title: "Edit app.ts"
      }),
      event(3, {
        sessionUpdate: "tool_call_update",
        toolCallId: "edit-1",
        status: "completed",
        content: [{ type: "diff", path: "app.ts", oldText: "old", newText: "new" }],
        diffStats: [{ path: "app.ts", added: 1, removed: 1 }]
      }),
      event(4, {
        sessionUpdate: "plan_document",
        markdown: "1. Inspect\n2. Patch"
      }),
      event(5, {
        sessionUpdate: "agent_message_chunk",
        messageId: "a1",
        content: { type: "text", text: "Done." }
      }),
      event(6, { stopReason: "end_turn" }, "session.updated")
    ])

    expect(replayed.eventCursor).toBe(99)
    expect(replayed.conversation.map((item) => [item.role, item.text, item.isGenerating])).toEqual([
      ["user", "please patch it", false],
      ["assistant", "Done.", false]
    ])

    const assistant = replayed.conversation.find((item) => item.role === "assistant")
    expect(assistant).toBeDefined()
    const meta = replayed.turnMeta?.[assistant?.id ?? ""]
    expect(meta?.startedAt).toBe("2026-01-01T00:00:02.000Z")
    expect(meta?.endedAt).toBe("2026-01-01T00:00:06.000Z")
    expect(meta?.planDocument).toBe("1. Inspect\n2. Patch")
    expect(meta?.toolCalls).toHaveLength(1)
    expect(meta?.toolCalls[0]).toMatchObject({
      toolCallId: "edit-1",
      status: "completed",
      content: [{ type: "diff", path: "app.ts", oldText: "old", newText: "new" }],
      diffStats: [{ path: "app.ts", added: 1, removed: 1 }]
    })
  })

  it("routes subagent transcript output into the spawning turn", () => {
    const replayed = replaySessionEvents(detail(), [
      event(1, {
        sessionUpdate: "user_message_chunk",
        messageId: "u1",
        content: { type: "text", text: "delegate this" }
      }),
      event(2, {
        sessionUpdate: "tool_call",
        toolCallId: "task-1",
        kind: "agent",
        status: "in_progress",
        title: "Agent: inspect transcript"
      }),
      event(
        3,
        {
          backgroundTasks: [
            {
              id: "bg-1",
              description: "Inspect transcript",
              status: "running",
              taskType: "subagent",
              toolUseId: "task-1"
            }
          ]
        },
        "session.updated"
      ),
      event(4, { stopReason: "end_turn" }, "session.updated"),
      event(5, {
        sessionUpdate: "agent_message_chunk",
        messageId: "sub-msg",
        parentToolCallId: "task-1",
        content: { type: "text", text: "Reading Swift views." }
      }),
      event(6, {
        sessionUpdate: "tool_call",
        toolCallId: "sub-read",
        kind: "read",
        status: "completed",
        title: "Read AssistantTurnView.swift",
        parentToolCallId: "task-1"
      })
    ])

    const assistant = replayed.conversation.find((item) => item.role === "assistant")
    expect(assistant?.text).toBe("")
    expect(replayed.runningSubagentToolCallIds).toEqual(["task-1"])

    const meta = replayed.turnMeta?.[assistant?.id ?? ""]
    expect(meta?.entries).toMatchObject([
      { type: "tool", call: { toolCallId: "task-1", status: "completed" } }
    ])
    expect(meta?.textPhases).toEqual({})
    expect(meta?.subagents["task-1"]?.entries).toMatchObject([
      { type: "text", id: "acp:sub-msg", markdown: "Reading Swift views." },
      { type: "tool", call: { toolCallId: "sub-read", parentToolCallId: "task-1" } }
    ])
  })

  it("routes nested agent output to its original turn and cascades parent settlement", () => {
    const replayed = replaySessionEvents(detail(), [
      event(1, {
        sessionUpdate: "tool_call",
        toolCallId: "task-1",
        kind: "agent",
        status: "in_progress",
        title: "Agent: outer"
      }),
      event(2, {
        sessionUpdate: "tool_call",
        toolCallId: "task-2",
        kind: "agent",
        status: "in_progress",
        title: "Agent: inner",
        parentToolCallId: "task-1"
      }),
      event(3, { stopReason: "end_turn" }, "session.updated"),
      event(4, {
        sessionUpdate: "tool_call",
        toolCallId: "sub-run",
        kind: "execute",
        status: "in_progress",
        title: "Run checks",
        parentToolCallId: "task-2"
      }),
      event(5, {
        sessionUpdate: "tool_call_update",
        toolCallId: "task-1",
        status: "completed"
      })
    ])

    const assistants = replayed.conversation.filter((item) => item.role === "assistant")
    expect(assistants).toHaveLength(1)
    const meta = replayed.turnMeta?.[assistants[0]?.id ?? ""]
    expect(meta?.subagents["task-1"]?.entries).toMatchObject([
      { type: "tool", call: { toolCallId: "task-2", status: "completed" } }
    ])
    expect(meta?.subagents["task-2"]?.entries).toMatchObject([
      { type: "tool", call: { toolCallId: "sub-run", status: "completed" } }
    ])
    expect(meta?.subagents["task-2"]?.isThinking).toBe(false)
  })

  it("preserves live user attachments while replaying output events", () => {
    const attachment = {
      fileId: "file-1",
      name: "screenshot.png",
      mimeType: "image/png",
      sizeBytes: 42,
      kind: "image" as const
    }
    const replayed = replaySessionEvents(detail(), [
      event(1, {
        role: "user",
        text: "Look at this",
        attachments: [attachment]
      })
    ])

    expect(replayed.conversation).toHaveLength(1)
    expect(replayed.conversation[0]).toMatchObject({
      role: "user",
      text: "Look at this",
      attachments: [attachment]
    })
  })

  it("clears main thinking state when a turn settles", () => {
    const replayed = replaySessionEvents(detail(), [
      event(1, {
        sessionUpdate: "agent_thought_chunk",
        content: { type: "text", text: "thinking" }
      }),
      event(2, { stopReason: "end_turn" }, "session.updated")
    ])

    const assistant = replayed.conversation.find((item) => item.role === "assistant")
    expect(assistant?.isGenerating).toBe(false)
    expect(replayed.turnMeta?.[assistant?.id ?? ""]?.isThinking).toBe(false)
  })

  it("clears a stale stream error when a non-text update starts a new turn", () => {
    const replayed = replaySessionEvents(detail(), [
      event(1, { message: "Connection lost" }, "session.error"),
      event(2, {
        sessionUpdate: "tool_call",
        toolCallId: "read-1",
        kind: "read",
        status: "in_progress",
        title: "Read queries.ts"
      })
    ])

    expect(replayed.streamError).toBeUndefined()
    expect(replayed.conversation).toMatchObject([{ role: "assistant", isGenerating: true }])
  })

  it("keeps a pending question until its resolution arrives", () => {
    const replayed = replaySessionEvents(detail(), [
      event(1, {
        sessionUpdate: "question",
        questionId: "q1",
        questions: [
          {
            id: "choice",
            question: "Proceed?",
            options: [{ label: "Yes" }, { label: "No" }],
            allowsOther: false
          }
        ]
      })
    ])

    expect(replayed.pendingQuestion).toMatchObject({
      questionId: "q1",
      questions: [{ id: "choice", question: "Proceed?" }]
    })

    const resolved = replaySessionEvents(detail(), [
      event(1, {
        sessionUpdate: "question",
        questionId: "q1",
        questions: [
          {
            id: "choice",
            question: "Proceed?",
            options: [{ label: "Yes" }, { label: "No" }],
            allowsOther: false
          }
        ]
      }),
      event(2, {
        sessionUpdate: "question_resolved",
        questionId: "q1",
        outcome: "cancelled",
        questions: [
          {
            id: "choice",
            question: "Proceed?",
            options: [{ label: "Yes" }, { label: "No" }],
            allowsOther: false
          }
        ]
      })
    ])

    expect(resolved.pendingQuestion).toBeUndefined()

    const finished = replaySessionEvents(detail(), [
      event(1, {
        sessionUpdate: "question",
        questionId: "q1",
        questions: [
          {
            id: "choice",
            question: "Proceed?",
            options: [{ label: "Yes" }, { label: "No" }],
            allowsOther: false
          }
        ]
      }),
      event(2, { stopReason: "end_turn" }, "session.updated")
    ])
    expect(finished.pendingQuestion).toBeUndefined()

    const failed = replaySessionEvents(detail(), [
      event(1, {
        sessionUpdate: "question",
        questionId: "q1",
        questions: [
          {
            id: "choice",
            question: "Proceed?",
            options: [{ label: "Yes" }, { label: "No" }],
            allowsOther: false
          }
        ]
      }),
      event(2, { message: "Connection lost" }, "session.error")
    ])
    expect(failed.pendingQuestion).toBeUndefined()
  })

  it("replays plan updates into pinned session todos", () => {
    const replayed = replaySessionEvents(detail(), [
      event(1, {
        sessionUpdate: "plan",
        entries: [
          { content: "Read code", status: "completed" },
          { content: "Patch UI", status: "in_progress" }
        ]
      })
    ])

    expect(replayed.sessionPlan).toEqual([
      { content: "Read code", priority: undefined, status: "completed" },
      { content: "Patch UI", priority: undefined, status: "in_progress" }
    ])

    const assistant = replayed.conversation.find((item) => item.role === "assistant")
    const meta = replayed.turnMeta?.[assistant?.id ?? ""]
    expect(meta?.plan).toEqual(replayed.sessionPlan)
  })

  it("replays config option snapshots into session state", () => {
    const configOptions = [
      {
        id: "mode",
        name: "Mode",
        category: "mode",
        currentValue: "plan",
        options: [
          { value: "plan", name: "Plan" },
          { value: "bypass", name: "Bypass Permissions" }
        ]
      }
    ]

    const replayed = replaySessionEvents(detail(), [event(1, { configOptions }, "session.updated")])

    expect(replayed.configOptions).toEqual(configOptions)
  })

  it("replays goal snapshots and clears into session state", () => {
    const goal = {
      objective: "ship parity",
      status: "active",
      tokenBudget: null,
      tokensUsed: 2500,
      timeUsedSeconds: 300,
      createdAt: "2026-01-01T00:00:00.000Z",
      updatedAt: "2026-01-01T00:00:01.000Z"
    }

    const replayed = replaySessionEvents(detail(), [
      event(1, { goal }, "session.updated"),
      event(2, { goal: { ...goal, status: "paused" } }, "session.updated")
    ])

    expect(replayed.goal).toMatchObject({ objective: "ship parity", status: "paused" })

    const cleared = replaySessionEvents(detail(), [
      event(1, { sessionUpdate: "goal_update", goal }),
      event(2, { goalCleared: true }, "session.updated")
    ])

    expect(cleared.goal).toBeUndefined()
  })
})

it("replays worktree setup phases for worktree-backed sessions", () => {
  const replayed = replaySessionEvents(
    {
      ...detail(),
      session: { worktreeName: "fix-auth-1234" } as SessionDetail["session"]
    },
    [
      event(
        1,
        {
          state: "started",
          worktreeId: "wt-1",
          projectId: "project-1",
          name: "fix-auth-1234",
          branch: "herdman/fix-auth-1234"
        },
        "worktree.setup"
      ),
      event(
        2,
        {
          state: "log",
          worktreeId: "wt-1",
          projectId: "project-1",
          name: "fix-auth-1234",
          branch: "herdman/fix-auth-1234",
          stream: "stderr",
          line: "Preparing worktree..."
        },
        "worktree.setup"
      ),
      event(
        3,
        {
          state: "completed",
          worktreeId: "wt-1",
          projectId: "project-1",
          name: "fix-auth-1234",
          branch: "herdman/fix-auth-1234",
          durationMs: 2000
        },
        "worktree.setup"
      )
    ]
  )

  expect(replayed.setupPhases).toMatchObject([
    {
      id: "worktree",
      outcome: "succeeded",
      logs: [{ stream: "stderr", text: "Preparing worktree..." }]
    }
  ])
})

it("replays session-subject worktree setup before the worktree name is patched", () => {
  const replayed = replaySessionEvents(
    {
      ...detail(),
      session: { id: "session-1" } as SessionDetail["session"]
    },
    [
      event(
        1,
        {
          state: "started",
          worktreeId: "wt-1",
          projectId: "project-1",
          name: "fix-auth-1234",
          branch: "herdman/fix-auth-1234"
        },
        "worktree.setup"
      ),
      event(
        2,
        {
          state: "completed",
          worktreeId: "wt-1",
          projectId: "project-1",
          name: "fix-auth-1234",
          branch: "herdman/fix-auth-1234",
          durationMs: 1500
        },
        "worktree.setup"
      )
    ]
  )

  expect(replayed.setupPhases).toMatchObject([{ id: "worktree", outcome: "succeeded" }])
})
