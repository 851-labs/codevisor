import { afterEach, describe, expect, it, vi } from "vitest"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { extractAllStringFields, extractStringField } from "./claude.js"
import { definition, FakeQuery, initMessage, makeProvider, run, settle } from "./test-support.js"

describe("ClaudeProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("emits authoritative diff stats and content from the PostToolUse hook", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    const created = await createPromise
    void created

    const hooks = fake.options?.hooks?.PostToolUse?.[0]?.hooks
    expect(hooks).toBeDefined()
    await hooks?.[0]?.(
      {
        cwd: "/tmp",
        hook_event_name: "PostToolUse",
        session_id: "sdk-session-1",
        tool_input: { file_path: "/tmp/a.txt", new_string: "x\ny\n", old_string: "z\n" },
        tool_name: "Edit",
        tool_response: {
          structuredPatch: [
            { lines: ["-z", "+x", "+y"], newLines: 2, newStart: 1, oldLines: 1, oldStart: 1 }
          ]
        },
        tool_use_id: "tool-hook-1",
        transcript_path: "/tmp/transcript"
      } as never,
      "tool-hook-1",
      { signal: new AbortController().signal }
    )
    await settle()

    const payload = events.at(-1)?.payload as Record<string, unknown>
    expect(payload).toMatchObject({
      sessionUpdate: "tool_call_update",
      toolCallId: "tool-hook-1",
      diffStats: [{ added: 2, path: "/tmp/a.txt", removed: 1 }]
    })
    expect(payload.content).toEqual([
      { newText: "x\ny\n", oldText: "z\n", path: "/tmp/a.txt", type: "diff" }
    ])
  })

  it("recomputes stats for a Write creation whose structuredPatch is empty", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    await settle()
    fake.push(initMessage())
    await createPromise

    // The SDK reports file creations with an empty structuredPatch — there
    // was nothing to patch. Counting its hunks yields an authoritative
    // +0 −0 that used to beat the content-derived totals in the client.
    const hooks = fake.options?.hooks?.PostToolUse?.[0]?.hooks
    expect(hooks).toBeDefined()
    await hooks?.[0]?.(
      {
        cwd: "/tmp",
        hook_event_name: "PostToolUse",
        session_id: "sdk-session-1",
        tool_input: { content: "a\nb\nc\n", file_path: "/tmp/new.py" },
        tool_name: "Write",
        tool_response: { structuredPatch: [], type: "create" },
        tool_use_id: "tool-hook-2",
        transcript_path: "/tmp/transcript"
      } as never,
      "tool-hook-2",
      { signal: new AbortController().signal }
    )
    await settle()

    const payload = events.at(-1)?.payload as Record<string, unknown>
    expect(payload).toMatchObject({
      sessionUpdate: "tool_call_update",
      toolCallId: "tool-hook-2",
      diffStats: [{ added: 3, path: "/tmp/new.py", removed: 0 }]
    })
    expect(payload.content).toEqual([
      { newText: "a\nb\nc\n", oldText: null, path: "/tmp/new.py", type: "diff" }
    ])
  })
})

describe("partial JSON string extraction", () => {
  it("extracts complete and streaming values", () => {
    const complete = '{"file_path":"/a.txt","old_string":"one\\ntwo"}'
    expect(extractStringField(complete, "file_path")).toBe("/a.txt")
    expect(extractStringField(complete, "old_string")).toBe("one\ntwo")

    const partial = '{"file_path":"/a.txt","new_string":"line one\\nline tw'
    expect(extractStringField(partial, "new_string")).toBe("line one\nline tw")
    expect(extractStringField(partial, "missing")).toBeUndefined()
  })

  it("decodes escapes including unicode", () => {
    const json = '{"s":"tab\\there \\u0041 quote\\" done"}'
    expect(extractStringField(json, "s")).toBe('tab\there A quote" done')
  })

  it("extracts every occurrence for MultiEdit", () => {
    const json =
      '{"edits":[{"old_string":"a\\nb","new_string":"c"},{"old_string":"d","new_string":"e\\nf"}]}'
    expect(extractAllStringFields(json, "old_string")).toEqual(["a\nb", "d"])
    expect(extractAllStringFields(json, "new_string")).toEqual(["c", "e\nf"])
  })
})
