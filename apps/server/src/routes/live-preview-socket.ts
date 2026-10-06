import type { McpManager } from "@codevisor/mcp"
import type { RawData, WebSocket } from "ws"

export const LIVE_PREVIEW_SOCKET_PATH = "/v1/live-preview/socket"

/// Frames are dropped, not queued, past this much unsent data: a live view
/// wants the newest frame, never a backlog of stale ones.
const MAX_BUFFERED_BYTES = 2 * 1024 * 1024

/// One client's live view of a session's agent, for the picture-in-picture
/// card. The server sends `{type: "tool", tool}` with the tool the agent
/// touched last ("browser" or "computer") and on every switch, and
/// `{type: "status", state, title, url}` on every change to the tab it
/// drives through Browser Use. While the client asks for them with
/// `{type: "watch", dimension}` it also sends that tab's `{type: "frame",
/// data}` JPEGs; `{type: "unwatch"}` pauses frames without closing.
/// Computer Use frames travel over screen sharing, not this socket.
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
  socket.on("message", (raw: RawData) => {
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
