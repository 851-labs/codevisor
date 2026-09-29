import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { describe, expect, it } from "vitest"

import {
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  run,
  streamEvent,
  systemMessage
} from "./test-support.js"

/// A message sent to an existing subagent (`SendMessage`) restarts its task
/// under the follow-up's own tool call, while its thread keeps streaming
/// under the call that spawned it. Both calls carry the agent's task id, so
/// clients tie them together from stored transcript data alone.
describe("Claude subagent follow-ups", () => {
  it("marks a message to an existing agent as a follow-up, not a new agent", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    fake.push(initMessage())
    await createPromise

    const startTool = (id: string, name: string, index: number) =>
      streamEvent({
        content_block: { id, name, type: "tool_use" },
        index,
        type: "content_block_start"
      })
    const taskStarted = (toolUseId: string) =>
      systemMessage("task_started", {
        description: "Analyze commits",
        subagent_type: "general-purpose",
        task_id: "agent-1",
        tool_use_id: toolUseId
      })
    fake.push(startTool("toolu-spawn", "Agent", 0))
    fake.push(taskStarted("toolu-spawn"))
    fake.push(startTool("toolu-follow-up", "SendMessage", 1))
    fake.push(taskStarted("toolu-follow-up"))
    await fake.drain()

    const updates = events
      .map((event) => event.payload as Record<string, unknown>)
      .filter(
        (payload) => payload.sessionUpdate === "tool_call_update" && payload.title !== undefined
      )
    const meta = { codevisorSubagent: { taskId: "agent-1" } }
    expect(updates.find((payload) => payload.toolCallId === "toolu-spawn")).toEqual({
      _meta: meta,
      kind: "agent",
      sessionUpdate: "tool_call_update",
      title: "Agent: Analyze commits",
      toolCallId: "toolu-spawn"
    })
    expect(updates.find((payload) => payload.toolCallId === "toolu-follow-up")).toEqual({
      _meta: meta,
      sessionUpdate: "tool_call_update",
      title: "Messaged agent: Analyze commits",
      toolCallId: "toolu-follow-up"
    })
  })
})
