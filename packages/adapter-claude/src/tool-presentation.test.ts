import { afterEach, describe, expect, it, vi } from "vitest"
import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { webSearchSources } from "./claude.js"
import {
  definition,
  FakeQuery,
  initMessage,
  makeProvider,
  resultMessage,
  run,
  streamEvent
} from "./test-support.js"

describe("ClaudeProvider", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("maps the Task and Agent tools to kind agent", async () => {
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
    fake.push(
      streamEvent({
        content_block: { id: "task-1", name: "Task", type: "tool_use" },
        index: 0,
        type: "content_block_start"
      })
    )
    fake.push(
      streamEvent({
        content_block: { id: "task-2", name: "Agent", type: "tool_use" },
        index: 1,
        type: "content_block_start"
      })
    )
    fake.push(resultMessage())
    await promptPromise

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads).toContainEqual(
      expect.objectContaining({ kind: "agent", sessionUpdate: "tool_call", toolCallId: "task-1" })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({ kind: "agent", sessionUpdate: "tool_call", toolCallId: "task-2" })
    )
  })

  it("titles web searches with their query and maps them to kind web_search", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("look it up"))
    await fake.nextPrompt()
    fake.push(
      streamEvent({
        content_block: { id: "ws-1", name: "WebSearch", type: "tool_use" },
        index: 0,
        type: "content_block_start"
      })
    )
    fake.push({
      message: {
        content: [
          {
            id: "ws-1",
            input: { query: "swift concurrency actors" },
            name: "WebSearch",
            type: "tool_use"
          },
          {
            id: "wf-1",
            input: { url: "https://example.com/docs" },
            name: "WebFetch",
            type: "tool_use"
          }
        ],
        role: "assistant"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "assistant"
    } as never)
    fake.push(resultMessage())
    await promptPromise

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    expect(payloads).toContainEqual(
      expect.objectContaining({
        kind: "web_search",
        sessionUpdate: "tool_call",
        toolCallId: "ws-1"
      })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({
        kind: "web_search",
        sessionUpdate: "tool_call_update",
        title: "Searched for swift concurrency actors",
        toolCallId: "ws-1"
      })
    )
    expect(payloads).toContainEqual(
      expect.objectContaining({
        kind: "fetch",
        sessionUpdate: "tool_call_update",
        title: "Fetched https://example.com/docs",
        toolCallId: "wf-1"
      })
    )
  })

  it("surfaces WebSearch result sources as resource_link content", async () => {
    const fake = new FakeQuery()
    const provider = makeProvider(fake)
    const events: Array<RuntimeEvent> = []
    const emit = async (event: RuntimeEvent): Promise<void> => {
      events.push(event)
    }
    const createPromise = run(provider.createSession(definition, "/tmp", emit))
    fake.push(initMessage())
    const created = await createPromise

    const promptPromise = run(created.handle.prompt("look it up"))
    await fake.nextPrompt()
    // The WebSearch tool_result is a plain string with an embedded Links array
    // (verbatim shape from the Claude CLI).
    const resultText =
      'Web search results for query: "swift release"\n\n' +
      'Links: [{"title":"Swift 6.2 Released | Swift.org","url":"https://www.swift.org/blog/swift-6.2-released/"},' +
      '{"title":"Releases · swiftlang/swift","url":"https://github.com/swiftlang/swift/releases"}]\n\n' +
      "Swift 6.2 was released on September 15, 2025."
    fake.push({
      message: {
        content: [
          { content: resultText, is_error: false, tool_use_id: "ws-1", type: "tool_result" }
        ],
        role: "user"
      },
      parent_tool_use_id: null,
      session_id: "sdk-session-1",
      type: "user"
    } as never)
    fake.push(resultMessage())
    await promptPromise

    const payloads = events.map((event) => event.payload as Record<string, unknown>)
    const update = payloads.find(
      (payload) =>
        payload.sessionUpdate === "tool_call_update" &&
        payload.toolCallId === "ws-1" &&
        Array.isArray(payload.content)
    )
    expect(update?.content).toEqual([
      {
        content: {
          name: "Swift 6.2 Released | Swift.org",
          title: "Swift 6.2 Released | Swift.org",
          type: "resource_link",
          uri: "https://www.swift.org/blog/swift-6.2-released/"
        },
        type: "content"
      },
      {
        content: {
          name: "Releases · swiftlang/swift",
          title: "Releases · swiftlang/swift",
          type: "resource_link",
          uri: "https://github.com/swiftlang/swift/releases"
        },
        type: "content"
      }
    ])
  })
})

describe("webSearchSources", () => {
  it("parses the Links array from a WebSearch result string", () => {
    const result =
      'Web search results for query: "swift release"\n\n' +
      'Links: [{"title":"A","url":"https://a.example"},{"title":"B","url":"https://b.example"}]\n\n' +
      "Some commentary."
    expect(webSearchSources(result)).toEqual([
      { title: "A", url: "https://a.example" },
      { title: "B", url: "https://b.example" }
    ])
  })

  it("reads the text out of a block array result", () => {
    const blocks = [
      {
        text: 'Web search results for query: "x"\n\nLinks: [{"title":"A","url":"https://a"}]',
        type: "text"
      }
    ]
    expect(webSearchSources(blocks)).toEqual([{ title: "A", url: "https://a" }])
  })

  it("isolates the array even when a title contains brackets", () => {
    const result =
      'Web search results for query: "x"\n\n' +
      'Links: [{"title":"Array [T] docs","url":"https://a"}]\n\nend'
    expect(webSearchSources(result)).toEqual([{ title: "Array [T] docs", url: "https://a" }])
  })

  it("returns [] for non-search results and malformed links", () => {
    expect(webSearchSources("total 0\n-rw-r--r-- file.txt")).toEqual([])
    expect(webSearchSources('Links: [{"title":"A","url":"https://a"}]')).toEqual([])
    expect(webSearchSources('Web search results for query: "x"\n\nLinks: [not json')).toEqual([])
    expect(webSearchSources(undefined)).toEqual([])
  })
})
