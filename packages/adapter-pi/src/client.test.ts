import type { NdjsonTransport } from "@codevisor/agent-runtime"
import { describe, expect, it, vi } from "vitest"

import { wirePiClient } from "./client.js"

/// An in-memory transport: records what the client sends and lets a test
/// write Pi's lines or fail the pipe.
const transport = () => {
  const sent: Array<Record<string, unknown>> = []
  let line: ((line: string) => void) | undefined
  let failure: ((error: Error) => void) | undefined
  let closed = false
  const fake: NdjsonTransport = {
    pid: 1,
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
    write: (record: unknown) =>
      line?.(typeof record === "string" ? record : JSON.stringify(record)),
    fail: (error: Error) => failure?.(error),
    closed: () => closed
  }
}

describe("Pi RPC client", () => {
  it("correlates responses with commands by id", async () => {
    const pipe = transport()
    const client = wirePiClient(pipe.fake)
    const state = client.command("get_state")
    const model = client.command("set_model", { provider: "x", modelId: "y" })
    expect(pipe.sent).toEqual([
      { id: "codevisor-1", type: "get_state" },
      { id: "codevisor-2", type: "set_model", provider: "x", modelId: "y" }
    ])
    // Out of order, and with responses for nobody in between.
    pipe.write({ type: "response", id: "codevisor-2", success: false, error: "Model not found" })
    pipe.write({ type: "response", id: "someone-else", success: true })
    pipe.write({ type: "response", command: "parse", success: false, error: "bad json" })
    pipe.write({ type: "response", id: "codevisor-1", success: true, data: { sessionId: "s" } })
    await expect(state).resolves.toEqual({ sessionId: "s" })
    await expect(model).rejects.toThrow("Model not found")
    const failed = client.command("abort")
    pipe.write({ type: "response", id: "codevisor-3", success: false })
    await expect(failed).rejects.toThrow("Pi failed.")
  })

  it("delivers events and dialogs, and answers dialogs", () => {
    const pipe = transport()
    const client = wirePiClient(pipe.fake)
    const events: Array<Record<string, unknown>> = []
    client.onEvent((event) => events.push(event))
    pipe.write({ type: "agent_start" })
    pipe.write("not json")
    pipe.write({ type: "extension_ui_request", id: "d1", method: "confirm" })
    expect(events.map((event) => event.type)).toEqual(["agent_start", "extension_ui_request"])
    client.respond({ id: "d1", confirmed: true })
    expect(pipe.sent).toEqual([{ id: "d1", confirmed: true, type: "extension_ui_response" }])

    // A handler that throws is logged, not allowed to escape the stream.
    const error = vi.spyOn(console, "error").mockImplementation(() => undefined)
    client.onEvent(() => {
      throw new Error("boom")
    })
    pipe.write({ type: "agent_end" })
    expect(error).toHaveBeenCalledWith("Error handling pi event agent_end", expect.any(Error))
    error.mockRestore()
  })

  it("fails outstanding commands when Pi exits, and only reports real failures", async () => {
    const pipe = transport()
    const client = wirePiClient(pipe.fake)
    const closes: Array<string> = []
    client.onClose((error) => closes.push(error.message))
    const pending = client.command("prompt", { message: "hi" })
    pipe.fail(new Error("pi exited"))
    pipe.fail(new Error("again"))
    await expect(pending).rejects.toThrow("pi exited")
    expect(closes).toEqual(["pi exited"])
    await expect(client.command("get_state")).rejects.toThrow("Pi is no longer running.")

    const second = transport()
    const closing = wirePiClient(second.fake)
    closing.onClose((error) => closes.push(error.message))
    const outstanding = closing.command("get_state")
    closing.close()
    await expect(outstanding).rejects.toThrow("Pi was closed.")
    expect(second.closed()).toBe(true)
    expect(closes).toEqual(["pi exited"])
  })
})
