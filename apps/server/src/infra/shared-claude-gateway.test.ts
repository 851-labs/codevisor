import { createServer, IncomingMessage, ServerResponse } from "node:http"
import { Socket } from "node:net"
import type { AddressInfo } from "node:net"

import { describe, expect, it, onTestFinished, vi } from "vitest"

import { makeSharedClaudeGateway } from "./shared-claude-gateway.js"

const bundle = {
  harnessId: "claude-code",
  subject: "user",
  accessToken: "current",
  expiresAt: 10_000_000,
  ownership: "managed"
} as const
const fixture = async (options: Parameters<typeof makeSharedClaudeGateway>[0]) => {
  const gateway = makeSharedClaudeGateway(options)
  gateway.register("account", "original")
  const server = createServer((request, response) => {
    void gateway.handle(request, response, new URL(request.url!, "http://localhost"))
  })
  onTestFinished(async () => {
    gateway.close()
    server.closeAllConnections()
    await new Promise<void>((resolve) => server.close(() => resolve()))
  })
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  const base = `http://127.0.0.1:${(server.address() as AddressInfo).port}/harness/claude`
  const send = (path = "/v1/messages", headers: Record<string, string> = {}) =>
    fetch(`${base}${path}`, {
      method: "POST",
      headers: {
        authorization: "Bearer original",
        "content-type": "application/json",
        "anthropic-beta": "oauth-2025-04-20",
        ...headers
      },
      body: JSON.stringify({ messages: [] })
    })
  return { gateway, send, base }
}
describe("Claude shared account gateway", () => {
  it("retries an unauthorized request once with the new token and preserves streaming and OAuth headers", async () => {
    const token = vi.fn(async (_id: string, rejected?: string) => ({
      ...bundle,
      accessToken: rejected ? "refreshed" : "current"
    }))
    const requests: Array<{
      url: string
      authorization: string | null
      beta: string | null
      body: string
    }> = []
    const f = await fixture({
      token,
      fetch: (async (url, options) => {
        const headers = new Headers(options?.headers)
        requests.push({
          url: String(url),
          authorization: headers.get("authorization"),
          beta: headers.get("anthropic-beta"),
          body: String(options?.body)
        })
        return requests.length === 1
          ? new Response("expired", { status: 401 })
          : new Response("data: done\n\n", { headers: { "content-type": "text/event-stream" } })
      }) as typeof fetch
    })
    const response = await f.send("/v1/messages?beta=true")
    expect(response.status).toBe(200)
    expect(await response.text()).toBe("data: done\n\n")
    expect(requests.map((row) => row.authorization)).toEqual(["Bearer current", "Bearer refreshed"])
    expect(requests[1]?.beta).toBe("oauth-2025-04-20")
    expect(requests[1]?.url).toBe("https://api.anthropic.com/v1/messages?beta=true")
    expect(requests[0]?.body).toBe(requests[1]?.body)
    expect(token).toHaveBeenLastCalledWith("account", "current")
  })
  it("rejects unregistered credentials, browser origins and paths outside the provider API", async () => {
    const upstream = vi.fn(async () => new Response("unexpected")) as unknown as typeof fetch
    const f = await fixture({ token: async () => bundle, fetch: upstream })
    expect((await f.send("/v1/messages", { authorization: "Bearer stranger" })).status).toBe(401)
    expect((await f.send("/v1/messages", { origin: "https://example.test" })).status).toBe(403)
    expect((await f.send("/api/oauth/token")).status).toBe(404)
    f.gateway.forget("account")
    expect((await f.send()).status).toBe(401)
    expect(upstream).not.toHaveBeenCalled()
  })
  it("does not leak token errors or retry provider failures other than unauthorized", async () => {
    const f = await fixture({
      token: async () => {
        throw new Error("SECRET")
      }
    })
    const failed = await f.send()
    expect(failed.status).toBe(503)
    expect(await failed.text()).not.toContain("SECRET")
    const upstream = vi.fn(
      async () => new Response("limited", { status: 429 })
    ) as unknown as typeof fetch
    const g = await fixture({ token: async () => bundle, fetch: upstream })
    expect((await g.send()).status).toBe(429)
    expect(upstream).toHaveBeenCalledOnce()
  })
})

it("bounds request bodies and preserves private empty model responses", async () => {
  const upstream = vi.fn<typeof fetch>(
    async () =>
      new Response(null, {
        status: 204,
        headers: { "cache-control": "public", "set-cookie": "secret", connection: "keep-alive" }
      })
  )
  const f = await fixture({ token: async () => bundle, fetch: upstream })
  expect((await fetch(`${f.base}/v1/models`)).status).toBe(401)
  const empty = await fetch(`${f.base}/v1/models`, {
    headers: { authorization: "Bearer original" }
  })
  expect(empty.status).toBe(204)
  expect(empty.headers.get("cache-control")).toBe("no-store")
  expect(empty.headers.get("set-cookie")).toBeNull()
  expect(upstream.mock.calls[0]?.[1]?.body).toBeUndefined()
  const tooLarge = await fetch(`${f.base}/v1/messages`, {
    method: "POST",
    headers: { authorization: "Bearer original" },
    body: Buffer.alloc(32 * 1024 * 1024 + 1)
  })
  expect(tooLarge.status).toBe(413)
  expect(upstream).toHaveBeenCalledOnce()
  f.gateway.register("second", "unrelated")
  f.gateway.forget("account")
  expect(
    (await fetch(`${f.base}/v1/models`, { headers: { authorization: "Bearer unrelated" } })).status
  ).toBe(204)
})
it("ends a failed stream without appending a second HTTP response", async () => {
  let controller!: ReadableStreamDefaultController<Uint8Array>
  const f = await fixture({
    token: async () => bundle,
    fetch: (async () =>
      new Response(
        new ReadableStream<Uint8Array>({
          start(value) {
            controller = value
            value.enqueue(new TextEncoder().encode("first"))
          }
        })
      )) as typeof fetch
  })
  const response = await f.send()
  const body = response.text()
  const assertion = expect(body).rejects.toThrow()
  controller.error(new Error("upstream stream failed"))
  await assertion
})
it("refreshes an empty unauthorized response and aborts upstream when a client leaves", async () => {
  let count = 0,
    aborted!: () => void
  const disconnect = new Promise<void>((resolve) => {
    aborted = resolve
  })
  const f = await fixture({
    token: async () => bundle,
    fetch: (async (_url, options) => {
      if (++count === 1) return new Response(null, { status: 401 })
      options?.signal?.addEventListener("abort", aborted, { once: true })
      return new Response(
        new ReadableStream({
          start(controller) {
            controller.enqueue(new TextEncoder().encode("first"))
          }
        })
      )
    }) as typeof fetch
  })
  const response = await f.send()
  await response.body?.cancel()
  await disconnect
  expect(count).toBe(2)
})

it("rejects requests without a verified loopback peer", async () => {
  const gateway = makeSharedClaudeGateway({ token: async () => bundle })
  const socket = new Socket(),
    request = new IncomingMessage(socket),
    response = new ServerResponse(request)
  try {
    await gateway.handle(request, response, new URL("http://localhost/harness/claude/v1/models"))
    expect(response.statusCode).toBe(403)
  } finally {
    socket.destroy()
    response.destroy()
    gateway.close()
  }
})
