import { Socket } from "node:net"
import { afterEach, expect, it, vi } from "vitest"
import { hasExistingListener } from "./listener-probe.js"

afterEach(() => vi.restoreAllMocks())
it.each(["0.0.0.0", "::", "127.0.0.1"])(
  "probes %s on loopback without reserving a port",
  async (host) => {
    const socket = new Socket()
    const dial = vi.fn(() => socket)
    const result = hasExistingListener(host, 4321, dial)
    socket.emit("error", new Error("connection refused"))
    expect(await result).toBe(false)
    expect(dial).toHaveBeenCalledWith({ host: "127.0.0.1", port: 4321 })
    expect(socket.destroyed).toBe(true)
  }
)
it("closes a probe when its socket timeout fires", async () => {
  const socket = new Socket()
  let timeout: (() => void) | undefined
  vi.spyOn(socket, "setTimeout").mockImplementation((_ms, callback) => {
    timeout = callback
    return socket
  })
  const result = hasExistingListener("127.0.0.1", 4321, () => socket)
  expect(socket.destroyed).toBe(false)
  expect(socket.setTimeout).toHaveBeenCalledWith(1000, expect.any(Function))
  timeout!()
  expect(await result).toBe(false)
  expect(socket.destroyed).toBe(true)
})
