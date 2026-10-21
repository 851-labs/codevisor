import { afterEach, describe, expect, it, vi } from "vitest"

import { NodeStreamableHttpTransport } from "./mcp-http-transport.js"

afterEach(() => {
  vi.unstubAllGlobals()
})

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
