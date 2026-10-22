import type { WebSocket } from "ws"

export const rawDataBytes = (data: WebSocket.RawData) => {
  if (Array.isArray(data)) return Buffer.concat(data)
  if (data instanceof ArrayBuffer) return Buffer.from(data)
  return data
}
