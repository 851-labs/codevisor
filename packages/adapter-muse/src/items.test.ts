import { describe, expect, it } from "vitest"

import { makeMuseItemMapper } from "./items.js"
import type { MuseItem } from "./protocol.js"

// Frames as Muse Code 1.4.7 sent them for "create hello.txt, edit it, run ls".
const write = (revision: number, status: string, extra: Partial<MuseItem> = {}): MuseItem => ({
  itemId: "w1",
  kind: "toolCall",
  revision,
  status,
  tool: "write_file",
  args: '{"content":"hi","path":"hello.txt"}',
  ...extra
})
const edit: MuseItem = {
  itemId: "e1",
  kind: "toolCall",
  revision: 3,
  status: "completed",
  tool: "edit_file",
  args: '{"find":"hi","path":"hello.txt","replace":"hello world"}',
  visibleOutput: "edited\nchanged lines: line 1\n",
  patchSummary: { files: 1, added: 1, removed: 1 }
}
const bash = (revision: number, status: string, visibleOutput?: string): MuseItem => ({
  itemId: "b1",
  kind: "toolCall",
  revision,
  status,
  tool: "bash",
  args: '{"command":"ls -la && cat hello.txt","description":"List files"}',
  ...(visibleOutput === undefined ? {} : { visibleOutput })
})

const payloads = (events: ReadonlyArray<{ payload: Record<string, unknown> }>) =>
  events.map((event) => event.payload)

describe("Muse item mapping", () => {
  it("streams a reply once: deltas as they come, then only what the completed item adds", () => {
    const mapper = makeMuseItemMapper()
    const message = {
      itemId: "m1",
      kind: "agentMessage",
      revision: 1,
      status: "inProgress",
      text: ""
    }
    expect(mapper.item(message, "started")).toEqual([])
    expect(payloads(mapper.delta("m1", "text", "Done — "))).toEqual([
      {
        sessionUpdate: "agent_message_chunk",
        messageId: "m1",
        content: { type: "text", text: "Done — " }
      }
    ])
    expect(mapper.delta("m1", "text", "")).toEqual([])
    const completed = {
      ...message,
      revision: 2,
      status: "completed",
      text: "Done — hello.txt says hi."
    }
    expect(payloads(mapper.item(completed, "completed"))).toEqual([
      {
        sessionUpdate: "agent_message_chunk",
        messageId: "m1",
        content: { type: "text", text: "hello.txt says hi." }
      }
    ])
    // A replayed or older revision changes nothing.
    expect(mapper.item(completed, "completed")).toEqual([])
    expect(mapper.item({ ...completed, revision: 3 }, "updated")).toEqual([])
  })

  it("shows a reply that never streamed, and never repeats a diverged one", () => {
    const mapper = makeMuseItemMapper()
    expect(
      payloads(
        mapper.item(
          { itemId: "m2", kind: "agentMessage", revision: 2, status: "completed", text: "Hi" },
          "completed"
        )
      )
    ).toEqual([
      {
        sessionUpdate: "agent_message_chunk",
        messageId: "m2",
        content: { type: "text", text: "Hi" }
      }
    ])
    mapper.delta("m3", "text", "abc")
    expect(
      mapper.item(
        { itemId: "m3", kind: "agentMessage", revision: 2, status: "completed", text: "xyz" },
        "completed"
      )
    ).toEqual([])
    expect(
      mapper.item(
        { itemId: "m4", kind: "agentMessage", revision: 1, status: "completed" },
        "completed"
      )
    ).toEqual([])
  })

  it("streams reasoning summaries, falling back to the settled text", () => {
    const mapper = makeMuseItemMapper()
    const reasoning = { itemId: "r1", kind: "reasoning", revision: 1, status: "inProgress" }
    expect(mapper.item(reasoning, "started")).toEqual([])
    expect(payloads(mapper.delta("r1", "summary.0", "Thinking"))).toEqual([
      { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Thinking" } }
    ])
    expect(
      mapper.item(
        { ...reasoning, revision: 2, status: "completed", summary: ["Thinking"] },
        "completed"
      )
    ).toEqual([])

    const unstreamed = makeMuseItemMapper()
    expect(
      payloads(
        unstreamed.item(
          {
            itemId: "r2",
            kind: "reasoning",
            revision: 2,
            status: "completed",
            summary: ["One", "Two"]
          },
          "completed"
        )
      )
    ).toEqual([
      { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "One\n\nTwo" } }
    ])
    expect(
      payloads(
        unstreamed.item(
          {
            itemId: "r3",
            kind: "reasoning",
            revision: 2,
            status: "completed",
            summary: [],
            text: "Raw"
          },
          "completed"
        )
      )
    ).toEqual([{ sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "Raw" } }])
    expect(
      unstreamed.item(
        { itemId: "r4", kind: "reasoning", revision: 2, status: "completed" },
        "completed"
      )
    ).toEqual([])
  })

  it("shows a file write as an edit with its diff and Muse's counts", () => {
    const mapper = makeMuseItemMapper()
    expect(payloads(mapper.item(write(1, "inProgress"), "started"))).toEqual([
      {
        sessionUpdate: "tool_call",
        status: "in_progress",
        toolCallId: "w1",
        kind: "edit",
        title: "hello.txt",
        rawInput: { content: "hi", path: "hello.txt" },
        locations: [{ path: "hello.txt" }]
      }
    ])
    const summary = { patchSummary: { files: 1, added: 1, removed: 0 } }
    expect(payloads(mapper.item(write(2, "inProgress", summary), "updated"))).toEqual([
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "w1",
        diffStats: [{ path: "hello.txt", added: 1, removed: 0 }]
      }
    ])
    const [completed] = payloads(
      mapper.item(
        write(3, "completed", { ...summary, visibleOutput: "wrote 2 bytes" }),
        "completed"
      )
    )
    expect(completed).toMatchObject({
      sessionUpdate: "tool_call_update",
      status: "completed",
      content: [
        { type: "content", content: { type: "text", text: "wrote 2 bytes" } },
        { type: "diff", path: "hello.txt", oldText: null, newText: "hi" }
      ],
      diffStats: [{ path: "hello.txt", added: 1, removed: 0 }],
      rawOutput: "wrote 2 bytes"
    })
  })

  it("opens and settles an edit first seen complete, with the find/replace as its diff", () => {
    const mapper = makeMuseItemMapper()
    const events = payloads(mapper.item(edit, "completed"))
    expect(events.map((event) => [event.sessionUpdate, event.status])).toEqual([
      ["tool_call", "completed"],
      ["tool_call_update", "completed"]
    ])
    expect(events[1]).toMatchObject({
      content: [
        { type: "content" },
        { type: "diff", path: "hello.txt", oldText: "hi", newText: "hello world" }
      ],
      diffStats: [{ path: "hello.txt", added: 1, removed: 1 }]
    })
    // Without Muse's counts the diff is counted from the texts.
    const { patchSummary: _, ...uncounted } = edit
    expect(
      payloads(makeMuseItemMapper().item({ ...uncounted, itemId: "e2" }, "completed"))[1]
    ).toMatchObject({ diffStats: [{ path: "hello.txt", added: 1, removed: 1 }] })
    expect(
      payloads(makeMuseItemMapper().item(write(3, "completed"), "completed"))[1]
    ).toMatchObject({ diffStats: [{ path: "hello.txt", added: 1, removed: 0 }] })
    // An edit shape without find/replace keeps Muse's counts, or nothing.
    const batch = { ...edit, itemId: "e3", args: '{"path":"a.ts","edits":[]}' }
    expect(payloads(makeMuseItemMapper().item(batch, "completed"))[1]).toMatchObject({
      diffStats: [{ path: "a.ts", added: 1, removed: 1 }]
    })
    const { patchSummary: __, ...bare } = batch
    expect(payloads(makeMuseItemMapper().item(bare, "completed"))[1]).not.toHaveProperty(
      "diffStats"
    )
  })

  it("streams shell output and settles with the envelope's output and exit code", () => {
    const mapper = makeMuseItemMapper()
    mapper.item(bash(1, "inProgress"), "started")
    mapper.delta("b1", "output", "total 8\n")
    expect(payloads(mapper.delta("b1", "output", "hello world"))).toEqual([
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "b1",
        content: [{ type: "content", content: { type: "text", text: "total 8\nhello world" } }]
      }
    ])
    // A still-running update without a diff adds nothing.
    expect(mapper.item(bash(2, "inProgress", "total 8\nhello world"), "updated")).toEqual([])
    const envelope = JSON.stringify({ command: "ls", exit_code: 0, output: "total 8\nhello world" })
    expect(payloads(mapper.item(bash(3, "completed", envelope), "completed"))[0]).toMatchObject({
      status: "completed",
      kind: "execute",
      title: "List files",
      exitCode: 0,
      content: [{ type: "content", content: { type: "text", text: "total 8\nhello world" } }]
    })
  })

  it("keeps only the newest tail of a long command's output", () => {
    const mapper = makeMuseItemMapper()
    mapper.item(bash(1, "inProgress"), "started")
    mapper.delta("b1", "output", "x".repeat(64 * 1024))
    const [update] = payloads(mapper.delta("b1", "output", "END"))
    const shown = (update!.content as Array<{ content: { text: string } }>)[0]!.content.text
    expect(shown).toHaveLength(64 * 1024)
    expect(shown.endsWith("END")).toBe(true)
  })

  it("reports failures with Muse's reason, and shell output that isn't an envelope as-is", () => {
    const mapper = makeMuseItemMapper()
    expect(
      payloads(
        mapper.item({ ...write(2, "failed"), failureReason: "permission denied" }, "completed")
      )[1]
    ).toMatchObject({
      status: "failed",
      content: [{ type: "content", content: { type: "text", text: "permission denied" } }]
    })
    expect(
      payloads(mapper.item({ ...bash(2, "rejected", "{broken"), itemId: "b2" }, "completed"))[1]
    ).toMatchObject({
      status: "failed",
      content: [{ type: "content", content: { type: "text", text: "{broken" } }]
    })
    expect(
      payloads(mapper.item({ ...bash(2, "completed", "plain"), itemId: "b3" }, "completed"))[1]
    ).toMatchObject({
      content: [{ type: "content", content: { type: "text", text: "plain" } }],
      rawOutput: "plain"
    })
    expect(
      payloads(
        mapper.item(
          { itemId: "b4", kind: "toolCall", revision: 2, status: "completed", tool: "bash" },
          "completed"
        )
      )[1]
    ).toMatchObject({ content: [], rawOutput: null })
  })

  it("names other tools by what they act on and falls back for odd arguments", () => {
    const mapper = makeMuseItemMapper()
    const call = (itemId: string, tool: string | undefined, args?: string) =>
      payloads(
        mapper.item(
          {
            itemId,
            kind: "toolCall",
            revision: 1,
            status: "inProgress",
            ...(tool === undefined ? {} : { tool }),
            ...(args === undefined ? {} : { args })
          },
          "started"
        )
      )[0]
    expect(call("t1", "search", '{"pattern":"TODO"}')).toMatchObject({
      kind: "search",
      title: "TODO"
    })
    expect(call("t2", "web_fetch", '{"url":"https://x.dev"}')).toMatchObject({
      kind: "fetch",
      title: "https://x.dev"
    })
    expect(call("t3", "web_search", '{"query":"muse"}')).toMatchObject({
      kind: "fetch",
      title: "muse"
    })
    expect(call("t4", "read_file", '{"path":"a.ts"}')).toMatchObject({
      kind: "read",
      title: "a.ts"
    })
    expect(call("t5", "add_memory", "{}")).toMatchObject({ kind: "edit", title: "add_memory" })
    expect(call("t6", "monitor", "not json")).toMatchObject({ kind: "execute", rawInput: {} })
    expect(call("t7", "cron_create", "[1]")).toMatchObject({ kind: "other", title: "cron_create" })
    expect(call("t8", undefined)).toMatchObject({ kind: "other", title: "tool" })
  })

  it("hides plumbing tools and drops their output", () => {
    const mapper = makeMuseItemMapper()
    for (const tool of ["write_todos", "request_user_input", "subagent_wait"])
      expect(
        mapper.item(
          { itemId: tool, kind: "toolCall", revision: 1, status: "inProgress", tool },
          "started"
        )
      ).toEqual([])
    expect(mapper.delta("subagent_wait", "output", "waiting")).toEqual([])
    expect(mapper.delta("unknown", "summary", "x")).toEqual([])
  })

  it("shows subagents as agent rows with their objective and result", () => {
    const mapper = makeMuseItemMapper()
    const agent = {
      itemId: "a1",
      kind: "subagent",
      revision: 1,
      status: "inProgress",
      objective: "Find the bug\nin parser",
      role: "explorer"
    }
    expect(payloads(mapper.item(agent, "started"))).toEqual([
      {
        sessionUpdate: "tool_call",
        toolCallId: "a1",
        kind: "agent",
        status: "in_progress",
        title: "Agent (explorer): Find the bug",
        rawInput: { prompt: "Find the bug\nin parser" }
      }
    ])
    expect(mapper.item({ ...agent, revision: 2 }, "updated")).toEqual([])
    expect(
      payloads(
        mapper.item(
          { ...agent, revision: 3, status: "completed", result: { summary: "Found it" } },
          "completed"
        )
      )
    ).toEqual([
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "a1",
        status: "completed",
        content: [{ type: "content", content: { type: "text", text: "Found it" } }]
      }
    ])
    const bare = payloads(
      mapper.item(
        { itemId: "a2", kind: "subagent", revision: 2, status: "failed", failureReason: "stopped" },
        "completed"
      )
    )
    expect(bare[0]).toMatchObject({ title: "Agent" })
    expect(bare[0]).not.toHaveProperty("rawInput")
    expect(bare[1]).toMatchObject({
      status: "failed",
      content: [{ type: "content", content: { type: "text", text: "stopped" } }]
    })
  })

  it("shows web searches, skill reads and compactions; skips Muse's housekeeping", () => {
    const mapper = makeMuseItemMapper()
    expect(
      payloads(
        mapper.item(
          { itemId: "w", kind: "webSearch", revision: 1, status: "inProgress", query: "msp" },
          "started"
        )
      )
    ).toEqual([
      {
        sessionUpdate: "tool_call",
        toolCallId: "w",
        kind: "fetch",
        title: "msp",
        status: "in_progress"
      }
    ])
    expect(
      mapper.item({ itemId: "w", kind: "webSearch", revision: 2, status: "inProgress" }, "updated")
    ).toEqual([])
    expect(
      payloads(
        mapper.item(
          { itemId: "w", kind: "webSearch", revision: 3, status: "completed", url: "https://a" },
          "completed"
        )
      )
    ).toEqual([
      {
        sessionUpdate: "tool_call_update",
        toolCallId: "w",
        kind: "fetch",
        title: "https://a",
        status: "completed"
      }
    ])
    expect(
      payloads(
        mapper.item(
          { itemId: "w2", kind: "webSearch", revision: 1, status: "inProgress" },
          "started"
        )
      )[0]
    ).toMatchObject({ title: "Web search" })
    expect(
      payloads(
        mapper.item(
          { itemId: "k", kind: "skillRead", revision: 1, status: "completed", selector: "plan" },
          "completed"
        )
      )[0]
    ).toMatchObject({
      kind: "read",
      title: "Skill: plan"
    })
    expect(
      payloads(
        mapper.item(
          { itemId: "k2", kind: "skillRead", revision: 1, status: "completed" },
          "completed"
        )
      )[0]
    ).toMatchObject({
      title: "Skill: skill"
    })
    const compaction = { itemId: "c", kind: "compaction", revision: 1, status: "inProgress" }
    expect(payloads(mapper.item(compaction, "started"))).toEqual([
      { sessionUpdate: "context_compaction", compactionId: "c", status: "started" }
    ])
    expect(mapper.item({ ...compaction, revision: 2 }, "updated")).toEqual([])
    expect(
      payloads(mapper.item({ ...compaction, revision: 3, status: "completed" }, "completed"))
    ).toEqual([{ sessionUpdate: "context_compaction", compactionId: "c", status: "completed" }])
    expect(
      payloads(
        mapper.item(
          { itemId: "c2", kind: "compaction", revision: 2, status: "failed" },
          "completed"
        )
      )
    ).toEqual([
      { sessionUpdate: "context_compaction", compactionId: "c2", status: "started" },
      { sessionUpdate: "context_compaction", compactionId: "c2", status: "failed" }
    ])
    for (const kind of ["userMessage", "reminderChild", "hookRun"])
      expect(
        mapper.item({ itemId: kind, kind, revision: 1, status: "completed" }, "completed")
      ).toEqual([])
  })
})
