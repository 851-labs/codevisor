import type { CloudSocket } from "@codevisor/cloud-client"
import { WebSocket } from "ws"

import { rawDataBytes } from "./ws-raw-data.js"

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
  socket.on("unexpected-response", (request, response) => {
    response.resume()
    request.destroy()
    adapted.onrejected?.(response.statusCode ?? 0)
  })
  socket.on("message", (data, isBinary) => {
    try {
      const bytes = rawDataBytes(data)
      adapted.onmessage?.(isBinary ? new Uint8Array(bytes) : bytes.toString())
    } catch {
      socket.close(1011, "message handler failed")
    }
  })
  socket.on("close", (code) => adapted.onclose?.(code))
  socket.on("error", () => undefined)
  return adapted
}
