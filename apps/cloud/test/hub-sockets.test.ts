import { describe, expect, it, vi } from "vitest"

import { closingSocket, openSocket, taggedSockets } from "./hub-port-test-support.js"

describe("HubSockets delivery acknowledgement", () => {
  it("does not claim delivery to a closing socket whose send would be discarded", () => {
    const socket = closingSocket()
    const send = vi.spyOn(socket, "send")
    const net = taggedSockets(new Map())

    expect(net.send(socket, new Uint8Array([1]))).toBe(false)
    expect(send).not.toHaveBeenCalled()
  })

  it("reports a send that throws after the open-state check as failed", () => {
    const socket = openSocket()
    vi.spyOn(socket, "send").mockImplementation(() => {
      throw new Error("socket died")
    })
    const net = taggedSockets(new Map())

    expect(net.send(socket, "frame")).toBe(false)
  })
})
