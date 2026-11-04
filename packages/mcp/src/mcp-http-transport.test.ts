import { afterEach, describe, expect, it, vi } from "vitest"
import { z } from "zod"

import { streamableHttpTransport } from "./mcp-http-transport.js"

afterEach(() => {
  vi.unstubAllGlobals()
  vi.restoreAllMocks()
})

const SentMessageSchema = z.object({ id: z.number().optional() })

const ping = { jsonrpc: "2.0" as const, id: 1, method: "ping" }

const pong = () =>
  new Response(JSON.stringify({ jsonrpc: "2.0", id: 1, result: {} }), {
    headers: { "content-type": "application/json" }
  })

const serve = (accepted: string) => {
  const presented: Array<string | null> = []
  vi.stubGlobal(
    "fetch",
    vi.fn(async (_url: URL, init: RequestInit) => {
      const authorization = new Headers(init.headers).get("authorization")
      presented.push(authorization)
      if (authorization !== `Bearer ${accepted}`) return new Response("expired", { status: 401 })
      return pong()
    })
  )
  return presented
}

describe("Streamable HTTP headers", () => {
  it("sends the access token, protocol version and custom headers with every request", async () => {
    const fetchMock = vi.fn<typeof fetch>(async () => pong())
    vi.stubGlobal("fetch", fetchMock)
    const transport = streamableHttpTransport(new URL("https://example.test/mcp"), "access-token", {
      "X-Workspace": "emojis"
    })
    const received = vi.fn()
    Object.assign(transport, { onmessage: received })
    transport.setProtocolVersion("2025-11-25")
    await transport.start()

    await transport.send(ping)
    await transport.send(ping)

    const sent = fetchMock.mock.calls.map(([, init]) => new Headers(init?.headers))
    expect(sent.map((headers) => headers.get("authorization"))).toEqual([
      "Bearer access-token",
      "Bearer access-token"
    ])
    expect(sent.map((headers) => headers.get("x-workspace"))).toEqual(["emojis", "emojis"])
    expect(sent[0]?.get("mcp-protocol-version")).toBe("2025-11-25")
    expect(received).toHaveBeenCalledTimes(2)
    await transport.close()
  })

  it("reports what the server said when it rejects a static access token", async () => {
    serve("fresh")
    const transport = streamableHttpTransport(new URL("https://mcp.example/mcp"), "stale")
    await transport.start()

    await expect(transport.send(ping)).rejects.toThrow("Streamable HTTP error 401: expired")
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
    const transport = streamableHttpTransport(new URL("https://mcp.example/mcp"), {
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
    const transport = streamableHttpTransport(new URL("https://mcp.example/mcp"), {
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
    const transport = streamableHttpTransport(new URL("https://mcp.example/mcp"))
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
