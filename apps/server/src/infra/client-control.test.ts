import { EventEmitter } from "node:events"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { WebSocket } from "ws"
import { ClientControlBroker } from "./client-control.js"

class ClientSocket extends EventEmitter {
  sent: Array<{ requestId: string; method: string; navigation?: unknown }> = []
  sendError = false
  throwOnSend = false
  closed = false
  send(raw: string, callback: (error?: Error) => void) {
    if (this.throwOnSend) throw new Error("send failed")
    this.sent.push(JSON.parse(raw))
    callback(this.sendError ? new Error("disconnected") : undefined)
  }
  close() {
    this.closed = true
    this.emit("close")
  }
  frame(frame: unknown) {
    this.emit("message", Buffer.from(JSON.stringify(frame)))
  }
}
const context = { isActive: true, workspaces: [] }
const attach = (broker: ClientControlBroker, id: string) => {
  const socket = new ClientSocket()
  broker.attach(id, socket as unknown as WebSocket)
  socket.frame({ type: "hello", name: id, platform: "macos" })
  return socket
}

describe("native client control", () => {
  afterEach(() => vi.useRealTimers())

  it("targets one window and waits for its acknowledged context", async () => {
    const broker = new ClientControlBroker()
    const a = attach(broker, "a")
    const b = attach(broker, "b")
    try {
      expect(broker.list().map((client) => client.clientId)).toEqual(["a", "b"])
      const navigation = {
        workspaceId: "workspace",
        destination: { kind: "pane" as const, id: "pane" }
      }
      const result = broker.request("b", { method: "navigate", navigation })
      expect(a.sent).toEqual([])
      expect(b.sent[0]).toMatchObject({ method: "navigate", navigation })
      b.frame({ type: "response", requestId: "stale", context })
      b.frame({ type: "response", requestId: b.sent[0]!.requestId, context })
      expect(await result).toEqual(context)
      const failure = broker.request("a", { method: "context" })
      a.frame({ type: "response", requestId: a.sent[0]!.requestId, error: "Window is loading" })
      await expect(failure).rejects.toThrow("Window is loading")
      const invalid = broker.request("a", { method: "context" })
      a.frame({ type: "response", requestId: a.sent[1]!.requestId })
      await expect(invalid).rejects.toThrow("no context")
    } finally {
      broker.close()
    }
    expect(broker.list()).toEqual([])
    await expect(broker.request("missing", { method: "context" })).rejects.toThrow("not connected")
  })

  it("drops pending commands on replacement without replaying them or removing the replacement", async () => {
    const broker = new ClientControlBroker()
    const old = attach(broker, "window")
    const pending = broker.request("window", {
      method: "navigate",
      navigation: { workspaceId: "w" }
    })
    const replacement = attach(broker, "window")
    await expect(pending).rejects.toThrow("disconnected")
    old.emit("close")
    old.emit("error", new Error("old connection"))
    old.frame({ type: "hello", name: "old", platform: "ios" })
    expect(replacement.sent).toEqual([])
    expect(broker.list()).toMatchObject([{ name: "window", platform: "macos" }])
    const disconnected = broker.request("window", { method: "context" })
    replacement.close()
    await expect(disconnected).rejects.toThrow("disconnected")
    expect(broker.list()).toEqual([])
    broker.close()
  })

  it("times out unresponsive clients and cleans up unregistered connections", async () => {
    vi.useFakeTimers()
    const broker = new ClientControlBroker(1000)
    attach(broker, "silent")
    const failed = expect(broker.request("silent", { method: "context" })).rejects.toThrow(
      "outcome is unknown"
    )
    await vi.advanceTimersByTimeAsync(999)
    expect(broker.list()).toHaveLength(1)
    await vi.advanceTimersByTimeAsync(1)
    await failed
    expect(broker.list()).toEqual([])
    const incomplete = new ClientSocket()
    broker.attach("incomplete", incomplete as unknown as WebSocket)
    expect(broker.list()).toEqual([])
    await vi.advanceTimersByTimeAsync(1000)
    expect(incomplete.closed).toBe(true)
    expect(vi.getTimerCount()).toBe(0)
    broker.close()
  })

  it.each(["malformed", "socket-error", "send-error", "send-throw"])(
    "fails closed on %s",
    async (kind) => {
      const broker = new ClientControlBroker()
      const socket = attach(broker, "client")
      socket.sendError = kind === "send-error"
      socket.throwOnSend = kind === "send-throw"
      const result = broker.request("client", { method: "context" })
      if (kind === "malformed") socket.emit("message", Buffer.from("not json"))
      if (kind === "socket-error") socket.emit("error", new Error("broken"))
      await expect(result).rejects.toThrow("disconnected")
      expect(broker.list()).toEqual([])
      broker.close()
    }
  )
})
