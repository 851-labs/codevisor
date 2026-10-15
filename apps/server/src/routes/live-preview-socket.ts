import type { McpManager } from "@codevisor/mcp"
import type { WebSocket } from "ws"

export const LIVE_PREVIEW_SOCKET_PATH = "/v1/live-preview/socket"

const MAX_BUFFERED_BYTES = 2 * 1024 * 1024

export const attachLivePreviewSocket = (
  mcp: Pick<McpManager, "subscribeAutomationUse" | "subscribeBrowserPreview">,
  sessionId: string,
  socket: WebSocket
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
    let message: { readonly type?: unknown; readonly dimension?: unknown }
    try {
      message = JSON.parse(raw.toString()) as typeof message
    } catch {
      return
    }
    if (message.type === "watch") {
      subscription.watch(typeof message.dimension === "number" ? message.dimension : 0)
    } else if (message.type === "unwatch") {
      subscription.unwatch()
    }
  })
  socket.on("close", () => {
    unsubscribeUse()
    subscription.close()
  })
}
