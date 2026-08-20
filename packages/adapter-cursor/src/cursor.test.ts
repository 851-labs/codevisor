import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { describe, expect, it } from "vitest"
import {
  CursorTodoTracker,
  cursorAskQuestion,
  cursorCreatePlanQuestion,
  cursorGenerateImageEvent,
  cursorTaskEvent
} from "./cursor.js"

const payload = (event: RuntimeEvent | undefined): Record<string, unknown> | undefined =>
  event?.payload as Record<string, unknown> | undefined

describe("Cursor ACP extensions", () => {
  it("round-trips multi-question answers by Cursor option id", () => {
    const mapped = cursorAskQuestion(
      {
        toolCallId: "tool-ask",
        title: "Need input",
        questions: [
          {
            id: "mode",
            prompt: "Which mode?",
            options: [
              { id: "agent", label: "Agent" },
              { id: "plan", label: "Plan" }
            ]
          },
          {
            id: "targets",
            prompt: "Which targets?",
            options: [
              { id: "web", label: "Web" },
              { id: "mac", label: "macOS" }
            ],
            allowMultiple: true
          }
        ]
      },
      "session-1"
    )!

    expect(mapped.questions).toEqual([
      {
        allowsOther: false,
        header: "Need input",
        id: "mode",
        options: [
          { id: "agent", label: "Agent" },
          { id: "plan", label: "Plan" }
        ],
        question: "Which mode?"
      },
      {
        allowsOther: false,
        header: "Need input",
        id: "targets",
        multiSelect: true,
        options: [
          { id: "web", label: "Web" },
          { id: "mac", label: "macOS" }
        ],
        question: "Which targets?"
      }
    ])
    expect(
      mapped.responseFor({
        outcome: "answered",
        answers: {
          mode: { answers: ["Plan"] },
          targets: { answers: ["Web", "macOS"] }
        }
      })
    ).toEqual({
      outcome: {
        outcome: "answered",
        answers: [
          { questionId: "mode", selectedOptionIds: ["plan"] },
          { questionId: "targets", selectedOptionIds: ["web", "mac"] }
        ]
      }
    })
  })

  it("surfaces plan markdown and maps approval or rejection feedback", () => {
    const mapped = cursorCreatePlanQuestion(
      {
        toolCallId: "tool-plan",
        name: "Refactor tabs",
        overview: "Tighten layout behavior.",
        plan: "1. Inspect\n2. Update"
      },
      "session-1"
    )!
    expect(mapped.planDocument).toBe("1. Inspect\n2. Update")
    expect(
      mapped.responseFor({
        outcome: "answered",
        answers: { cursor_create_plan: { answers: ["Accept plan"] } }
      })
    ).toEqual({ outcome: { outcome: "accepted" } })
    expect(
      mapped.responseFor({
        outcome: "answered",
        answers: {
          cursor_create_plan: { answers: ["Reject plan"], note: "Keep the old API" }
        }
      })
    ).toEqual({ outcome: { outcome: "rejected", reason: "Keep the old API" } })
  })

  it("maintains full todo snapshots when Cursor sends merge updates", () => {
    const tracker = new CursorTodoTracker()
    const first = tracker.update("session-1", {
      toolCallId: "todo-1",
      merge: false,
      todos: [
        { id: "a", content: "Inspect", status: "in_progress" },
        { id: "b", content: "Verify", status: "pending" }
      ]
    })
    const merged = tracker.update("session-1", {
      toolCallId: "todo-2",
      merge: true,
      todos: [
        { id: "a", content: "Inspect", status: "completed" },
        { id: "c", content: "Document", status: "cancelled" }
      ]
    })

    expect(payload(first)).toMatchObject({
      entries: [
        { content: "Inspect", status: "in_progress" },
        { content: "Verify", status: "pending" }
      ],
      sessionUpdate: "plan"
    })
    expect(payload(merged)).toMatchObject({
      entries: [
        { content: "Inspect", status: "completed" },
        { content: "Verify", status: "pending" },
        { content: "Document", status: "completed" }
      ]
    })
  })

  it("enriches task and generated-image tool calls without creating a second stream", () => {
    expect(
      payload(
        cursorTaskEvent(
          {
            toolCallId: "task-1",
            description: "Explore auth",
            prompt: "Find auth code",
            subagentType: "explore",
            agentId: "agent-1",
            durationMs: 250
          },
          "session-1"
        )
      )
    ).toMatchObject({
      kind: "agent",
      sessionUpdate: "tool_call",
      status: "completed",
      toolCallId: "task-1"
    })
    expect(
      payload(
        cursorGenerateImageEvent(
          { toolCallId: "image-1", description: "App icon", filePath: "/tmp/icon.png" },
          "session-1"
        )
      )
    ).toMatchObject({
      locations: [{ path: "/tmp/icon.png" }],
      sessionUpdate: "tool_call_update",
      status: "completed",
      toolCallId: "image-1"
    })
  })
})
