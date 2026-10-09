import { describe, expect, it } from "vitest"

import { run, setup } from "./test-support.js"

/// A multi-agent v2 activity item for the child agent at `/root/map_server_storage`.
const activity = (kind: string, id: string, turnId = "turn-1") => ({
  item: {
    agentPath: "/root/map_server_storage",
    agentThreadId: "thread-child",
    id,
    kind,
    type: "subAgentActivity"
  },
  threadId: "thread-new",
  turnId
})

describe("CodexProvider", () => {
  it("nests collab subagent threads under the spawn call and isolates their turn lifecycle", async () => {
    const { client, created, events } = await setup()
    const promptPromise = run(created!.handle.prompt("spin up subagents"))
    await Promise.resolve()

    client.emit("turn/started", {
      threadId: "thread-new",
      turn: { id: "turn-1", status: "inProgress" }
    })
    // spawnAgent opens the Agent tool call and registers the child thread.
    client.emit("item/started", {
      item: {
        agentsStates: {},
        id: "collab-spawn",
        prompt: "Explore the repo\nreport back",
        receiverThreadIds: ["thread-child"],
        senderThreadId: "thread-new",
        status: "inProgress",
        tool: "spawnAgent",
        type: "collabAgentToolCall"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: {
        agentsStates: {},
        id: "collab-spawn",
        receiverThreadIds: ["thread-child"],
        senderThreadId: "thread-new",
        status: "completed",
        tool: "spawnAgent",
        type: "collabAgentToolCall"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    // The child thread works: its turn lifecycle must NOT drive the session's.
    client.emit("turn/started", {
      threadId: "thread-child",
      turn: { id: "turn-child", status: "inProgress" }
    })
    client.emit("item/started", {
      item: { command: "ls", id: "child-cmd", status: "inProgress", type: "commandExecution" },
      threadId: "thread-child",
      turnId: "turn-child"
    })
    client.emit("item/agentMessage/delta", {
      delta: "child findings",
      itemId: "child-msg",
      threadId: "thread-child",
      turnId: "turn-child"
    })
    // Traffic from a thread we can't attribute is dropped, not mixed in.
    client.emit("item/agentMessage/delta", {
      delta: "stranger danger",
      itemId: "stray-msg",
      threadId: "thread-stranger",
      turnId: "turn-x"
    })
    client.emit("turn/completed", {
      threadId: "thread-child",
      turn: { id: "turn-child", status: "completed" }
    })
    // closeAgent settles the spawn row.
    client.emit("item/completed", {
      item: {
        agentsStates: {},
        id: "collab-close",
        receiverThreadIds: ["thread-child"],
        senderThreadId: "thread-new",
        status: "completed",
        tool: "closeAgent",
        type: "collabAgentToolCall"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "turn-1", status: "completed" }
    })

    const result = await promptPromise
    expect(result.stopReason).toBe("end_turn")

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads).toContainEqual(
      expect.objectContaining({
        kind: "agent",
        sessionUpdate: "tool_call",
        status: "in_progress",
        title: "Agent: Explore the repo",
        toolCallId: "collab-spawn"
      })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({
        parentToolCallId: "collab-spawn",
        sessionUpdate: "tool_call",
        toolCallId: "child-cmd"
      })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({
        messageId: "child-msg",
        parentToolCallId: "collab-spawn",
        sessionUpdate: "agent_message_chunk"
      })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({
        sessionUpdate: "tool_call_update",
        status: "completed",
        toolCallId: "collab-spawn"
      })
    )
    // No visible rows for the close call itself, no stray-thread leakage, and
    // exactly one turn end — the child's turn never ended the session's.
    expect(payloads.some((payload) => payload.toolCallId === "collab-close")).toBe(false)
    expect(JSON.stringify(payloads)).not.toContain("stranger danger")
    expect(payloads.filter((payload) => payload.turnState === "ended")).toHaveLength(1)
  })

  it("cuts long spawn prompts at a word boundary in the Agent title", async () => {
    const { client, events } = await setup()
    client.emit("item/started", {
      item: {
        agentsStates: {},
        id: "collab-long",
        prompt:
          "You are one of a couple sub-agents being spawned for a demonstration. Read-only task: inspect things.",
        receiverThreadIds: ["thread-child"],
        senderThreadId: "thread-new",
        status: "inProgress",
        tool: "spawnAgent",
        type: "collabAgentToolCall"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    await Promise.resolve()

    const spawn = events
      .map((event) => event.payload as Record<string, unknown>)
      .find((payload) => payload.toolCallId === "collab-long")
    expect(spawn?.title).toBe("Agent: You are one of a couple sub-agents being…")
  })

  it("shows multi-agent v2 subagents, named by task, with their thread nested and finish settling them", async () => {
    const { client, events } = await setup()
    // Each activity arrives as a started/completed pair.
    client.emit("item/started", activity("started", "call-spawn"))
    client.emit("item/completed", activity("started", "call-spawn"))
    client.emit("item/started", {
      item: { command: "ls", id: "child-cmd", status: "inProgress", type: "commandExecution" },
      threadId: "thread-child",
      turnId: "turn-child"
    })
    client.emit("item/completed", activity("completed", "subagent-completed-turn-child"))
    // Messaged again in the same turn: the same chip runs again.
    client.emit("item/started", activity("interacted", "call-message"))
    client.emit("item/completed", activity("interacted", "call-message"))
    await Promise.resolve()

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    const chips = payloads.filter(
      (payload) => payload.sessionUpdate === "tool_call" && payload.kind === "agent"
    )
    expect(chips).toEqual([
      expect.objectContaining({
        _meta: { codevisorSubagent: { taskId: "thread-child" } },
        rawInput: { agentPath: "/root/map_server_storage", description: "Map server storage" },
        status: "in_progress",
        title: "Agent: Map server storage",
        toolCallId: "call-spawn"
      })
    ])
    expect(payloads).toContainEqual(
      expect.objectContaining({
        parentToolCallId: "call-spawn",
        sessionUpdate: "tool_call",
        toolCallId: "child-cmd"
      })
    )
    expect(
      payloads
        .filter(
          (payload) =>
            payload.sessionUpdate === "tool_call_update" && payload.toolCallId === "call-spawn"
        )
        .map((payload) => payload.status)
    ).toEqual(["completed", "in_progress"])
  })

  it("gives a multi-agent v2 subagent messaged in a later turn a chip there that continues its history", async () => {
    const { client, events } = await setup()
    client.emit("item/started", activity("started", "call-spawn"))
    client.emit("item/completed", activity("completed", "subagent-completed-turn-child"))
    client.emit("item/started", activity("interacted", "call-followup", "turn-2"))
    client.emit("item/completed", activity("interacted", "call-followup", "turn-2"))
    client.emit("item/started", {
      item: { command: "rg", id: "child-cmd-2", status: "inProgress", type: "commandExecution" },
      threadId: "thread-child",
      turnId: "turn-child-2"
    })
    client.emit(
      "item/completed",
      activity("completed", "subagent-completed-turn-child-2", "turn-2")
    )
    await Promise.resolve()

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(
      payloads.filter(
        (payload) => payload.sessionUpdate === "tool_call" && payload.kind === "agent"
      )
    ).toEqual([
      expect.objectContaining({
        _meta: { codevisorSubagent: { taskId: "thread-child" } },
        toolCallId: "call-spawn"
      }),
      expect.objectContaining({
        _meta: { codevisorSubagent: { continues: true, taskId: "thread-child" } },
        status: "in_progress",
        title: "Agent: Map server storage",
        toolCallId: "call-followup"
      })
    ])
    // The new run nests under, and settles, the later chip.
    expect(payloads).toContainEqual(
      expect.objectContaining({ parentToolCallId: "call-followup", toolCallId: "child-cmd-2" })
    )
    expect(
      payloads
        .filter((payload) => payload.sessionUpdate === "tool_call_update")
        .map((payload) => [payload.toolCallId, payload.status])
    ).toEqual([
      ["call-spawn", "completed"],
      ["call-followup", "completed"]
    ])
  })

  it("cancels a spawned agent's row when its thread is interrupted", async () => {
    const { client, events } = await setup()
    client.emit("item/started", {
      item: {
        agentsStates: {},
        id: "collab-spawn",
        receiverThreadIds: ["thread-child"],
        senderThreadId: "thread-new",
        status: "inProgress",
        tool: "spawnAgent",
        type: "collabAgentToolCall"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: {
        agentPath: "root/child",
        agentThreadId: "thread-child",
        id: "activity-1",
        kind: "interrupted",
        type: "subAgentActivity"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    await Promise.resolve()

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads).toContainEqual(
      expect.objectContaining({
        sessionUpdate: "tool_call_update",
        status: "cancelled",
        toolCallId: "collab-spawn"
      })
    )
  })
})
