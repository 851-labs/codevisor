import { describe, expect, it, vi } from "vitest"
import { HubSockets } from "../src/hub-sockets.js"

describe("HubSockets delivery acknowledgement", () => {
  it("does not claim delivery to a closing socket whose send would be discarded", () => {
    const send = vi.fn()
    const socket = { readyState: WebSocket.CLOSING, send } as unknown as WebSocket
    const net = new HubSockets({} as DurableObjectState)

    expect(net.send(socket, new Uint8Array([1]))).toBe(false)
    expect(send).not.toHaveBeenCalled()
  })

  it("reports a send that throws after the open-state check as failed", () => {
    const socket = {
      readyState: WebSocket.OPEN,
      send: () => {
        throw new Error("socket died")
      }
    } as unknown as WebSocket
    const net = new HubSockets({} as DurableObjectState)

    expect(net.send(socket, "frame")).toBe(false)
  })
})
