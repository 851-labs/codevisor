import type * as acp from "@agentclientprotocol/sdk"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { describe, expect, it } from "vitest"
import { GrokStreamNormalizer } from "./stream.js"

const notification = (
  update: Readonly<Record<string, unknown>>,
  promptId: string | null = "prompt-1"
): acp.SessionNotification =>
  ({
    ...(promptId === null ? {} : { _meta: { promptId } }),
    sessionId: "session-1",
    update
  }) as unknown as acp.SessionNotification

const payload = (event: RuntimeEvent): Record<string, unknown> =>
  event.payload as Record<string, unknown>

describe("Grok stream normalizer", () => {
  it("assigns response ids, demotes tool preamble, and asserts the final response", () => {
    const normalizer = new GrokStreamNormalizer()
    const preamble = normalizer.mapSessionNotification(
      notification({
        content: { text: "I’ll inspect it.", type: "text" },
        sessionUpdate: "agent_message_chunk"
      })
    )
    expect(payload(preamble[0]!)).toMatchObject({
      messageId: "grok:prompt-1:0",
      sessionUpdate: "agent_message_chunk"
    })

    const toolDelta = normalizer.mapExtensionNotification({
      sessionId: "session-1",
      update: { sessionUpdate: "tool_call_delta_chunk", tool_index: 0 }
    })
    expect(toolDelta.map(payload)).toEqual([
      expect.objectContaining({
        messageId: "grok:prompt-1:0",
        phase: "commentary",
        sessionUpdate: "agent_message_chunk"
      })
    ])

    normalizer.mapExtensionNotification({
      sessionId: "session-1",
      update: { sessionUpdate: "response_completed" }
    })
    const tool = normalizer.mapSessionNotification(
      notification({
        kind: "read",
        sessionUpdate: "tool_call",
        status: "in_progress",
        title: "Read files",
        toolCallId: "tool-1"
      })
    )
    expect(tool).toHaveLength(1)
    expect(payload(tool[0]!)).toMatchObject({ sessionUpdate: "tool_call", toolCallId: "tool-1" })

    const thought = normalizer.mapSessionNotification(
      notification({
        content: { text: "Checking the result", type: "text" },
        sessionUpdate: "agent_thought_chunk"
      })
    )
    const answer = normalizer.mapSessionNotification(
      notification({
        content: { text: "This repository builds a game.", type: "text" },
        sessionUpdate: "agent_message_chunk"
      })
    )
    expect(payload(thought[0]!)).toMatchObject({ messageId: "grok:prompt-1:1" })
    expect(payload(answer[0]!)).toMatchObject({ messageId: "grok:prompt-1:1" })

    expect(normalizer.completeTurn("session-1").map(payload)).toEqual([
      expect.objectContaining({
        messageId: "grok:prompt-1:1",
        phase: "final",
        sessionUpdate: "agent_message_chunk"
      })
    ])
  })

  it("uses canonical tool calls as the replay boundary without duplicate corrections", () => {
    const normalizer = new GrokStreamNormalizer()
    normalizer.mapSessionNotification(
      notification({
        content: { text: "Let me check.", type: "text" },
        sessionUpdate: "agent_message_chunk"
      })
    )
    const firstTool = normalizer.mapSessionNotification(
      notification({
        sessionUpdate: "tool_call",
        status: "in_progress",
        title: "Search",
        toolCallId: "tool-1"
      })
    )
    expect(firstTool.map(payload)).toEqual([
      expect.objectContaining({ messageId: "grok:prompt-1:0", phase: "commentary" }),
      expect.objectContaining({ sessionUpdate: "tool_call", toolCallId: "tool-1" })
    ])
    const update = normalizer.mapSessionNotification(
      notification({
        sessionUpdate: "tool_call_update",
        status: "completed",
        toolCallId: "tool-1"
      })
    )
    expect(update).toHaveLength(1)
  })

  it("preserves a real Messages-backend response id", () => {
    const normalizer = new GrokStreamNormalizer()
    normalizer.mapExtensionNotification({
      method: "x.ai/session_notification",
      params: {
        sessionId: "session-1",
        update: { message_id: "msg-real", sessionUpdate: "response_started" }
      }
    })
    const events = normalizer.mapSessionNotification(
      notification({
        content: { text: "Hello", type: "text" },
        sessionUpdate: "agent_message_chunk"
      })
    )
    expect(payload(events[0]!)).toMatchObject({ messageId: "msg-real" })
  })

  it("uses Grok's durable turn boundary to keep tool-free replay responses separate", () => {
    const normalizer = new GrokStreamNormalizer()
    const first = normalizer.mapSessionNotification(
      notification(
        {
          content: { text: "First answer", type: "text" },
          sessionUpdate: "agent_message_chunk"
        },
        null
      )
    )
    const firstCompleted = normalizer.mapExtensionNotification({
      sessionId: "session-1",
      update: {
        prompt_id: "historical-prompt-1",
        sessionUpdate: "turn_completed",
        stop_reason: "end_turn"
      }
    })
    const second = normalizer.mapSessionNotification(
      notification(
        {
          content: { text: "Second answer", type: "text" },
          sessionUpdate: "agent_message_chunk"
        },
        null
      )
    )
    const secondCompleted = normalizer.mapExtensionNotification({
      sessionId: "session-1",
      update: {
        prompt_id: "historical-prompt-2",
        sessionUpdate: "turn_completed",
        stop_reason: "end_turn"
      }
    })

    expect(payload(first[0]!)).toMatchObject({ messageId: "grok:session-1:0" })
    expect(firstCompleted.map(payload)).toEqual([
      expect.objectContaining({ messageId: "grok:session-1:0", phase: "final" })
    ])
    expect(payload(second[0]!)).toMatchObject({ messageId: "grok:session-1:1" })
    expect(secondCompleted.map(payload)).toEqual([
      expect.objectContaining({ messageId: "grok:session-1:1", phase: "final" })
    ])
  })

  it("falls back to replayed user messages as legacy turn boundaries", () => {
    const normalizer = new GrokStreamNormalizer()
    const first = normalizer.mapSessionNotification(
      notification(
        {
          content: { text: "First answer", type: "text" },
          sessionUpdate: "agent_message_chunk"
        },
        null
      )
    )
    const user = normalizer.mapSessionNotification(
      notification(
        {
          content: { text: "Next question", type: "text" },
          sessionUpdate: "user_message_chunk"
        },
        null
      )
    )
    const second = normalizer.mapSessionNotification(
      notification(
        {
          content: { text: "Second answer", type: "text" },
          sessionUpdate: "agent_message_chunk"
        },
        null
      )
    )

    expect(payload(first[0]!)).toMatchObject({ messageId: "grok:session-1:0" })
    expect(user.map(payload)).toEqual([
      expect.objectContaining({ messageId: "grok:session-1:0", phase: "final" }),
      expect.objectContaining({ sessionUpdate: "user_message_chunk" })
    ])
    expect(payload(second[0]!)).toMatchObject({ messageId: "grok:session-1:1" })
  })
})
