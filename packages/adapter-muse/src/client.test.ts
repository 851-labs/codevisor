import type { NdjsonTransport } from "@codevisor/agent-runtime"
import { describe, expect, it, vi } from "vitest"

import {
  handshake,
  museExitMessage,
  MuseExitedError,
  MuseRequestError,
  wireMuseClient
} from "./client.js"
import { FakeMuseClient } from "./test-support.js"

/// An in-memory transport: records what the client sends and lets a test
/// write Muse's lines or fail the pipe.
const transport = () => {
  const sent: Array<Record<string, unknown>> = []
  let line: ((line: string) => void) | undefined
  let failure: ((error: Error) => void) | undefined
  let closed = false
  const fake: NdjsonTransport = {
    isOpen: () => !closed,
    send: (payload) => sent.push(payload),
    onLine: (handler) => {
      line = handler
    },
    onFailure: (handler) => {
      failure = handler
    },
    close: () => {
      closed = true
    }
  }
  return {
    fake,
    sent,
    write: (frame: unknown) => line?.(typeof frame === "string" ? frame : JSON.stringify(frame)),
    fail: (error: Error) => failure?.(error),
    closed: () => closed
  }
}

describe("MSP client", () => {
  it("correlates JSON-RPC 2.0 responses with requests, carrying Muse's error kind", async () => {
    const pipe = transport()
    const client = wireMuseClient(pipe.fake)
    const listed = client.request("model/list", { sessionId: "s" })
    const started = client.request("turn/start")
    const read = client.request("account/read")
    expect(pipe.sent).toEqual([
      { jsonrpc: "2.0", id: 1, method: "model/list", params: { sessionId: "s" } },
      { jsonrpc: "2.0", id: 2, method: "turn/start" },
      { jsonrpc: "2.0", id: 3, method: "account/read" }
    ])
    // Out of order, with garbage and a response for nobody in between.
    pipe.write("not json")
    pipe.write({ jsonrpc: "2.0", id: 99, result: {} })
    pipe.write({ jsonrpc: "2.0", id: "1", result: {} })
    pipe.write({
      jsonrpc: "2.0",
      id: 2,
      error: { code: -32030, message: "busy", data: { kind: "commandRejected" } }
    })
    pipe.write({ jsonrpc: "2.0", id: 3, error: {} })
    pipe.write({ jsonrpc: "2.0", id: 1, result: { models: [] } })
    await expect(listed).resolves.toEqual({ models: [] })
    const rejected = await started.catch((error: unknown) => error)
    expect(rejected).toBeInstanceOf(MuseRequestError)
    expect(rejected).toMatchObject({ message: "busy", code: -32030, kind: "commandRejected" })
    await expect(read).rejects.toMatchObject({
      message: "Muse rejected the request",
      code: undefined,
      kind: undefined
    })
    client.notify("initialized")
    client.notify("account/changed", { state: "x" })
    expect(pipe.sent.slice(-2)).toEqual([
      { jsonrpc: "2.0", method: "initialized" },
      { jsonrpc: "2.0", method: "account/changed", params: { state: "x" } }
    ])
  })

  it("delivers notifications and answers server requests with the handler's receipt", () => {
    const pipe = transport()
    const client = wireMuseClient(pipe.fake)
    // Before a handler exists, Muse's request still gets an answer.
    pipe.write({ jsonrpc: "2.0", id: 7, method: "approval/request", params: {} })
    expect(pipe.sent.at(-1)).toMatchObject({ id: 7, error: { code: -32601 } })
    pipe.write({ jsonrpc: "2.0", method: "item/delta", params: { delta: "early" } })

    const notes: Array<[string, unknown]> = []
    client.onNotification((method, params) => notes.push([method, params]))
    client.onRequest((method) => (method === "userInput/request" ? "not a record" : { ok: true }))
    pipe.write({ jsonrpc: "2.0", method: "item/delta", params: { delta: "hi" } })
    pipe.write({ jsonrpc: "2.0", id: 8, method: "approval/request", params: {} })
    pipe.write({ jsonrpc: "2.0", id: 9, method: "userInput/request", params: {} })
    expect(notes).toEqual([["item/delta", { delta: "hi" }]])
    expect(pipe.sent.slice(-2)).toEqual([
      { jsonrpc: "2.0", id: 8, result: { ok: true } },
      { jsonrpc: "2.0", id: 9, result: {} }
    ])
  })

  it("contains handler failures: notifications are skipped, requests answered with an error", () => {
    const pipe = transport()
    const client = wireMuseClient(pipe.fake)
    const logged = vi.spyOn(console, "error").mockImplementation(() => undefined)
    client.onNotification(() => {
      throw new Error("mapping bug")
    })
    client.onRequest(() => {
      throw new Error("question bug")
    })
    pipe.write({ jsonrpc: "2.0", method: "item/started", params: {} })
    pipe.write({ jsonrpc: "2.0", id: 4, method: "approval/request", params: {} })
    expect(logged).toHaveBeenCalledTimes(2)
    expect(pipe.sent).toEqual([
      {
        jsonrpc: "2.0",
        id: 4,
        error: {
          code: -32603,
          message: "Codevisor couldn't handle approval/request",
          data: { kind: "internal" }
        }
      }
    ])
    logged.mockRestore()
  })

  it("fails pending requests when Muse stops, and reports why exactly once", async () => {
    const pipe = transport()
    const client = wireMuseClient(pipe.fake)
    const closes: Array<Error> = []
    client.onClose((error) => closes.push(error))
    const pending = client.request("session/start")
    pipe.fail(new Error("muse exited: credentials"))
    pipe.fail(new Error("again"))
    await expect(pending).rejects.toBeInstanceOf(MuseExitedError)
    expect(closes.map((error) => error.message)).toEqual(["muse exited: credentials"])
    await expect(client.request("model/list")).rejects.toThrow("muse is no longer running")

    // An explained exit keeps its explanation.
    const explained = transport()
    const other = wireMuseClient(explained.fake)
    const reasons: Array<Error> = []
    other.onClose((error) => reasons.push(error))
    const exit = new MuseExitedError(museExitMessage(4, ""))
    explained.fail(exit)
    expect(reasons).toEqual([exit])
  })

  it("closes deliberately without reporting a failure", async () => {
    const pipe = transport()
    const client = wireMuseClient(pipe.fake)
    const closes: Array<Error> = []
    client.onClose((error) => closes.push(error))
    const pending = client.request("model/list")
    client.close()
    await expect(pending).rejects.toThrow("muse client closed")
    expect(closes).toEqual([])
    expect(pipe.closed()).toBe(true)
  })

  it("explains the exit codes Muse documents", () => {
    expect(museExitMessage(3, "x")).toMatch(/Sign in to Muse again/)
    expect(museExitMessage(4, "x")).toMatch(/open in another Muse window/)
    expect(museExitMessage(5, "x")).toMatch(/doesn't include the session host/)
    expect(museExitMessage(1, "fallback")).toBe("fallback")
    expect(museExitMessage(null, "fallback")).toBe("fallback")
  })
})

describe("handshake", () => {
  it("initializes with the experimental surface and the session MCP capability", async () => {
    const client = new FakeMuseClient()
    const warn = vi.fn()
    await expect(handshake(client, warn)).resolves.toEqual({
      version: "1.4.7",
      experimentalApi: true,
      capabilities: ["sessionMcp"]
    })
    expect(client.sent("initialize")[0]).toMatchObject({
      capabilities: { experimentalApi: true, requestedCapabilities: ["sessionMcp"] }
    })
    expect(client.notified).toEqual(["initialized"])
    expect(warn).not.toHaveBeenCalled()
  })

  it("works with a newer schema but notes the difference", async () => {
    const client = new FakeMuseClient()
    client.replies.initialize = {
      serverInfo: { version: "1.5.0-R1" },
      schema: { fingerprint: "sha256:new" }
    }
    const warn = vi.fn()
    await expect(handshake(client, warn)).resolves.toEqual({
      version: "1.5.0-R1",
      experimentalApi: false,
      capabilities: []
    })
    expect(warn).toHaveBeenCalledWith(expect.stringContaining("sha256:new"))
    client.replies.initialize = { serverInfo: { version: "2" } }
    await handshake(client, warn)
    expect(warn).toHaveBeenLastCalledWith(expect.stringContaining("schema unknown"))
    // Exactly the minimum, and a short or odd version, still pass.
    for (const version of ["1.4.0", "1.4", "1.4.x"]) {
      client.replies.initialize = { serverInfo: { version } }
      await expect(handshake(client, warn)).resolves.toMatchObject({ version })
    }
    expect(warn).toHaveBeenLastCalledWith(expect.stringContaining("schema unknown"))
  })

  it("refuses a Muse too old for Codevisor", async () => {
    const client = new FakeMuseClient()
    client.replies.initialize = { serverInfo: { version: "1.3.9" } }
    await expect(handshake(client)).rejects.toThrow(
      "This version of Muse Code (1.3.9) is too old for Codevisor. Update Muse Code to 1.4.0 or newer."
    )
    expect(client.closed).toBe(true)
    client.replies.initialize = {}
    await expect(handshake(client)).rejects.toThrow("(0) is too old")
  })
})
