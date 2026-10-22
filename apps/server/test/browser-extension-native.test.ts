import { readFile } from "node:fs/promises"
import { join } from "node:path"
import { createContext, runInContext } from "node:vm"

import { describe, expect, it, vi } from "vitest"

type Listener = (...arguments_: ReadonlyArray<unknown>) => unknown

const event = () => {
  const listeners = new Set<Listener>()
  return {
    addListener: (listener: Listener) => listeners.add(listener),
    removeListener: (listener: Listener) => listeners.delete(listener),
    emit: (...arguments_: ReadonlyArray<unknown>) =>
      Promise.all([...listeners].map((listener) => listener(...arguments_)))
  }
}

class FakePort {
  readonly onMessage = event()
  readonly onDisconnect = event()
  readonly posted: Array<unknown> = []
  private readonly postWaiters = new Set<() => void>()
  disconnected = false

  constructor(
    readonly hostName: string,
    private readonly runtime: { lastError?: { message: string } | undefined }
  ) {}

  postMessage(message: unknown) {
    this.posted.push(message)
    for (const waiter of this.postWaiters) waiter()
  }

  posts(count: number): Promise<Array<unknown>> {
    return new Promise((resolve) => {
      const check = () => {
        if (this.posted.length < count) return
        this.postWaiters.delete(check)
        resolve(this.posted.slice(0, count))
      }
      this.postWaiters.add(check)
      check()
    })
  }

  disconnect() {
    this.disconnected = true
  }

  async exit(error?: string) {
    this.runtime.lastError = error === undefined ? undefined : { message: error }
    await this.onDisconnect.emit()
    this.runtime.lastError = undefined
  }
}

class FakeWebSocket {
  static readonly CONNECTING = 0
  static readonly OPEN = 1
  static readonly CLOSING = 2
  static readonly CLOSED = 3
  readyState = FakeWebSocket.CONNECTING

  constructor(readonly url: string) {
    sockets.push(this)
  }

  addEventListener() {}
}

const sockets: Array<FakeWebSocket> = []

const extensionScript = (name: string): Promise<string> =>
  readFile(
    join(
      process.cwd(),
      "..",
      "..",
      "packages",
      "automation",
      "resources",
      "browser-extension",
      name
    ),
    "utf8"
  )

const startBackground = async ({ nativeMessaging = true } = {}) => {
  sockets.splice(0)
  const ports: Array<FakePort> = []
  const runtimeMessage = event()
  const debuggerSendCommand = vi.fn(async (): Promise<unknown> => ({ ok: true }))
  const runtime: Record<string, unknown> & { lastError?: { message: string } | undefined } = {
    getManifest: () => ({ version: "0.3.0" }),
    onMessage: runtimeMessage,
    sendMessage: vi.fn(async () => ({ ok: true }))
  }
  if (nativeMessaging) {
    runtime.connectNative = (hostName: string) => {
      const port = new FakePort(hostName, runtime)
      ports.push(port)
      return port
    }
  }
  const context = createContext({
    CODEVISOR_RELAY: "ws://127.0.0.1:49361/v1/browser-use/extension/socket",
    CODEVISOR_NATIVE_HOST: "com.codevisor.host",
    URL,
    WebSocket: FakeWebSocket,
    chrome: {
      alarms: { clear: vi.fn(async () => true), create: vi.fn(async () => {}), onAlarm: event() },
      debugger: {
        attach: vi.fn(async () => undefined),
        detach: vi.fn(async () => undefined),
        sendCommand: debuggerSendCommand,
        onEvent: event(),
        onDetach: event()
      },
      downloads: { search: vi.fn(async () => []), onCreated: event(), onChanged: event() },
      runtime,
      tabs: {
        query: vi.fn(async () => [{ id: 7, url: "https://example.com", title: "Example" }]),
        onCreated: event(),
        onRemoved: event()
      }
    },
    clearInterval: vi.fn(),
    clearTimeout: vi.fn(),
    console,
    importScripts: vi.fn(),
    setInterval: vi.fn(() => 1),
    setTimeout: vi.fn(() => 1),
    self: { addEventListener: vi.fn() }
  })
  context.globalThis = context
  runInContext(await extensionScript("relay-candidates.js"), context)
  runInContext(await extensionScript("native-relay.js"), context)
  runInContext(await extensionScript("background.js"), context)
  const status = async () => {
    const reply = vi.fn()
    await runtimeMessage.emit({ type: "status" }, {}, reply)
    const value: unknown = reply.mock.calls[0]?.[0]
    return value
  }
  return { ports, status, debuggerSendCommand }
}

const connected = async (
  extension: Awaited<ReturnType<typeof startBackground>>,
  port: FakePort
) => {
  await port.onMessage.emit({ type: "hello", version: 1 })
  await port.onMessage.emit({ type: "connected" })
  await vi.waitFor(
    async () => expect(await extension.status()).toMatchObject({ connected: true }),
    { timeout: 10_000 }
  )
}

describe("browser extension native messaging", () => {
  it("connects through the native host instead of the localhost socket", async () => {
    const extension = await startBackground()
    const [port] = extension.ports

    await connected(extension, port!)

    expect(port!.hostName).toBe("com.codevisor.host")
    expect(sockets).toEqual([])
    expect(await extension.status()).toMatchObject({
      connected: true,
      transport: "native",
      relay: "Native host com.codevisor.host"
    })
  })

  it("reassembles chunked commands and chunks replies too large for one message", async () => {
    const extension = await startBackground()
    const [port] = extension.ports
    await connected(extension, port!)
    await port!.onMessage.emit(
      '{"id":1,"method":"Target.attachToTarget","params":{"targetId":"7"}}'
    )
    await port!.posts(1)
    const screenshot = "x".repeat(9 * 1024 * 1024)
    extension.debuggerSendCommand.mockResolvedValueOnce({ data: screenshot })
    const command = '{"id":2,"sessionId":"tab:7","method":"Page.captureScreenshot"}'

    await port!.onMessage.emit({
      type: "chunk",
      id: 1,
      index: 0,
      count: 2,
      data: command.slice(0, 20)
    })
    await port!.onMessage.emit({
      type: "chunk",
      id: 1,
      index: 1,
      count: 2,
      data: command.slice(20)
    })

    const chunks = (await port!.posts(3)).slice(1).map(chunkFields)
    expect(chunks.map((chunk) => [chunk.index, chunk.count])).toEqual([
      [0, 2],
      [1, 2]
    ])
    expect(JSON.parse(chunks.map((chunk) => chunk.data).join(""))).toEqual({
      id: 2,
      result: { data: screenshot }
    })
    expect(extension.debuggerSendCommand).toHaveBeenLastCalledWith(
      { tabId: 7 },
      "Page.captureScreenshot",
      {}
    )
  })

  it("falls back to the localhost socket when the app has not installed the native host", async () => {
    const extension = await startBackground()

    await extension.ports[0]!.exit("Specified native messaging host not found.")

    expect(sockets.map((socket) => socket.url)).toEqual([
      "ws://127.0.0.1:49361/v1/browser-use/extension/socket"
    ])
    expect(await extension.status()).toMatchObject({
      transport: "websocket",
      relay: "ws://127.0.0.1:49361/v1/browser-use/extension/socket"
    })
  })

  it("waits for Codevisor instead of falling back when the native host reports it is not running", async () => {
    const extension = await startBackground()
    const [port] = extension.ports

    await port!.onMessage.emit({ type: "hello", version: 1 })
    await port!.onMessage.emit({
      type: "unavailable",
      reason: "Codevisor is not running on port 49361"
    })
    await port!.exit()

    expect(sockets).toEqual([])
    expect(await extension.status()).toMatchObject({
      connected: false,
      state: "reconnecting",
      transport: "native",
      lastConnectionError: "Codevisor is not running on port 49361"
    })
  })

  it("uses the localhost socket when Chrome has not granted native messaging", async () => {
    const extension = await startBackground({ nativeMessaging: false })

    expect(extension.ports).toEqual([])
    expect(sockets).toHaveLength(1)
    expect(await extension.status()).toMatchObject({ transport: "websocket" })
  })
})

const chunkFields = (message: unknown) => {
  const chunk: Record<string, unknown> =
    typeof message === "object" && message !== null ? { ...message } : {}
  return { index: chunk.index, count: chunk.count, data: String(chunk.data) }
}
