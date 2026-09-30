import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { describe, expect, it } from "vitest"

import {
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  resultMessage,
  run
} from "./test-support.js"

// The Agent tool's result for spawn "agent-1": the framed text the CLI hands
// the parent, plus the SDK's structured output.
const agentResult = (toolUseResult: Record<string, unknown>): SDKMessage =>
  ({
    message: {
      content: [
        {
          content: [{ text: "[Subagent hand-back] framed report", type: "text" }],
          tool_use_id: "agent-1",
          type: "tool_result"
        }
      ],
      role: "user"
    },
    parent_tool_use_id: null,
    session_id: "sdk-session-1",
    tool_use_result: toolUseResult,
    type: "user"
  }) as never

// The prose streamed into agent-1's thread over one turn of `messages`.
const subagentProse = async (messages: Array<SDKMessage>): Promise<Array<unknown>> => {
  const fake = new FakeQuery()
  const provider = makeProvider(fake)
  const events: Array<RuntimeEvent> = []
  const emit = async (event: RuntimeEvent): Promise<void> => {
    events.push(event)
  }
  const createPromise = run(provider.createSession(definition, "/tmp", emit))
  fake.push(initMessage())
  const created = await createPromise
  const promptPromise = run(created.handle.prompt("spawn an agent"))
  await fake.nextPrompt()
  for (const message of messages) fake.push(message)
  fake.push(resultMessage())
  await promptPromise
  return events
    .map((event) => event.payload as Record<string, unknown>)
    .filter(
      (payload) =>
        payload.sessionUpdate === "agent_message_chunk" && payload.parentToolCallId === "agent-1"
    )
    .map((payload) => (payload.content as { text: string }).text)
}

describe("a subagent's hand-back", () => {
  it("ends the subagent's thread with its final report", async () => {
    const prose = await subagentProse([
      agentResult({
        agentId: "a1",
        content: [{ text: "Here is the haiku.", type: "text" }],
        status: "completed"
      })
    ])

    expect(prose).toEqual(["Here is the haiku."])
  })

  it("is not repeated when the subagent's thread already ends with it", async () => {
    const prose = await subagentProse([
      {
        message: {
          content: [{ text: "Here is the haiku.", type: "text" }],
          id: "msg-sub-final",
          role: "assistant"
        },
        parent_tool_use_id: "agent-1",
        session_id: "sdk-session-1",
        type: "assistant"
      } as never,
      agentResult({
        agentId: "a1",
        content: [{ text: "Here is the haiku.", type: "text" }],
        status: "completed"
      })
    ])

    expect(prose).toEqual(["Here is the haiku."])
  })

  it("is not taken from a background launch's acknowledgement", async () => {
    const prose = await subagentProse([
      agentResult({
        agentId: "a1",
        description: "Slow haiku",
        outputFile: "/tmp/a1.output",
        prompt: "Write a haiku",
        status: "async_launched"
      })
    ])

    expect(prose).toEqual([])
  })
})
