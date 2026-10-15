import { EventEmitter, once } from "node:events"

import type { BrowserPreviewViewer } from "@codevisor/automation"
import type { AutomationTool } from "@codevisor/mcp"
import { describe, expect, it } from "vitest"
import { WebSocket } from "ws"

import { jsonRequest, makeServices, start, startWithApp } from "../test-support.js"
import { attachLivePreviewSocket } from "./live-preview-socket.js"
import { field } from "./response-test-support.js"

class FakePreviewSocket extends EventEmitter {
  readonly OPEN = WebSocket.OPEN
  readyState: WebSocket["readyState"] = WebSocket.OPEN
  bufferedAmount = 0
  readonly sent: Array<unknown> = []
  send(text: string): void {
    const message: unknown = JSON.parse(text)
    this.sent.push(message)
  }
}

const fakeSocket = () => new FakePreviewSocket()

const advertisedFeatures = async (server: Awaited<ReturnType<typeof startWithApp>>) => {
  return field((await jsonRequest(server, "/v1/info")).body, "features")
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
      socket
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
    expect(await advertisedFeatures(await startWithApp(services))).toContain("live-preview-v1")
    const { mcp: _mcp, ...withoutMcp } = services
    expect(await advertisedFeatures(await startWithApp(withoutMcp))).not.toContain(
      "live-preview-v1"
    )
  })
})
