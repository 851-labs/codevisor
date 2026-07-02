import type { EventEnvelope } from "@herdman/api"
import { describe, expect, it } from "vitest"

import { sessionStreamEvents } from "./session-events"

function envelope(kind: EventEnvelope["kind"], payload: unknown): EventEnvelope {
  return {
    id: 1,
    serverId: "local",
    kind,
    subjectId: "session-1",
    createdAt: "2026-01-01T00:00:00.000Z",
    payload
  }
}

describe("sessionStreamEvents", () => {
  it("maps assistant output chunks", () => {
    const events = sessionStreamEvents(
      envelope("session.output", { role: "assistant", text: "Hello", messageId: "m1" })
    )
    expect(events).toEqual([
      { type: "textChunk", role: "assistant", text: "Hello", messageId: "m1" }
    ])
  })

  it("maps user output chunks without messageId", () => {
    const events = sessionStreamEvents(envelope("session.output", { role: "user", text: "Hi" }))
    expect(events).toEqual([{ type: "textChunk", role: "user", text: "Hi", messageId: undefined }])
  })

  it("drops empty and system output", () => {
    expect(
      sessionStreamEvents(envelope("session.output", { role: "assistant", text: "" }))
    ).toEqual([])
    expect(
      sessionStreamEvents(envelope("session.output", { role: "system", text: "boot" }))
    ).toEqual([])
  })

  it("maps raw agent_message_chunk updates to assistant text", () => {
    const events = sessionStreamEvents(
      envelope("session.output", {
        sessionUpdate: "agent_message_chunk",
        content: { type: "text", text: "Hi there" },
        messageId: "m2"
      })
    )
    expect(events).toEqual([
      { type: "textChunk", role: "assistant", text: "Hi there", messageId: "m2" }
    ])
  })

  it("maps raw thought chunks", () => {
    const events = sessionStreamEvents(
      envelope("session.output", {
        sessionUpdate: "agent_thought_chunk",
        content: { type: "text", text: "pondering" }
      })
    )
    expect(events).toEqual([{ type: "thoughtChunk", text: "pondering" }])
  })

  it("maps raw tool calls and updates", () => {
    expect(
      sessionStreamEvents(
        envelope("session.output", {
          sessionUpdate: "tool_call",
          toolCallId: "t1",
          title: "Read file",
          kind: "read",
          status: "in_progress"
        })
      )
    ).toEqual([
      {
        type: "toolCall",
        call: { toolCallId: "t1", title: "Read file", kind: "read", status: "in_progress" }
      }
    ])
    expect(
      sessionStreamEvents(
        envelope("session.output", {
          sessionUpdate: "tool_call_update",
          toolCallId: "t1",
          status: "completed"
        })
      )
    ).toEqual([
      {
        type: "toolCallUpdate",
        call: { toolCallId: "t1", title: undefined, kind: undefined, status: "completed" }
      }
    ])
  })

  it("parses streamed diff stats and drops malformed entries", () => {
    const events = sessionStreamEvents(
      envelope("session.output", {
        sessionUpdate: "tool_call_update",
        toolCallId: "t1",
        status: "in_progress",
        diffStats: [
          { path: "release.yml", added: 13, removed: 7 },
          { path: "bad" },
          "junk"
        ],
        parentToolCallId: "task-1"
      })
    )
    expect(events).toEqual([
      {
        type: "toolCallUpdate",
        call: {
          toolCallId: "t1",
          title: undefined,
          kind: undefined,
          status: "in_progress",
          diffStats: [{ path: "release.yml", added: 13, removed: 7 }],
          parentToolCallId: "task-1"
        }
      }
    ])
  })

  it("passes the cancelled tool-call status through", () => {
    const events = sessionStreamEvents(
      envelope("session.output", {
        sessionUpdate: "tool_call_update",
        toolCallId: "t1",
        status: "cancelled"
      })
    )
    expect(events[0]).toMatchObject({ call: { status: "cancelled" } })
  })

  it("maps raw plan updates", () => {
    const events = sessionStreamEvents(
      envelope("session.output", {
        sessionUpdate: "plan",
        entries: [{ content: "Step one", priority: "high", status: "pending" }, { bad: true }]
      })
    )
    expect(events).toEqual([
      {
        type: "planUpdated",
        entries: [{ content: "Step one", priority: "high", status: "pending" }]
      }
    ])
  })

  it("maps raw available-commands updates", () => {
    const events = sessionStreamEvents(
      envelope("session.output", {
        sessionUpdate: "available_commands_update",
        availableCommands: [
          { name: "compact", description: "Compact the session", input: { hint: "instructions" } }
        ]
      })
    )
    expect(events).toEqual([
      {
        type: "commandsChanged",
        commands: [{ name: "compact", description: "Compact the session", hint: "instructions" }]
      }
    ])
  })

  it("maps raw usage and mode updates on session.updated", () => {
    expect(
      sessionStreamEvents(
        envelope("session.updated", {
          sessionUpdate: "usage_update",
          used: 1200,
          size: 200000,
          cost: { amount: 0.42, currency: "USD" }
        })
      )
    ).toEqual([
      {
        type: "usageChanged",
        usage: { used: 1200, size: 200000, costAmount: 0.42, costCurrency: "USD" }
      }
    ])
    expect(
      sessionStreamEvents(
        envelope("session.output", { sessionUpdate: "current_mode_update", currentModeId: "code" })
      )
    ).toEqual([{ type: "modeChanged", modeId: "code" }])
  })

  it("drops unknown raw updates", () => {
    expect(
      sessionStreamEvents(envelope("session.output", { sessionUpdate: "mystery_update" }))
    ).toEqual([])
  })

  it("maps stop reasons on session.updated to finished", () => {
    const events = sessionStreamEvents(envelope("session.updated", { stopReason: "end_turn" }))
    expect(events).toEqual([{ type: "finished", stopReason: "end_turn" }])
  })

  it("maps mode changes on session.updated", () => {
    const events = sessionStreamEvents(envelope("session.updated", { modeId: "plan" }))
    expect(events).toEqual([{ type: "modeChanged", modeId: "plan" }])
  })

  it("maps config option updates on session.updated", () => {
    const configOptions = [
      {
        id: "model",
        name: "Model",
        currentValue: "opus",
        options: [{ value: "opus", name: "Opus" }]
      }
    ]
    const events = sessionStreamEvents(envelope("session.updated", { configOptions }))
    expect(events).toMatchObject([{ type: "configOptionsChanged" }])
  })

  it("prefers config options over mode when both are present", () => {
    const events = sessionStreamEvents(
      envelope("session.updated", {
        modeId: "plan",
        configOptions: [{ id: "model", name: "Model", currentValue: "opus", options: [] }]
      })
    )
    expect(events).toMatchObject([{ type: "configOptionsChanged" }])
  })

  it("maps queue updates, tolerating malformed queues", () => {
    const queue = [
      {
        id: "q1",
        sessionId: "session-1",
        text: "next",
        createdAt: "2026-01-01T00:00:00.000Z",
        updatedAt: "2026-01-01T00:00:00.000Z"
      }
    ]
    expect(sessionStreamEvents(envelope("session.queue.updated", { queue }))).toEqual([
      { type: "queueUpdated", queue }
    ])
    expect(
      sessionStreamEvents(envelope("session.queue.updated", { queue: [{ nope: true }] }))
    ).toEqual([{ type: "queueUpdated", queue: [] }])
  })

  it("maps session errors with a fallback message", () => {
    expect(sessionStreamEvents(envelope("session.error", { message: "boom" }))).toEqual([
      { type: "failed", message: "boom" }
    ])
    expect(sessionStreamEvents(envelope("session.error", {}))).toEqual([
      { type: "failed", message: "The server reported an error." }
    ])
  })

  it("ignores unrelated kinds", () => {
    expect(sessionStreamEvents(envelope("terminal.output", { data: "x" }))).toEqual([])
    expect(sessionStreamEvents(envelope("update.changed", {}))).toEqual([])
  })
})
