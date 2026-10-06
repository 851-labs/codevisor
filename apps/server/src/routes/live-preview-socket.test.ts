import { EventEmitter, once } from "node:events"

import type { BrowserPreviewViewer } from "@codevisor/automation"
import type { AutomationTool } from "@codevisor/mcp"
import { describe, expect, it } from "vitest"
import { WebSocket } from "ws"

import { jsonRequest, makeServices, runningServers, start, startWithApp } from "../test-support.js"
import { attachLivePreviewSocket } from "./live-preview-socket.js"

/// The socket surface the route uses, with a controllable send buffer.
const fakeSocket = () => {
  const socket = Object.assign(new EventEmitter(), {
    OPEN: 1,
    readyState: 1,
    bufferedAmount: 0,
    sent: [] as Array<Record<string, unknown>>,
    send(text: string) {
      socket.sent.push(JSON.parse(text) as Record<string, unknown>)
    }
  })
  return socket
}

describe("browser preview socket", () => {
  it("relays the last tool, status, and frames, honors watch requests, and drops frames under backpressure", () => {
    let viewer: BrowserPreviewViewer | undefined
    let useListener: ((tool: AutomationTool) => void) | undefined
    const calls: Array<unknown> = []
    const socket = fakeSocket()
    attachLivePreviewSocket(
      {
        subscribeAutomationUse: (sessionId, listener) => {
          calls.push(["use", sessionId])
          useListener = listener
          return () => calls.push(["unuse"])
        },
        subscribeBrowserPreview: (sessionId, subscriber) => {
          calls.push(["subscribe", sessionId])
          viewer = subscriber
          return {
            watch: (dimension) => calls.push(["watch", dimension]),
            unwatch: () => calls.push(["unwatch"]),
            close: () => calls.push(["close"])
          }
        }
      },
      "chat",
      socket as unknown as WebSocket
    )

    useListener!("browser")
    viewer!.status({ state: "active", title: "Example", url: "https://example.com/" })
    viewer!.frame("jpeg-1")
    socket.bufferedAmount = 3 * 1024 * 1024
    viewer!.frame("jpeg-2")
    socket.bufferedAmount = 0
    socket.readyState = 3
    viewer!.frame("jpeg-3")
    expect(socket.sent).toEqual([
      { type: "tool", tool: "browser" },
      { type: "status", state: "active", title: "Example", url: "https://example.com/" },
      { type: "frame", data: "jpeg-1" }
    ])

    for (const message of [
      { type: "watch", dimension: 900 },
      { type: "watch" },
      { type: "unwatch" },
      { type: "other" }
    ])
      socket.emit("message", Buffer.from(JSON.stringify(message)))
    socket.emit("message", Buffer.from("not json"))
    socket.emit("close")
    expect(calls).toEqual([
      ["use", "chat"],
      ["subscribe", "chat"],
      ["watch", 900],
      ["watch", 0],
      ["unwatch"],
      ["unuse"],
      ["close"]
    ])
  })

  it("serves the route to authorized clients with a session id", async () => {
    const { server } = await start()
    const socket = new WebSocket(
      `${server.url.replace("http", "ws")}/v1/live-preview/socket?sessionId=chat`
    )
    try {
      const [raw] = await once(socket, "message")
      expect(JSON.parse(String(raw))).toEqual({
        type: "status",
        state: "inactive",
        title: "",
        url: ""
      })
    } finally {
      socket.close()
    }
  })

  it("advertises live-preview-v1 only when the MCP manager is present", async () => {
    const { services } = await makeServices("server-a")
    const features = async (server: Awaited<ReturnType<typeof startWithApp>>) => {
      runningServers.push(server)
      return ((await jsonRequest(server, "/v1/info")).body as { features: Array<string> }).features
    }
    expect(await features(await startWithApp(services))).toContain("live-preview-v1")
    const { mcp: _mcp, ...withoutMcp } = services
    expect(await features(await startWithApp(withoutMcp))).not.toContain("live-preview-v1")
  })
})
