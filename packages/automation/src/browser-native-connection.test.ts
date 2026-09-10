import { EventEmitter } from "node:events"
import { afterEach, describe, expect, it, vi } from "vitest"
const mocks = vi.hoisted(() => ({ socket: vi.fn(), read: vi.fn() }))
vi.mock("node:net", () => ({ createConnection: mocks.socket }))
vi.mock("node:fs", () => ({ readFileSync: mocks.read }))
import { connectNativeBrowser, nativeBrowserSocketPath } from "./browser-native-connection.js"

class Wire extends EventEmitter {
  readonly written: Record<string, unknown>[] = []
  autoConnect = true
  reply: (packet: Record<string, unknown>) => unknown = () => ({ available: true })
  setEncoding() {}
  write(line: string) {
    const packet = JSON.parse(line)
    this.written.push(packet)
    const result = this.reply(packet)
    if (result !== undefined) {
      const data = JSON.stringify({ id: packet.id, result }) + "\n"
      // Fragmented frames must survive the Unix stream boundary.
      this.emit("data", data.slice(0, 7))
      this.emit("data", data.slice(7))
    }
  }
  end() {
    this.emit("close")
  }
  destroy() {
    this.emit("close")
  }
}
const setup = () => {
  const wire = new Wire()
  mocks.read.mockReturnValue("fixture-token")
  mocks.socket.mockImplementation(() => {
    if (wire.autoConnect) queueMicrotask(() => wire.emit("connect"))
    return wire
  })
  return wire
}
afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
  vi.clearAllMocks()
})

describe("native browser local transport", () => {
  it("isolates Unix paths by installation and OS user", () => {
    expect(nativeBrowserSocketPath("/fixture/data", 501)).toMatch(
      /^\/tmp\/codevisor-browser-501-[0-9a-f]+\.sock$/
    )
    expect(nativeBrowserSocketPath("/fixture/data", 501)).not.toBe(
      nativeBrowserSocketPath("/fixture/other", 501)
    )
    expect(nativeBrowserSocketPath("/fixture/data", 501)).not.toBe(
      nativeBrowserSocketPath("/fixture/data", 502)
    )
    expect(nativeBrowserSocketPath("/fixture/data")).toContain(`-${process.getuid?.() ?? 0}-`)
    vi.stubGlobal("process", { ...process, getuid: undefined })
    expect(nativeBrowserSocketPath("/fixture/data")).toContain("-0-")
  })
  it("authenticates locally and delivers fragmented replies and session events", async () => {
    const wire = setup()
    const { connection } = await connectNativeBrowser("/fixture/data", "session", "darwin")
    expect(connection).toBeDefined()
    try {
      expect(mocks.socket).toHaveBeenCalledWith(nativeBrowserSocketPath("/fixture/data"))
      expect(wire.written[0]).toMatchObject({
        method: "Codevisor.connect",
        params: { token: "fixture-token", sessionId: "session" }
      })
      const events: unknown[] = []
      connection!.on("Page.loadEventFired", (value) => events.push(value), "session")
      wire.emit(
        "data",
        '{"method":"Page.loadEventFired","sessionId":"session","params":{"timestamp":1}}\n'
      )
      expect(events).toEqual([{ timestamp: 1 }])
      wire.reply = () => ({ targetInfos: [] })
      expect(await connection!.send("Target.getTargets")).toEqual({ targetInfos: [] })
    } finally {
      await connection?.close()
    }
    expect(connection!.closed).toBe(true)
  })
  it("treats unsupported hosts, missing tokens, refused connections and rejected setup as unavailable", async () => {
    setup()
    expect(await connectNativeBrowser("/fixture", "s", "linux")).toMatchObject({
      reason: expect.any(String)
    })
    mocks.read.mockImplementation(() => {
      throw Error("missing")
    })
    expect(await connectNativeBrowser("/fixture", "s", "darwin")).toMatchObject({
      reason: expect.any(String)
    })
    const refused = setup()
    refused.autoConnect = false
    mocks.socket.mockImplementation(() => {
      queueMicrotask(() => refused.emit("error", Error("refused")))
      return refused
    })
    expect(await connectNativeBrowser("/fixture", "s", "darwin")).toMatchObject({
      reason: expect.any(String)
    })
    const rejected = setup()
    rejected.reply = () => ({ available: false })
    expect(await connectNativeBrowser("/fixture", "s", "darwin")).toMatchObject({
      reason: expect.any(String)
    })
  })
  it("bounds connection setup and authentication without depending on a client", async () => {
    vi.useFakeTimers()
    const wire = setup()
    wire.autoConnect = false
    const unavailable = connectNativeBrowser("/fixture", "s", "darwin")
    await vi.advanceTimersByTimeAsync(1499)
    expect(wire.written).toHaveLength(0)
    await vi.advanceTimersByTimeAsync(1)
    expect(await unavailable).toMatchObject({ reason: expect.any(String) })
    const unresponsive = setup()
    unresponsive.reply = () => undefined
    const authentication = connectNativeBrowser("/fixture", "s", "darwin")
    await vi.advanceTimersByTimeAsync(1500)
    expect(await authentication).toMatchObject({ reason: expect.any(String) })
  })
  it("closes a disconnected or oversized stream and rejects pending commands", async () => {
    const wire = setup()
    const { connection } = await connectNativeBrowser("/fixture", "s", "darwin")
    wire.emit("error", Error("lost native app"))
    await expect(connection!.send("Target.getTargets")).rejects.toThrow("lost native app")
    wire.destroy()
    const oversized = setup()
    const { connection: next } = await connectNativeBrowser("/fixture", "s", "darwin")
    oversized.emit("data", "x".repeat(64 * 1024 * 1024 + 1))
    expect(next!.closed).toBe(true)
  })
})
