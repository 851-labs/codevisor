import { describe, expect, it } from "vitest"

import { makePiEventMapper, piToolKind, piToolTitle } from "./events.js"

const update = (assistantMessageEvent: Record<string, unknown>) => ({
  type: "message_update",
  assistantMessageEvent
})
const assistant = (extra: Record<string, unknown> = {}) => ({
  role: "assistant",
  timestamp: 100,
  usage: { input: 10, cacheRead: 5, output: 3, reasoning: 1, totalTokens: 18 },
  stopReason: "stop",
  ...extra
})

describe("Pi event mapping", () => {
  it("streams text per block and thinking, with a usage update per response", () => {
    const mapper = makePiEventMapper(() => 272_000)
    const map = (event: Record<string, unknown>) => mapper.map(event)
    expect(map({ type: "message_start", message: { role: "user" } })).toEqual([])
    map({ type: "message_start", message: { role: "assistant", timestamp: 100 } })
    expect(map(update({ type: "text_delta", contentIndex: 0, delta: "I'll check." }))).toEqual([
      {
        kind: "session.output",
        payload: {
          sessionUpdate: "agent_message_chunk",
          messageId: "pi-100-1:0",
          content: { type: "text", text: "I'll check." }
        }
      }
    ])
    expect(map(update({ type: "thinking_delta", contentIndex: 1, delta: "Hmm" }))).toEqual([
      {
        kind: "session.output",
        payload: { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Hmm" } }
      }
    ])
    expect(map(update({ type: "text_delta", contentIndex: 0, delta: "" }))).toEqual([])
    expect(map(update({ type: "thinking_delta", delta: "" }))).toEqual([])
    expect(map(update({ type: "text_end", contentIndex: 0 }))).toEqual([])
    expect(map({ type: "message_end", message: assistant() })).toEqual([
      {
        kind: "session.updated",
        payload: {
          sessionUpdate: "usage_update",
          used: 18,
          size: 272_000,
          inputTokens: 10,
          cachedInputTokens: 5,
          outputTokens: 3,
          reasoningOutputTokens: 1,
          totalTokens: 18
        }
      }
    ])
    expect(mapper.outcome()).toEqual({ stopReason: "stop" })
    // A second response is a new message, and usage keeps a running total.
    map({ type: "message_start", message: { role: "assistant" } })
    expect(
      map(update({ type: "text_delta", contentIndex: 0, delta: "Done" }))[0]?.payload
    ).toMatchObject({
      messageId: "pi-0-2:0"
    })
    expect(map({ type: "message_end", message: { role: "toolResult" } })).toEqual([])
    const unknownWindow = makePiEventMapper(() => undefined)
    expect(
      unknownWindow.map({
        type: "message_end",
        message: { role: "assistant", usage: { totalTokens: 1 } }
      })[0]?.payload
    ).not.toHaveProperty("size")
    expect(
      map({ type: "message_end", message: assistant({ stopReason: undefined }) })
    ).toHaveLength(1)
    expect(mapper.outcome()).toEqual({ stopReason: "stop" })
  })

  it("remembers how the newest response ended until the next run", () => {
    const mapper = makePiEventMapper(() => undefined)
    mapper.map({
      type: "message_end",
      message: assistant({ stopReason: "error", errorMessage: "429 rate limited" })
    })
    expect(mapper.outcome()).toEqual({ stopReason: "error", errorMessage: "429 rate limited" })
    mapper.startRun()
    expect(mapper.outcome()).toBeUndefined()
  })

  it("follows a tool call from the model's first token to its result", () => {
    const mapper = makePiEventMapper(() => undefined)
    const id = "call_1|fc_1"
    expect(
      mapper.map(update({ type: "toolcall_start", contentIndex: 1, id, toolName: "bash" }))
    ).toEqual([
      {
        kind: "session.output",
        payload: {
          sessionUpdate: "tool_call",
          status: "pending",
          rawInput: {},
          toolCallId: id,
          kind: "execute",
          title: "bash"
        }
      }
    ])
    expect(
      mapper.map(
        update({
          type: "toolcall_end",
          toolCall: { id, name: "bash", arguments: { command: "wc -l notes.txt" } }
        })
      )[0]?.payload
    ).toMatchObject({
      sessionUpdate: "tool_call_update",
      title: "wc -l notes.txt",
      rawInput: { command: "wc -l notes.txt" }
    })
    expect(
      mapper.map({
        type: "tool_execution_start",
        toolCallId: id,
        toolName: "bash",
        args: { command: "wc -l notes.txt" }
      })[0]?.payload
    ).toMatchObject({ status: "in_progress" })
    expect(
      mapper.map({ type: "tool_execution_update", toolCallId: id, partialResult: { content: [] } })
    ).toEqual([])
    expect(
      mapper.map({
        type: "tool_execution_update",
        toolCallId: id,
        partialResult: { content: [{ type: "text", text: "2 notes" }, { type: "image" }] }
      })[0]?.payload
    ).toEqual({
      sessionUpdate: "tool_call_update",
      toolCallId: id,
      content: [{ type: "content", content: { type: "text", text: "2 notes" } }]
    })
    expect(
      mapper.map({
        type: "tool_execution_end",
        toolCallId: id,
        toolName: "bash",
        result: {
          content: [{ type: "text", text: "2 notes.txt\n" }],
          structuredContent: { output: "2 notes.txt\n", exit_code: 0 }
        },
        isError: false
      })[0]?.payload
    ).toEqual({
      sessionUpdate: "tool_call_update",
      toolCallId: id,
      status: "completed",
      content: [{ type: "content", content: { type: "text", text: "2 notes.txt\n" } }],
      exitCode: 0,
      rawOutput: { output: "2 notes.txt\n", exit_code: 0 }
    })
    // Calls Pi reports without an id are ignored.
    expect(mapper.map(update({ type: "toolcall_start", toolName: "bash" }))).toEqual([])
    expect(mapper.map(update({ type: "toolcall_end", toolCall: {} }))).toEqual([])
  })

  it("shows edits and writes as diffs, and failures without one", () => {
    const mapper = makePiEventMapper(() => undefined)
    const run = (
      name: string,
      args: Record<string, unknown>,
      result: Record<string, unknown>,
      isError = false
    ) => {
      mapper.map({ type: "tool_execution_start", toolCallId: name, toolName: name, args })
      return mapper.map({
        type: "tool_execution_end",
        toolCallId: name,
        toolName: name,
        result,
        isError
      })[0]?.payload
    }
    expect(
      run(
        "edit",
        { path: "notes.txt" },
        {
          content: [{ type: "text", text: "Replaced 1 block." }],
          details: {
            patch: "--- notes.txt\n+++ notes.txt\n@@ -1,2 +1,2 @@\n alpha\n-beta\n+gamma\n"
          }
        }
      )
    ).toMatchObject({
      status: "completed",
      content: [
        { type: "content", content: { type: "text", text: "Replaced 1 block." } },
        { type: "diff", path: "notes.txt", oldText: "alpha\nbeta\n", newText: "alpha\ngamma\n" }
      ],
      diffStats: [{ path: "notes.txt", added: 1, removed: 1 }],
      rawOutput: { patch: expect.any(String) }
    })
    expect(run("write", { path: "new.txt", content: "one\ntwo\n" }, { content: [] })).toMatchObject(
      {
        content: [{ type: "diff", path: "new.txt", oldText: null, newText: "one\ntwo\n" }],
        diffStats: [{ path: "new.txt", added: 2, removed: 0 }],
        rawOutput: null
      }
    )
    // No diff: a failed edit, an edit Pi reported no patch for, one with an empty patch, no path.
    expect(
      run("edit", { path: "a" }, { content: [{ type: "text", text: "no match" }] }, true)
    ).toMatchObject({
      status: "failed",
      content: [{ type: "content", content: { type: "text", text: "no match" } }]
    })
    expect(run("edit", { path: "a" }, { details: {} })).not.toHaveProperty("diffStats")
    expect(run("edit", { path: "a" }, { details: { patch: "--- a\n+++ a\n" } })).not.toHaveProperty(
      "diffStats"
    )
    expect(run("write", {}, {})).not.toHaveProperty("diffStats")
    // A result for a call Pi never announced still lands.
    expect(
      mapper.map({
        type: "tool_execution_end",
        toolCallId: "late",
        toolName: "read",
        result: {}
      })[0]?.payload
    ).toMatchObject({ toolCallId: "late", status: "completed", content: [] })
  })

  it("titles and kinds Pi's tools by what they act on", () => {
    expect(
      ["read", "bash", "edit", "write", "grep", "find", "ls", "mcp__x"].map(piToolKind)
    ).toEqual(["read", "execute", "edit", "edit", "search", "search", "search", "other"])
    expect(piToolTitle("grep", { pattern: "TODO" })).toBe("TODO")
    expect(piToolTitle("read", { path: "a.ts" })).toBe("a.ts")
    expect(piToolTitle("custom", { path: "" })).toBe("custom")
    const mapper = makePiEventMapper(() => undefined)
    expect(
      mapper.map({
        type: "tool_execution_start",
        toolCallId: "r",
        toolName: "read",
        args: { path: "a.ts" }
      })[0]?.payload
    ).toMatchObject({ locations: [{ path: "a.ts" }] })
  })

  it("passes on session names and compactions, and ignores the rest", () => {
    const mapper = makePiEventMapper(() => undefined)
    expect(mapper.map({ type: "session_info_changed", name: "Flights" })).toEqual([
      {
        kind: "session.updated",
        payload: { sessionUpdate: "session_info_update", title: "Flights" }
      }
    ])
    expect(mapper.map({ type: "session_info_changed" })).toEqual([])
    expect(mapper.map({ type: "compaction_start", reason: "threshold" })[0]?.payload).toEqual({
      sessionUpdate: "context_compaction",
      compactionId: "pi-1",
      status: "started"
    })
    expect(mapper.map({ type: "compaction_end" })[0]?.payload).toMatchObject({
      compactionId: "pi-1",
      status: "completed"
    })
    expect(mapper.map({ type: "queue_update" })).toEqual([])
  })
})
