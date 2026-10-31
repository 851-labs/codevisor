import { afterEach, describe, expect, it, vi } from "vitest"
import { z } from "zod"

import { NodeStreamableHttpTransport } from "./mcp-http-transport.js"

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

const SentMessageSchema = z.object({ id: z.number().optional() })

const ping = { jsonrpc: "2.0" as const, id: 1, method: "ping" }

const serve = (accepted: string) => {
  const presented: Array<string | null> = []
  vi.stubGlobal(
    "fetch",
    vi.fn(async (_url: URL, init: RequestInit) => {
      const authorization = new Headers(init.headers).get("authorization")
      presented.push(authorization)
      if (authorization !== `Bearer ${accepted}`) return new Response("expired", { status: 401 })
      return new Response(JSON.stringify({ jsonrpc: "2.0", id: 1, result: {} }), {
        headers: { "content-type": "application/json" }
      })
    })
  )
  return presented
}

const splitSse = (event: string, at: number) =>
  new Response(
    new ReadableStream({
      start: (controller) => {
        controller.enqueue(new TextEncoder().encode(event.slice(0, at)))
        controller.enqueue(new TextEncoder().encode(event.slice(at)))
        controller.close()
      }
    }),
    { headers: { "content-type": "text/event-stream" } }
  )

describe("Streamable HTTP responses", () => {
  it("handles each response shape and keeps the session, protocol and custom headers", async () => {
    const responses = [
      new Response(
        JSON.stringify([
          { jsonrpc: "2.0", id: 1, result: {} },
          { jsonrpc: "2.0", method: "notifications/tools/list_changed" }
        ]),
        {
          headers: { "content-type": "application/json", "mcp-session-id": "session-1" }
        }
      ),
      new Response(null, { status: 202 }),
      new Response("upstream failed", { status: 500, statusText: "Failure" }),
      new Response("unexpected", { headers: { "content-type": "text/plain" } }),
      new Response("missing content type"),
      splitSse(
        `event: message\ndata: ${JSON.stringify({ jsonrpc: "2.0", id: 5, result: {} })}\n\n`,
        24
      ),
      new Response(
        `event: message\ndata: ${JSON.stringify({ jsonrpc: "2.0", method: "notifications/tools/list_changed" })}\n\n`,
        { headers: { "content-type": "text/event-stream" } }
      ),
      new Response(
        `event: message\ndata: ${JSON.stringify([{ jsonrpc: "2.0", id: 8, result: {} }])}\n\n`,
        { headers: { "content-type": "text/event-stream" } }
      ),
      new Response("event: message\ndata: not-json\n\n", {
        headers: { "content-type": "text/event-stream" }
      }),
      new Response(null, { headers: { "content-type": "text/event-stream" } })
    ]
    const fetchMock = vi.fn<typeof fetch>(async () => responses.shift()!)
    vi.stubGlobal("fetch", fetchMock)
    const errors = vi.spyOn(console, "error").mockImplementation(() => undefined)
    const transport = new NodeStreamableHttpTransport(
      new URL("https://example.test/mcp"),
      "access-token",
      { "X-Workspace": "emojis" }
    )
    const messages: unknown[] = []
    let closed = false
    // oxlint-disable-next-line unicorn/prefer-add-event-listener
    transport.onmessage = (message) => messages.push(message)
    // oxlint-disable-next-line unicorn/prefer-add-event-listener
    transport.onclose = () => {
      closed = true
    }
    transport.setProtocolVersion("2025-11-25")
    await transport.start()
    await expect(transport.start()).rejects.toThrow("already started")
    await transport.send({ jsonrpc: "2.0", id: 1, method: "ping" })
    await transport.send({ jsonrpc: "2.0", method: "notifications/initialized" })
    await expect(transport.send({ jsonrpc: "2.0", id: 3, method: "ping" })).rejects.toThrow(
      "Streamable HTTP error 500: upstream failed"
    )
    await expect(transport.send({ jsonrpc: "2.0", id: 4, method: "ping" })).rejects.toThrow(
      "Unexpected MCP response content type"
    )
    await expect(transport.send({ jsonrpc: "2.0", id: 4.5, method: "ping" })).rejects.toThrow(
      "Unexpected MCP response content type"
    )
    await transport.send({ jsonrpc: "2.0", id: 5, method: "ping" })
    await transport.send({ jsonrpc: "2.0", method: "notifications/initialized" })
    await transport.send({ jsonrpc: "2.0", id: 8, method: "ping" })
    await transport.send({ jsonrpc: "2.0", id: 9, method: "ping" })
    await transport.send({ jsonrpc: "2.0", id: 10, method: "ping" })

    expect(messages).toEqual([
      { jsonrpc: "2.0", id: 1, result: {} },
      { jsonrpc: "2.0", method: "notifications/tools/list_changed" },
      { jsonrpc: "2.0", id: 5, result: {} },
      { jsonrpc: "2.0", method: "notifications/tools/list_changed" },
      { jsonrpc: "2.0", id: 8, result: {} }
    ])
    expect(errors).toHaveBeenCalledWith(expect.stringContaining("Unable to decode MCP SSE event"))
    const firstHeaders = new Headers(fetchMock.mock.calls[0]?.[1]?.headers)
    expect(firstHeaders.get("authorization")).toBe("Bearer access-token")
    expect(firstHeaders.get("mcp-protocol-version")).toBe("2025-11-25")
    expect(
      fetchMock.mock.calls.map(([, init]) => new Headers(init?.headers).get("x-workspace"))
    ).toEqual(fetchMock.mock.calls.map(() => "emojis"))
    expect(new Headers(fetchMock.mock.calls[1]?.[1]?.headers).get("mcp-session-id")).toBe(
      "session-1"
    )
    await transport.close()
    expect(closed).toBe(true)
  })
})

describe("Streamable HTTP authorization", () => {
  it("renews a rejected token once and resends the request", async () => {
    const presented = serve("fresh")
    let current = "stale"
    const recoverUnauthorized = vi.fn(async () => {
      current = "fresh"
      return { retry: true } as const
    })
    const transport = new NodeStreamableHttpTransport(new URL("https://mcp.example/mcp"), {
      accessToken: async () => current,
      recoverUnauthorized
    })
    const received = vi.fn()
    Object.assign(transport, { onmessage: received })
    await transport.start()

    await transport.send(ping)

    expect(presented).toEqual(["Bearer stale", "Bearer fresh"])
    expect(recoverUnauthorized).toHaveBeenCalledExactlyOnceWith("stale")
    expect(received).toHaveBeenCalledOnce()
  })

  it("reports why a rejected token could not be renewed", async () => {
    const presented = serve("fresh")
    const transport = new NodeStreamableHttpTransport(new URL("https://mcp.example/mcp"), {
      accessToken: async () => "stale",
      recoverUnauthorized: async () => ({ retry: false, reason: "Tracker needs authorization" })
    })
    await transport.start()

    await expect(transport.send(ping)).rejects.toThrow(
      "Streamable HTTP error 401: Tracker needs authorization"
    )
    expect(presented).toEqual(["Bearer stale"])
  })
})

describe("Streamable HTTP cancellation", () => {
  it("aborts only the in-flight request a cancellation names", async () => {
    const requests = new Map<number, AbortSignal>()
    vi.stubGlobal(
      "fetch",
      vi.fn(async (_url: URL, init: RequestInit) => {
        const message = SentMessageSchema.parse(
          JSON.parse(typeof init.body === "string" ? init.body : "{}")
        )
        if (message.id === undefined) return new Response(null, { status: 202 })
        const signal = init.signal!
        requests.set(message.id, signal)
        return new Promise<Response>((_resolve, reject) => {
          signal.addEventListener("abort", () => reject(signal.reason))
        })
      })
    )
    const transport = new NodeStreamableHttpTransport(new URL("https://mcp.example/mcp"))
    await transport.start()
    const cancel = (params?: Record<string, unknown>) =>
      transport.send({
        jsonrpc: "2.0",
        method: "notifications/cancelled",
        ...(params === undefined ? {} : { params })
      })
    const aborted = () => [...requests].map(([id, signal]) => [id, signal.aborted])

    const cancelled = transport.send({ jsonrpc: "2.0", id: 7, method: "events/stream" })
    const kept = transport.send({ jsonrpc: "2.0", id: 8, method: "events/stream" })
    await cancel({ requestId: "a" })
    await cancel({ requestId: {} })
    await cancel()
    expect(aborted()).toEqual([
      [7, false],
      [8, false]
    ])

    await cancel({ requestId: 7 })

    await expect(cancelled).rejects.toMatchObject({ name: "AbortError" })
    expect(aborted()).toEqual([
      [7, true],
      [8, false]
    ])
    await cancel({ requestId: 8 })
    await expect(kept).rejects.toMatchObject({ name: "AbortError" })
  })
})
