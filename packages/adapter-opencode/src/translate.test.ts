import { describe, expect, it } from "vitest"

import { event } from "./test-support.js"
import {
  decodeEvent,
  foldEvent,
  initialFoldState,
  stopReason,
  turnFailure,
  type FoldOutput,
  type FoldState
} from "./translate.js"

const ROOT = "ses_root"

const started: FoldState = {
  ...initialFoldState(ROOT, "/work"),
  turn: { inputID: "msg_1", started: true, pending: new Set() }
}

const foldAll = (state: FoldState, events: ReadonlyArray<ReturnType<typeof event>>) => {
  const outputs: Array<FoldOutput> = []
  let current = state
  for (const next of events) {
    const folded = foldEvent(current, next)
    current = folded.state
    outputs.push(...folded.outputs)
  }
  return { state: current, outputs }
}

const updates = (outputs: ReadonlyArray<FoldOutput>) =>
  outputs.flatMap((output) => (output._tag === "update" ? [output.update] : []))

const tool = (name: string, input: Record<string, unknown>, extra: Record<string, unknown> = {}) =>
  foldAll(started, [
    event("session.tool.input.started", { sessionID: ROOT, id: name, name }),
    event("session.tool.called", { sessionID: ROOT, id: name, input }),
    event("session.tool.success", { sessionID: ROOT, id: name, ...extra })
  ]).outputs

const running = (name: string, input: Record<string, unknown>) => updates(tool(name, input))[1]

const readOutput = (text: string) =>
  updates(tool("read", { path: "a" }, { content: [{ type: "text", text }] }))[2]?.content

const tokens = (input: number) => ({ input, output: 1, reasoning: 0, cache: { read: 0, write: 2 } })

describe("OpenCode event fold", () => {
  it("projects a tool call through its whole lifecycle in ACP's shape", () => {
    const { state, outputs } = foldAll(started, [
      event("session.tool.input.started", { sessionID: ROOT, id: "call_1", name: "bash" }),
      event("session.tool.called", { sessionID: ROOT, id: "call_1", input: { command: "ls -la" } }),
      event("session.tool.progress", {
        sessionID: ROOT,
        id: "call_1",
        metadata: { shellID: "sh_1" }
      }),
      event("session.tool.success", {
        sessionID: ROOT,
        id: "call_1",
        content: [
          { type: "text", text: "README.md\n" },
          { type: "file", uri: "data:image/png;base64,AAAA" },
          { type: "file", uri: "file:///ignored.bin" }
        ],
        metadata: { exit: 0 }
      })
    ])
    expect(updates(outputs)).toEqual([
      {
        sessionUpdate: "tool_call",
        toolCallId: "call_1",
        name: "bash",
        title: "bash",
        kind: "execute",
        status: "pending",
        locations: [{ path: "/work" }],
        rawInput: { cwd: "/work" }
      },
      expect.objectContaining({
        status: "in_progress",
        title: "ls -la",
        rawInput: { command: "ls -la", cwd: "/work" }
      }),
      expect.objectContaining({ status: "in_progress", title: "ls -la" }),
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "call_1",
        status: "completed",
        locations: [{ path: "/work" }],
        content: [
          { type: "content", content: { type: "text", text: "README.md\n" } },
          { type: "content", content: { type: "image", mimeType: "image/png", data: "AAAA" } }
        ],
        rawOutput: { metadata: { exit: 0 } }
      }
    ])
    expect(outputs.at(-1)).toMatchObject({ metadata: { exit: 0 } })
    expect(state.tools.size).toBe(0)
  })

  it("names tool kinds, locations and read output the way OpenCode's ACP bridge does", () => {
    expect(running("read", { filePath: "src/a.ts" })).toMatchObject({
      kind: "read",
      locations: [{ path: "/work/src/a.ts" }]
    })
    expect(running("grep", { pattern: "x", path: "/abs" })).toMatchObject({
      kind: "search",
      locations: [{ path: "/abs" }]
    })
    expect(running("webfetch", { url: "https://x" })).toMatchObject({
      kind: "fetch",
      locations: []
    })
    expect(running("task", {})).toMatchObject({ kind: "think" })
    expect(running("external_directory", { filepath: "/tmp" })).toMatchObject({
      kind: "other",
      locations: [{ path: "/tmp" }]
    })
    expect(
      running("apply_patch", {
        patchText:
          "*** Begin Patch\n*** Update File: a.ts\n*** Move to: b.ts\n*** Add File: c.ts\n*** End Patch"
      })
    ).toMatchObject({
      kind: "edit",
      locations: [{ path: "/work/a.ts" }, { path: "/work/b.ts" }, { path: "/work/c.ts" }]
    })
    expect(readOutput(JSON.stringify({ type: "text-page", content: "line one" }))).toEqual([
      { type: "content", content: { type: "text", text: "line one" } }
    ])
    expect(readOutput(JSON.stringify({ entries: ["a.ts", { path: "b/" }, 3] }))).toEqual([
      { type: "content", content: { type: "text", text: "a.ts\nb/" } }
    ])
    expect(readOutput("{not json")).toEqual([
      { type: "content", content: { type: "text", text: "{not json" } }
    ])
  })

  it("reports failed tools with their error and untracked tools under a generic name", () => {
    const { outputs } = foldAll(started, [
      event("session.tool.failed", {
        sessionID: ROOT,
        id: "call_9",
        error: { type: "tool", message: "No such file" }
      }),
      event("session.tool.progress", { sessionID: ROOT, id: "call_unknown", metadata: {} })
    ])
    expect(updates(outputs)).toEqual([
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "call_9",
        status: "failed",
        kind: "other",
        title: "tool",
        locations: [],
        rawInput: {},
        content: [{ type: "content", content: { type: "text", text: "No such file" } }],
        rawOutput: { metadata: {}, error: "No such file" }
      }
    ])
  })

  it("streams text, reasoning, retries and renames for the root session", () => {
    const { outputs } = foldAll(started, [
      event("session.reasoning.delta", {
        sessionID: ROOT,
        assistantMessageID: "msg_a",
        ordinal: 2,
        delta: "hmm"
      }),
      event("session.retry.scheduled", {
        sessionID: ROOT,
        attempt: 2,
        at: 0,
        error: { type: "rate" }
      }),
      event("session.renamed", { sessionID: ROOT, title: "Fix the build" }),
      event("session.text.delta", {
        sessionID: "ses_other",
        assistantMessageID: "msg_b",
        delta: "not ours"
      })
    ])
    expect(updates(outputs)).toEqual([
      {
        sessionUpdate: "agent_thought_chunk",
        messageId: "msg_a:reasoning:2",
        content: { type: "text", text: "hmm" }
      },
      {
        sessionUpdate: "session_info_update",
        _meta: {
          "opencode/retry": {
            attempt: 2,
            nextRetryAt: "1970-01-01T00:00:00.000Z",
            error: { type: "rate" }
          }
        }
      },
      { sessionUpdate: "session_info_update", title: "Fix the build" }
    ])
  })

  it("routes subagent sessions, their nested children and their tools as child updates", () => {
    const { outputs } = foldAll(started, [
      event("session.created", { sessionID: "ses_child", parentID: ROOT, title: "Explore" }),
      event("session.created", { sessionID: "ses_grand", parentID: "ses_child" }),
      event("session.created", { sessionID: "ses_stranger", parentID: "ses_other" }),
      event("session.execution.started", { sessionID: "ses_child" }),
      event("session.tool.input.started", { sessionID: "ses_child", id: "call_1", name: "glob" }),
      event("session.execution.failed", {
        sessionID: "ses_grand",
        error: { type: "x", message: "y" }
      })
    ])
    expect(outputs.map((output) => (output._tag === "child" ? output.params : output))).toEqual([
      {
        rootSessionId: ROOT,
        childSessionId: "ses_child",
        parentSessionId: ROOT,
        depth: 1,
        title: "Explore",
        type: "status",
        status: "created"
      },
      {
        rootSessionId: ROOT,
        childSessionId: "ses_grand",
        parentSessionId: "ses_child",
        depth: 2,
        type: "status",
        status: "created"
      },
      expect.objectContaining({ childSessionId: "ses_child", type: "status", status: "running" }),
      expect.objectContaining({
        childSessionId: "ses_child",
        type: "update",
        update: expect.objectContaining({
          sessionUpdate: "tool_call",
          toolCallId: "ses_child:call_1",
          title: "Explore: glob",
          _meta: {
            "opencode/child-session": {
              id: "ses_child",
              parentID: ROOT,
              depth: 1,
              title: "Explore"
            }
          }
        })
      }),
      expect.objectContaining({ childSessionId: "ses_grand", type: "status", status: "failed" })
    ])
  })

  it("holds root output until the turn's prompt is delivered and tracks pending steers", () => {
    const waiting: FoldState = {
      ...initialFoldState(ROOT, "/work"),
      turn: { inputID: "msg_1", started: false, pending: new Set(["msg_1", "msg_2"]) }
    }
    const before = foldAll(waiting, [
      event("session.text.delta", { sessionID: ROOT, delta: "old" }),
      event("session.execution.succeeded", { sessionID: ROOT }),
      event("session.inbox.delivered", { sessionID: ROOT, inboxID: "msg_unknown" })
    ])
    expect(before.outputs).toEqual([])
    const after = foldAll(before.state, [
      event("session.inbox.delivered", { sessionID: ROOT, inboxID: "msg_1" }),
      event("session.inbox.delivered", { sessionID: ROOT, inboxID: "msg_2" }),
      event("session.execution.succeeded", { sessionID: ROOT })
    ])
    expect(after.state.turn).toMatchObject({ started: true, pending: new Set() })
    expect(after.outputs).toEqual([{ _tag: "terminal", terminal: "succeeded" }])
    expect(
      foldEvent(
        initialFoldState(ROOT, "/w"),
        event("session.inbox.delivered", { sessionID: ROOT, inboxID: "x" })
      ).outputs
    ).toEqual([])
  })

  it("accumulates step usage and records failures for the turn result", () => {
    const { state, outputs } = foldAll(started, [
      event("session.step.ended", { sessionID: ROOT, finish: "tool-calls", tokens: tokens(5) }),
      event("session.step.failed", {
        sessionID: ROOT,
        tokens: tokens(7),
        error: { type: "provider.api", message: "boom" }
      }),
      event("session.step.started", { sessionID: ROOT }),
      event("session.step.ended", { sessionID: ROOT, finish: "length", tokens: { input: 1 } }),
      event("session.execution.failed", {
        sessionID: ROOT,
        error: { type: "provider.api", message: "final" }
      })
    ])
    const turn = state.turn!
    expect(turn.usage).toEqual({
      turn: { input: 13, output: 2, reasoning: 0, cache: { read: 0, write: 4 } },
      last: { input: 1, output: 0, reasoning: 0, cache: { read: 0, write: 0 } }
    })
    expect(turnFailure(turn)).toEqual({ type: "provider.api", message: "final" })
    expect(outputs).toEqual([{ _tag: "terminal", terminal: "failed" }])
    expect(stopReason(turn, "succeeded")).toBe("max_tokens")
    expect(stopReason(turn, "interrupted")).toBe("cancelled")
    expect(
      stopReason({ ...turn, executionError: { type: "aborted", message: "" } }, "failed")
    ).toBe("cancelled")
    expect(
      turnFailure({ ...turn, executionError: { type: "aborted", message: "" } })
    ).toBeUndefined()
    expect(stopReason({ ...turn, finish: "content-filter" }, "succeeded")).toBe("refusal")
  })

  it("surfaces permissions and forms from the session tree and ignores everything else", () => {
    const withChild = foldAll(started, [
      event("session.created", { sessionID: "ses_child", parentID: ROOT }),
      event("session.tool.input.started", { sessionID: "ses_child", id: "call_1", name: "edit" })
    ]).state
    const { outputs } = foldAll(withChild, [
      event("permission.asked", {
        id: "per_1",
        sessionID: "ses_child",
        action: "edit",
        source: { id: "call_1" }
      }),
      event("permission.asked", { id: "per_2", sessionID: "ses_other", action: "edit" }),
      event("permission.replied", { sessionID: ROOT, requestID: "per_1", reply: "once" }),
      event("form.created", { form: { id: "frm_1", sessionID: ROOT } }),
      event("form.created", { form: { id: "frm_2", sessionID: "ses_other" } }),
      event("server.heartbeat", {})
    ])
    expect(outputs).toEqual([
      {
        _tag: "permission",
        request: { id: "per_1", sessionID: "ses_child", action: "edit", source: { id: "call_1" } },
        tool: { sessionID: "ses_child", id: "call_1", name: "edit", input: {}, metadata: {} },
        child: { id: "ses_child", parentID: ROOT, depth: 1 }
      },
      { _tag: "permissionSettled", id: "per_1" },
      { _tag: "form", form: { id: "frm_1", sessionID: ROOT } }
    ])
    expect(decodeEvent({ type: "x" })).toBeUndefined()
    expect(decodeEvent({ type: "x", data: {} })).toEqual({ type: "x", data: {} })
  })
})
