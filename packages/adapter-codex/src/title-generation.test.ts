import { afterEach, describe, expect, it, vi } from "vitest"

import { FakeCodexClient } from "./test-support.js"
import { CodexTitleGenerator, parseGeneratedTitle } from "./title-generation.js"

const deferred = <T>() => {
  let resolve!: (value: T) => void
  const promise = new Promise<T>((done) => {
    resolve = done
  })
  return { promise, resolve }
}

class TitleClient extends FakeCodexClient {
  readonly started = deferred<void>()
  readonly startingThread = deferred<void>()
  readonly unsubscribed = deferred<void>()
  holdStart: Promise<void> | undefined
  failConfig = false
  failStart = false
  failCleanup = false

  override async request<T>(method: string, params?: unknown): Promise<T> {
    this.requests.push({ method, params })
    switch (method) {
      case "config/read":
        if (this.failConfig) throw new Error("offline")
        return { config: { mcp_servers: { external: { command: "external" } } } } as T
      case "thread/start":
        this.startingThread.resolve()
        if (this.failStart) throw new Error("Cannot start temporary thread")
        if (this.holdStart) await this.holdStart
        return { thread: { id: "hidden-title" } } as T
      case "turn/start":
        this.started.resolve()
        return { turn: { id: "title-turn" } } as T
      case "thread/read":
        return { thread: { name: this.threadName } } as T
      case "thread/name/set":
        this.threadName = (params as { name: string }).name
        return {} as T
      case "thread/unsubscribe":
        this.unsubscribed.resolve()
        if (this.failCleanup) throw new Error("Connection closed")
        return {} as T
      case "turn/interrupt":
        if (this.failCleanup) throw new Error("Connection closed")
        return {} as T
      default:
        throw new Error(`Unexpected title request: ${method}`)
    }
  }
}

const fixture = (resumed = false) => {
  const client = new TitleClient()
  const generator = new CodexTitleGenerator(client, "main", "/project", resumed)
  generator.rememberPrompt("Please fix the login form validation")
  const finish = (text = '{"title":"Fix login validation"}', status = "completed") => {
    expect(
      generator.handleNotification("item/completed", {
        threadId: "hidden-title",
        item: { type: "agentMessage", text }
      })
    ).toBe(true)
    generator.handleNotification("turn/completed", {
      threadId: "hidden-title",
      turn: { id: "title-turn", status }
    })
  }
  return { client, generator, finish }
}

afterEach(() => vi.useRealTimers())

describe("Codex title generation", () => {
  it("generates once through an isolated thread and persists the name", async () => {
    const { client, generator, finish } = fixture()
    generator.rememberPrompt("A later message must not replace the original")
    const generation = generator.onTurnCompleted()
    expect(generator.onTurnCompleted()).toBe(generation)
    await client.started.promise
    expect(client.requests.find((r) => r.method === "thread/start")?.params).toMatchObject({
      ephemeral: true,
      sandbox: "read-only",
      model: "gpt-5.6-luna",
      config: { "features.apps": false, mcp_servers: { external: { enabled: false } } }
    })
    expect(client.requests.find((r) => r.method === "turn/start")?.params).toMatchObject({
      input: [{ text: "User's first message:\nPlease fix the login form validation" }],
      effort: "low"
    })
    expect(generator.handleNotification("turn/completed", { threadId: "main" })).toBe(false)
    expect(generator.handleNotification("anything", null)).toBe(false)
    expect(
      generator.handleNotification("item/agentMessage/delta", { threadId: "hidden-title" })
    ).toBe(true)
    finish()
    await generation
    await client.unsubscribed.promise
    expect(client.threadName).toBe("Fix login validation")
    await generator.onTurnCompleted()
    expect(client.requests.filter((r) => r.method === "thread/start")).toHaveLength(1)
  })

  it.each(["notification", "read"])(
    "preserves an external rename observed by %s",
    async (source) => {
      const { client, generator, finish } = fixture()
      const generation = generator.onTurnCompleted()
      await client.started.promise
      client.threadName = "My title"
      if (source === "notification") generator.observeName("My title")
      finish()
      await generation
      expect(client.requests.some((r) => r.method === "thread/name/set")).toBe(false)
      expect(client.threadName).toBe("My title")
    }
  )

  it("skips resumed, already named, empty, and closed sessions", async () => {
    const resumed = fixture(true)
    await resumed.generator.onTurnCompleted()
    expect(resumed.client.requests).toEqual([])
    const named = fixture()
    named.generator.observeName("Existing title")
    await named.generator.onTurnCompleted()
    expect(named.client.requests).toEqual([])
    const client = new TitleClient()
    const empty = new CodexTitleGenerator(client, "main", "/project", false)
    empty.rememberPrompt("   ")
    empty.observeName(null)
    await empty.onTurnCompleted()
    empty.close()
    await empty.onTurnCompleted()
    expect(client.requests).toEqual([])
  })

  it.each(["malformed", "failed", "error", "oversized"])(
    "keeps the fallback on %s output",
    async (failure) => {
      const { client, generator, finish } = fixture()
      const generation = generator.onTurnCompleted()
      await client.started.promise
      if (failure === "error") {
        generator.handleNotification("error", { threadId: "hidden-title", willRetry: true })
        generator.handleNotification("error", { threadId: "hidden-title", willRetry: false })
      } else {
        finish(
          failure === "oversized" ? "x".repeat(9_000) : "invalid",
          failure === "failed" ? "failed" : "completed"
        )
      }
      await generation
      expect(client.threadName).toBeNull()
      await client.unsubscribed.promise
    }
  )

  it("bounds a stalled request and cleans up without affecting the main thread", async () => {
    vi.useFakeTimers()
    const { client, generator } = fixture()
    client.failCleanup = true
    const generation = generator.onTurnCompleted()
    await client.started.promise
    await vi.advanceTimersByTimeAsync(29_999)
    expect(client.requests.some((r) => r.method === "turn/interrupt")).toBe(false)
    await vi.advanceTimersByTimeAsync(1)
    await generation
    expect(client.requests.find((r) => r.method === "turn/interrupt")?.params).toEqual({
      threadId: "hidden-title",
      turnId: "title-turn"
    })
    expect(client.threadName).toBeNull()
  })

  it("detaches a temporary thread that starts after the session closes", async () => {
    const { client, generator } = fixture()
    client.failCleanup = true
    const gate = deferred<void>()
    client.holdStart = gate.promise
    const generation = generator.onTurnCompleted()
    await client.startingThread.promise
    generator.close()
    await generation
    gate.resolve()
    await client.unsubscribed.promise
    expect(client.requests.some((r) => r.method === "turn/start")).toBe(false)
  })

  it("treats unavailable configuration as a best-effort failure", async () => {
    const { client, generator } = fixture()
    client.failConfig = true
    await generator.onTurnCompleted()
    expect(client.requests.map((r) => r.method)).toEqual(["config/read"])
  })

  it("keeps the main session usable when the temporary thread cannot start", async () => {
    const { client, generator } = fixture()
    client.failStart = true
    await generator.onTurnCompleted()
    expect(client.threadName).toBeNull()
    expect(client.closed).toBe(false)
  })

  it("validates and bounds generated text without splitting Unicode", () => {
    for (const value of [undefined, "no JSON", "null", "{}", '{"title":3}', '{"title":"  "}']) {
      expect(parseGeneratedTitle(value)).toBeUndefined()
    }
    expect(parseGeneratedTitle('{"title":" Fix   login\\nvalidation "}')).toBe(
      "Fix login validation"
    )
    expect(parseGeneratedTitle(JSON.stringify({ title: "🚀".repeat(81) }))).toBe("🚀".repeat(80))
  })
})
