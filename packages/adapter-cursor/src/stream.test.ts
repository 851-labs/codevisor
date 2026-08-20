import type * as acp from "@agentclientprotocol/sdk"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { describe, expect, it } from "vitest"
import { CursorStreamNormalizer } from "./stream.js"

const notification = (
  update: Readonly<Record<string, unknown>>,
  sessionId = "session-1"
): acp.SessionNotification => ({ sessionId, update }) as unknown as acp.SessionNotification

const payload = (event: RuntimeEvent): Record<string, unknown> =>
  event.payload as Record<string, unknown>

describe("Cursor stream normalizer", () => {
  it("coalesces text deltas, demotes tool preambles, and finalizes only the last span", () => {
    const normalizer = new CursorStreamNormalizer()
    normalizer.startTurn("session-1")

    const first = normalizer.mapSessionNotification(
      notification({
        content: { text: "I’ll inspect ", type: "text" },
        sessionUpdate: "agent_message_chunk"
      })
    )
    const second = normalizer.mapSessionNotification(
      notification({
        content: { text: "the files.", type: "text" },
        sessionUpdate: "agent_message_chunk"
      })
    )
    expect(payload(first[0]!)).toMatchObject({ messageId: "cursor:session-1:0:0" })
    expect(payload(second[0]!)).toMatchObject({ messageId: "cursor:session-1:0:0" })

    const tool = normalizer.mapSessionNotification(
      notification({
        kind: "read",
        sessionUpdate: "tool_call",
        status: "pending",
        title: "Read files",
        toolCallId: "tool-1"
      })
    )
    expect(tool.map(payload)).toEqual([
      expect.objectContaining({
        messageId: "cursor:session-1:0:0",
        phase: "commentary"
      }),
      expect.objectContaining({ sessionUpdate: "tool_call", toolCallId: "tool-1" })
    ])

    const thought = normalizer.mapSessionNotification(
      notification({
        content: { text: "Checking the result", type: "text" },
        sessionUpdate: "agent_thought_chunk"
      })
    )
    const answer = normalizer.mapSessionNotification(
      notification({
        content: { text: "This repository is a compiler.", type: "text" },
        sessionUpdate: "agent_message_chunk"
      })
    )
    expect(payload(thought[0]!)).toMatchObject({ messageId: "cursor:session-1:0:1" })
    expect(payload(answer[0]!)).toMatchObject({ messageId: "cursor:session-1:0:1" })
    expect(normalizer.completeTurn("session-1").map(payload)).toEqual([
      expect.objectContaining({
        messageId: "cursor:session-1:0:1",
        phase: "final"
      })
    ])
  })

  it("uses replayed user messages as deterministic historical turn boundaries", () => {
    const normalizer = new CursorStreamNormalizer()
    normalizer.mapSessionNotification(
      notification({
        content: { text: "First question", type: "text" },
        sessionUpdate: "user_message_chunk"
      })
    )
    const first = normalizer.mapSessionNotification(
      notification({
        content: { text: "First answer", type: "text" },
        sessionUpdate: "agent_message_chunk"
      })
    )
    const nextUser = normalizer.mapSessionNotification(
      notification({
        content: { text: "Second question", type: "text" },
        sessionUpdate: "user_message_chunk"
      })
    )
    const second = normalizer.mapSessionNotification(
      notification({
        content: { text: "Second answer", type: "text" },
        sessionUpdate: "agent_message_chunk"
      })
    )

    expect(payload(first[0]!)).toMatchObject({ messageId: "cursor:session-1:0:0" })
    expect(nextUser.map(payload)).toEqual([
      expect.objectContaining({ messageId: "cursor:session-1:0:0", phase: "final" }),
      expect.objectContaining({ sessionUpdate: "user_message_chunk" })
    ])
    expect(payload(second[0]!)).toMatchObject({ messageId: "cursor:session-1:1:0" })
  })

  it("preserves future provider message ids and drops finalization after cancellation", () => {
    const normalizer = new CursorStreamNormalizer()
    normalizer.startTurn("session-1")
    const event = normalizer.mapSessionNotification(
      notification({
        content: { text: "Hello", type: "text" },
        messageId: "cursor-native-message",
        sessionUpdate: "agent_message_chunk"
      })
    )
    expect(payload(event[0]!)).toMatchObject({ messageId: "cursor-native-message" })
    normalizer.cancelTurn("session-1")
    expect(normalizer.completeTurn("session-1")).toEqual([])
  })

  it("suppresses live prompt echoes and extracts a split terminal error", () => {
    const normalizer = new CursorStreamNormalizer()
    normalizer.startPrompt("session-1")

    expect(
      normalizer.mapSessionNotification(
        notification({
          content: { text: "what does this repo do", type: "text" },
          sessionUpdate: "user_message_chunk"
        })
      )
    ).toEqual([])
    expect(
      normalizer.mapSessionNotification(
        notification({
          content: { text: "\n\nError: Retriable", type: "text" },
          sessionUpdate: "agent_message_chunk"
        })
      )
    ).toEqual([])
    expect(
      normalizer.mapSessionNotification(
        notification({
          content: { text: "Error: [unavailable] Error", type: "text" },
          sessionUpdate: "agent_message_chunk"
        })
      )
    ).toEqual([])

    expect(normalizer.settlePromptLeg("session-1")).toEqual({
      events: [],
      terminalError: {
        kind: "retriable",
        message: "Cursor is temporarily unavailable.",
        rawDetail: "[unavailable] Error",
        retryable: true
      }
    })
    expect(normalizer.completeTurn("session-1")).toEqual([])
  })

  it("keeps a terminal error buffered across trailing metadata", () => {
    const normalizer = new CursorStreamNormalizer()
    normalizer.startPrompt("session-1")
    expect(
      normalizer.mapSessionNotification(
        notification({
          content: { text: "Error: RetriableError: [unavailable] Error", type: "text" },
          sessionUpdate: "agent_message_chunk"
        })
      )
    ).toEqual([])

    const usage = normalizer.mapSessionNotification(
      notification({
        sessionUpdate: "usage_update",
        totalTokens: 42
      })
    )
    expect(usage.map(payload)).toEqual([
      expect.objectContaining({ sessionUpdate: "usage_update", totalTokens: 42 })
    ])
    expect(normalizer.settlePromptLeg("session-1").terminalError).toMatchObject({
      kind: "retriable",
      retryable: true
    })
  })

  it("flushes a false-positive error prefix as ordinary response text", () => {
    const normalizer = new CursorStreamNormalizer()
    normalizer.startTurn("session-1")
    expect(
      normalizer.mapSessionNotification(
        notification({
          content: { text: "Error: Retri", type: "text" },
          sessionUpdate: "agent_message_chunk"
        })
      )
    ).toEqual([])

    const flushed = normalizer.mapSessionNotification(
      notification({
        content: { text: "es are documented here.", type: "text" },
        sessionUpdate: "agent_message_chunk"
      })
    )
    expect(flushed.map(payload)).toEqual([
      expect.objectContaining({
        content: { text: "Error: Retries are documented here.", type: "text" },
        messageId: "cursor:session-1:0:0"
      })
    ])
    expect(normalizer.settlePromptLeg("session-1")).toEqual({ events: [] })
  })
})
