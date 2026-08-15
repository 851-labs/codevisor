import { describe, expect, it } from "vitest"
import { run, setup, UNIFIED_DIFF } from "./test-support.js"

describe("CodexProvider", () => {
  it("preserves MCP arguments and results for semantic tool-call presentation", async () => {
    const { client, events } = await setup()
    client.emit("item/started", {
      item: {
        arguments: { server: "server-id", tool: "find_organizations" },
        id: "mcp-1",
        server: "codevisor",
        status: "inProgress",
        tool: "execute",
        type: "mcpToolCall"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: {
        arguments: { server: "server-id", tool: "find_organizations" },
        id: "mcp-1",
        result: { content: [{ text: "ok", type: "text" }] },
        server: "codevisor",
        status: "completed",
        tool: "execute",
        type: "mcpToolCall"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads).toContainEqual(
      expect.objectContaining({
        rawInput: { server: "server-id", tool: "find_organizations" },
        sessionUpdate: "tool_call",
        title: "codevisor.execute",
        toolCallId: "mcp-1"
      })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({
        rawOutput: { content: [{ text: "ok", type: "text" }] },
        sessionUpdate: "tool_call_update",
        status: "completed",
        toolCallId: "mcp-1"
      })
    )
  })

  it("maps a full turn: lifecycle, streamed patch stats, command items", async () => {
    const { client, created, events } = await setup()
    const promptPromise = run(created!.handle.prompt("change the runner"))
    await Promise.resolve()

    client.emit("turn/started", {
      threadId: "thread-new",
      turn: { id: "turn-1", status: "inProgress" }
    })
    client.emit("item/started", {
      item: {
        command: "rg runner",
        id: "item-cmd",
        status: "inProgress",
        type: "commandExecution"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: {
        aggregatedOutput: "release.yml",
        command: "rg runner",
        exitCode: 0,
        id: "item-cmd",
        status: "completed",
        type: "commandExecution"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/started", {
      item: { changes: [], id: "item-edit", status: "inProgress", type: "fileChange" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/fileChange/patchUpdated", {
      changes: [{ diff: UNIFIED_DIFF, kind: { type: "update" }, path: "release.yml" }],
      itemId: "item-edit",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: {
        changes: [{ diff: UNIFIED_DIFF, kind: { type: "update" }, path: "release.yml" }],
        id: "item-edit",
        status: "completed",
        type: "fileChange"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/agentMessage/delta", {
      delta: "Updated the runner.",
      itemId: "item-msg",
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
    expect(payloads[0]).toMatchObject({
      initiatedBy: "user",
      turnId: "turn-1",
      turnState: "started"
    })
    expect(payloads).toContainEqual(
      expect.objectContaining({
        sessionUpdate: "tool_call",
        toolCallId: "item-cmd",
        kind: "execute",
        status: "in_progress",
        title: "Ran rg runner"
      })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({
        sessionUpdate: "tool_call_update",
        toolCallId: "item-cmd",
        status: "completed",
        rawOutput: "release.yml"
      })
    )
    // The streamed patch carries realtime per-file stats.
    const streamed = payloads.find(
      (payload) =>
        payload.sessionUpdate === "tool_call_update" &&
        payload.toolCallId === "item-edit" &&
        payload.status === "in_progress"
    )
    expect(streamed?.diffStats).toEqual([{ added: 2, path: "release.yml", removed: 1 }])
    // Completion carries final stats plus a renderable diff block.
    const completedEdit = payloads.find(
      (payload) =>
        payload.sessionUpdate === "tool_call_update" &&
        payload.toolCallId === "item-edit" &&
        payload.status === "completed"
    )
    expect(completedEdit?.diffStats).toEqual([{ added: 2, path: "release.yml", removed: 1 }])
    expect(Array.isArray(completedEdit?.content)).toBe(true)
    expect(payloads).toContainEqual(
      expect.objectContaining({ sessionUpdate: "agent_message_chunk", messageId: "item-msg" })
    )
    expect(payloads.at(-1)).toMatchObject({
      stopReason: "end_turn",
      turnId: "turn-1",
      turnState: "ended"
    })
  })

  it("titles web searches with their query, re-titling on completion", async () => {
    const { client, created, events } = await setup()
    const promptPromise = run(created!.handle.prompt("look it up"))
    await Promise.resolve()

    client.emit("turn/started", {
      threadId: "thread-new",
      turn: { id: "turn-1", status: "inProgress" }
    })
    // The started item has no query yet — codex fills it in as the model
    // generates the call, so only completion carries the real query.
    client.emit("item/started", {
      item: { id: "item-ws", type: "webSearch" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: { id: "item-ws", query: "rust incremental build cache", type: "webSearch" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "turn-1", status: "completed" }
    })
    await promptPromise

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads).toContainEqual(
      expect.objectContaining({
        kind: "web_search",
        sessionUpdate: "tool_call",
        status: "in_progress",
        title: "Searching the web",
        toolCallId: "item-ws"
      })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({
        sessionUpdate: "tool_call_update",
        status: "completed",
        title: "Searched for rust incremental build cache",
        toolCallId: "item-ws"
      })
    )
  })

  it("carries agentMessage phase from item/started onto chunks and retro-tags completion-only phases", async () => {
    const { client, created, events } = await setup()
    const promptPromise = run(created!.handle.prompt("finality"))
    await Promise.resolve()

    client.emit("turn/started", {
      threadId: "thread-new",
      turn: { id: "turn-1", status: "inProgress" }
    })
    // Commentary preamble tagged at item/started: chunks carry the phase.
    client.emit("item/started", {
      item: { content: [], id: "item-pre", phase: "commentary", type: "agentMessage" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/agentMessage/delta", {
      delta: "Checking the workflow first.",
      itemId: "item-pre",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: { content: [], id: "item-pre", phase: "commentary", type: "agentMessage" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    // Final answer tagged at item/started: chunks stream as final from the start.
    client.emit("item/started", {
      item: { content: [], id: "item-final", phase: "final_answer", type: "agentMessage" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/agentMessage/delta", {
      delta: "All done.",
      itemId: "item-final",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: { content: [], id: "item-final", phase: "final_answer", type: "agentMessage" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    // Untagged at start, tagged only on completion: a zero-length chunk
    // retro-tags the already-streamed span.
    client.emit("item/started", {
      item: { content: [], id: "item-late", type: "agentMessage" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/agentMessage/delta", {
      delta: "Actually, one more thing…",
      itemId: "item-late",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: { content: [], id: "item-late", phase: "commentary", type: "agentMessage" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("turn/completed", {
      threadId: "thread-new",
      turn: { id: "turn-1", status: "completed" }
    })
    await promptPromise

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads).toContainEqual(
      expect.objectContaining({
        content: { text: "Checking the workflow first.", type: "text" },
        messageId: "item-pre",
        phase: "commentary",
        sessionUpdate: "agent_message_chunk"
      })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({
        content: { text: "All done.", type: "text" },
        messageId: "item-final",
        phase: "final",
        sessionUpdate: "agent_message_chunk"
      })
    )
    // The untagged stream carried no phase…
    const lateChunks = payloads.filter(
      (payload) =>
        payload.sessionUpdate === "agent_message_chunk" && payload.messageId === "item-late"
    )
    expect(lateChunks[0]).not.toHaveProperty("phase")
    // …and completion retro-tagged it with a zero-length correction chunk.
    expect(lateChunks.at(-1)).toMatchObject({
      content: { text: "", type: "text" },
      phase: "commentary"
    })
    // Matching phases at start and completion emit no redundant correction.
    const finalChunks = payloads.filter(
      (payload) =>
        payload.sessionUpdate === "agent_message_chunk" && payload.messageId === "item-final"
    )
    expect(finalChunks).toHaveLength(1)
  })

  it("counts add/delete changes from raw content, updates from unified diffs", async () => {
    const { client, events } = await setup()
    client.emit("item/fileChange/patchUpdated", {
      changes: [{ diff: "one\ntwo\nthree\n", kind: { type: "add" }, path: "new.txt" }],
      itemId: "item-add",
      threadId: "thread-new",
      turnId: "turn-1"
    })
    expect((events.at(-1)!.payload as Record<string, unknown>).diffStats).toEqual([
      { added: 3, path: "new.txt", removed: 0 }
    ])
    client.emit("item/completed", {
      item: {
        changes: [{ diff: "one\ntwo\nthree\n", kind: { type: "delete" }, path: "old.txt" }],
        id: "item-del",
        status: "completed",
        type: "fileChange"
      },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    const deleted = events.at(-1)?.payload as Record<string, unknown>
    expect(deleted.diffStats).toEqual([{ added: 0, path: "old.txt", removed: 3 }])
    expect(deleted.content).toEqual([
      { newText: "", oldText: "one\ntwo\nthree\n", path: "old.txt", type: "diff" }
    ])
  })

  it("renders completed plan items as plan documents, not tool calls", async () => {
    const { client, events } = await setup()
    client.emit("item/started", {
      item: { id: "plan-1", text: "", type: "plan" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    client.emit("item/completed", {
      item: { id: "plan-1", text: "# Proposed Plan\n\n- step one", type: "plan" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    // Empty plan text emits nothing.
    client.emit("item/completed", {
      item: { id: "plan-2", text: "", type: "plan" },
      threadId: "thread-new",
      turnId: "turn-1"
    })
    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads.filter((payload) => payload.sessionUpdate === "plan_document")).toEqual([
      { markdown: "# Proposed Plan\n\n- step one", sessionUpdate: "plan_document" }
    ])
    expect(
      payloads.filter(
        (payload) =>
          (payload.sessionUpdate === "tool_call" || payload.sessionUpdate === "tool_call_update") &&
          payload.toolCallId === "plan-1"
      )
    ).toEqual([])
  })
})
