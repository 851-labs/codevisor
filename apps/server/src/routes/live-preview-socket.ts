import type { McpManager } from "@codevisor/mcp"
import type { WebSocket } from "ws"

import { field } from "../unknown-values.js"

export const LIVE_PREVIEW_SOCKET_PATH = "/v1/live-preview/socket"

const MAX_BUFFERED_BYTES = 2 * 1024 * 1024

type LivePreviewSocket = Pick<WebSocket, "readyState" | "OPEN" | "bufferedAmount" | "send"> & {
  on(event: "message", listener: (raw: Buffer) => void): unknown
  on(event: "close", listener: () => void): unknown
}

export const attachLivePreviewSocket = (
  mcp: Pick<McpManager, "subscribeAutomationUse" | "subscribeBrowserPreview">,
  sessionId: string,
  socket: LivePreviewSocket
): void => {
  const send = (message: Readonly<Record<string, unknown>>): void => {
    if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(message))
  }
  const unsubscribeUse = mcp.subscribeAutomationUse(sessionId, (tool) =>
    send({ type: "tool", tool })
  )
  const subscription = mcp.subscribeBrowserPreview(sessionId, {
    status: (status) => send({ type: "status", ...status }),
    frame: (data) => {
      if (socket.bufferedAmount <= MAX_BUFFERED_BYTES) send({ type: "frame", data })
    }
  })
  socket.on("message", (raw: Buffer) => {
    let message: unknown
    try {
      message = JSON.parse(raw.toString())
    } catch {
      return
    }
    const type = field(message, "type")
    const dimension = field(message, "dimension")
    if (type === "watch") {
      subscription.watch(typeof dimension === "number" ? dimension : 0)
    } else if (type === "unwatch") {
      subscription.unwatch()
    }
  })
  socket.on("close", () => {
    unsubscribeUse()
    subscription.close()
  })
}
