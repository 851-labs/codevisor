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

  it("reports a window's ids in the server's lowercase form", async () => {
    const broker = new ClientControlBroker()
    const socket = attach(broker, "a")
    try {
      const result = broker.request("a", { method: "context" })
      socket.frame({
        type: "response",
        requestId: socket.sent[0]!.requestId,
        context: {
          isActive: true,
          workspaceId: "806AD5F8-3C5C-444A-916D-230D5501E9E2",
          workspaces: [
            {
              id: "806AD5F8-3C5C-444A-916D-230D5501E9E2",
              projectId: "CD36B326-E564-4E7A-B842-3737988458E2",
              name: "ABCDEF01-2345-6789-ABCD-EF0123456789",
              tabId: "tab-One",
              tabs: []
            }
          ]
        }
      })
      expect(await result).toEqual({
        isActive: true,
        workspaceId: "806ad5f8-3c5c-444a-916d-230d5501e9e2",
        workspaces: [
          {
            id: "806ad5f8-3c5c-444a-916d-230d5501e9e2",
            projectId: "cd36b326-e564-4e7a-b842-3737988458e2",
            // Only UUID-shaped id fields change; names and other ids keep their case.
            name: "ABCDEF01-2345-6789-ABCD-EF0123456789",
            tabId: "tab-One",
            tabs: []
          }
        ]
      })
    } finally {
      broker.close()
    }
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
    // Typed for gateway scripts: the window went away mid-command.
    await expect(disconnected).rejects.toMatchObject({
      status: 503,
      code: "client_unavailable",
      details: { clientId: "window", name: "window", phase: "in-flight" }
    })
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

  it("lists what each window views without waiting on, or detaching, a slow one", async () => {
    vi.useFakeTimers({ now: new Date("2026-01-02T03:04:05.000Z") })
    const broker = new ClientControlBroker()
    const focused = attach(broker, "focused")
    const slow = attach(broker, "slow")
    const machine = { id: "server", name: "Studio" }
    const capabilities = {
      pages: ["home"],
      settingsSections: [],
      layoutActions: [],
      windowActions: []
    }
    const panes = [{ id: "pane", kind: "chat", title: "Chat", sessionId: "chat" }]
    const listing = broker.describe(machine, null, 1500)
    expect(slow.sent).toMatchObject([{ method: "context" }])
    focused.frame({
      type: "response",
      requestId: focused.sent[0]!.requestId,
      context: {
        isActive: true,
        workspaceId: "workspace",
        page: { page: "workspace" },
        capabilities,
        workspaces: [
          {
            id: "workspace",
            projectId: "project",
            name: "Workspace",
            tabId: "tab",
            sessionId: "chat",
            tabs: [{ id: "tab", panes }]
          }
        ]
      }
    })
    await vi.advanceTimersByTimeAsync(1500)
    expect(await listing).toEqual([
      {
        id: "focused",
        clientId: "focused",
        name: "focused",
        platform: "macos",
        machine,
        online: true,
        isActive: true,
        lastActiveAt: "2026-01-02T03:04:05.000Z",
        viewing: { workspaceId: "workspace", sessionId: "chat", page: "workspace", panes },
        capabilities
      },
      {
        id: "slow",
        clientId: "slow",
        name: "slow",
        platform: "macos",
        machine,
        online: true
      }
    ])
    // A slow answer to a read-only probe is not a lost command.
    expect(broker.list().map((client) => client.clientId)).toEqual(["focused", "slow"])
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
