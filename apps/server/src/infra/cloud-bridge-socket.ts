import type { CloudSocket } from "@codevisor/cloud-client"
import { WebSocket } from "ws"

/// The hub socket for CloudMachineConnection: a `ws` client adapted to the
/// CloudSocket callback interface (split out of cloud-bridge.ts for size).
export const socketFactory = (url: string, headers: Record<string, string>): CloudSocket => {
  const socket = new WebSocket(url, { headers })
  const adapted: CloudSocket = {
    send: (data) => socket.send(data),
    close: (code, reason) => socket.close(code, reason),
    terminate: () => socket.terminate(),
    onopen: null,
    onmessage: null,
    onclose: null,
    onrejected: null
  }
  socket.on("open", () => adapted.onopen?.())
  // With a listener attached, ws leaves a non-101 response to us instead of
  // collapsing it into an error + close 1006. Surface the status, then drop
  // the request; any close ws still reports refers to a socket already
  // detached by the connection.
  socket.on("unexpected-response", (request, response) => {
    response.resume()
    request.destroy()
    adapted.onrejected?.(response.statusCode ?? 0)
  })
  socket.on("message", (data, isBinary) => {
    // A throw here would escape ws's listener and exit the server (every
    // agent with it); a handler that fails drops this hub connection
    // instead, and its close drives the reconnect.
    try {
      // Binary frames carry relay envelope batches; text frames JSON control.
      if (isBinary) {
        const bytes = Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer)
        adapted.onmessage?.(new Uint8Array(bytes))
        return
      }
      adapted.onmessage?.(String(data))
    } catch {
      socket.close(1011, "message handler failed")
    }
  })
  socket.on("close", (code) => adapted.onclose?.(code))
  socket.on("error", () => undefined) // close fires afterwards and drives reconnect
  return adapted
}
