import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { describe, expect, it } from "vitest"

import {
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  payloadOf,
  resultMessage,
  run,
  sdkMessage,
  streamEvent
} from "./test-support.js"

const replyMessage = (id: string, text: string, stopReason: string) =>
  sdkMessage({
    message: { content: [{ text, type: "text" }], id, role: "assistant", stop_reason: stopReason },
    parent_tool_use_id: null,
    session_id: "sdk-session-1",
    type: "assistant"
  })

describe("Claude message phases", () => {
  it("labels streamed preamble text commentary once a tool call starts, and an end_turn reply final", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("check the tests"))
    await fake.nextPrompt()
    fake.push(streamEvent({ message: { id: "msg-pre" }, type: "message_start" }))
    fake.push(
      streamEvent({
        delta: { text: "Let me check the tests.", type: "text_delta" },
        index: 0,
        type: "content_block_delta"
      })
    )
    fake.push(
      streamEvent({
        content_block: { id: "toolu-1", name: "Bash", type: "tool_use" },
        index: 1,
        type: "content_block_start"
      })
    )
    fake.push(
      streamEvent({
        content_block: { id: "toolu-2", name: "Bash", type: "tool_use" },
        index: 2,
        type: "content_block_start"
      })
    )
    fake.push(streamEvent({ delta: { stop_reason: "tool_use" }, type: "message_delta" }))
    fake.push(streamEvent({ message: { id: "msg-final" }, type: "message_start" }))
    fake.push(
      streamEvent({
        delta: { text: "Tests pass.", type: "text_delta" },
        index: 0,
        type: "content_block_delta"
      })
    )
    fake.push(streamEvent({ delta: { stop_reason: "end_turn" }, type: "message_delta" }))
    fake.push(resultMessage())
    await promptPromise

    const chunks = events
      .map(payloadOf)
      .filter((payload) => payload.sessionUpdate === "agent_message_chunk")
    expect(chunks[0]).toMatchObject({
      content: { text: "Let me check the tests.", type: "text" },
      messageId: "msg-pre"
    })
    expect(chunks[0]).not.toHaveProperty("phase")
    const corrections = chunks.filter((payload) => payload.phase === "commentary")
    expect(corrections).toHaveLength(1)
    expect(corrections[0]).toMatchObject({
      content: { text: "", type: "text" },
      messageId: "msg-pre"
    })
    const finalChunk = chunks.find((payload) => payload.messageId === "msg-final")
    expect(finalChunk).toMatchObject({ content: { text: "Tests pass.", type: "text" } })
    expect(finalChunk).not.toHaveProperty("phase")
    expect(chunks.filter((payload) => payload.phase === "final")).toEqual([
      {
        content: { text: "", type: "text" },
        messageId: "msg-final",
        phase: "final",
        sessionUpdate: "agent_message_chunk"
      }
    ])
  })

  it("labels unstreamed replies from their stop reason", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("check the tests"))
    await fake.nextPrompt()
    fake.push(replyMessage("msg-pre", "Let me check.", "tool_use"))
    fake.push(replyMessage("msg-final", "Tests pass.", "end_turn"))
    fake.push(resultMessage())
    await promptPromise

    const phases = events
      .map(payloadOf)
      .filter((payload) => payload.sessionUpdate === "agent_message_chunk")
      .map((payload) => [payload.messageId, payload.phase])
    expect(phases).toEqual([
      ["msg-pre", "commentary"],
      ["msg-final", "final"]
    ])
  })
})
