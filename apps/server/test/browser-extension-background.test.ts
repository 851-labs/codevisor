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
    emit: (...arguments_: ReadonlyArray<unknown>) => {
      for (const listener of listeners) listener(...arguments_)
    }
  }
}

class FakeWebSocket {
  static readonly CONNECTING = 0
  static readonly OPEN = 1
  static readonly CLOSING = 2
  static readonly CLOSED = 3
  static readonly instances: FakeWebSocket[] = []

  readonly listeners = new Map<string, Set<Listener>>()
  readyState = FakeWebSocket.CONNECTING
  onmessage?: Listener
  onclose?: Listener
  onerror?: Listener

  constructor(readonly url: string) {
    FakeWebSocket.instances.push(this)
  }

  addEventListener(type: string, listener: Listener) {
    const listeners = this.listeners.get(type) ?? new Set()
    listeners.add(listener)
    this.listeners.set(type, listeners)
  }

  send() {}

  open() {
    this.readyState = FakeWebSocket.OPEN
    return this.emit("open")
  }

  error() {
    return this.emit("error")
  }

  async close() {
    if (this.readyState === FakeWebSocket.CLOSED) return
    this.readyState = FakeWebSocket.CLOSED
    await this.emit("close")
  }

  private async emit(type: string) {
    const property = new Map([
      ["message", this.onmessage],
      ["close", this.onclose],
      ["error", this.onerror]
    ]).get(type)
    await Promise.all([
      property?.(),
      ...[...(this.listeners.get(type) ?? [])].map((listener) => listener())
    ])
  }
}

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

const startBackground = async (relay: string) => {
  FakeWebSocket.instances.splice(0)
  const runtimeMessage = event()
  const alarm = event()
  const debuggerEvent = event()
  const debuggerDetach = event()
  const tabCreated = event()
  const tabRemoved = event()
  const downloadCreated = event()
  const downloadChanged = event()
  const retryScheduled = Promise.withResolvers<void>()
  const alarms = {
    clear: vi.fn(async () => true),
    create: vi.fn(async () => {
      retryScheduled.resolve()
    }),
    onAlarm: alarm
  }
  const scheduledTimers = new Map<number, Listener>()
  const importScripts = vi.fn()
  let nextTimer = 1
  const context = createContext({
    CODEVISOR_RELAY: relay,
    WebSocket: FakeWebSocket,
    chrome: {
      action: {},
      alarms,
      debugger: {
        attach: vi.fn(async () => undefined),
        detach: vi.fn(async () => undefined),
        sendCommand: vi.fn(async () => ({})),
        onEvent: debuggerEvent,
        onDetach: debuggerDetach
      },
      downloads: {
        search: vi.fn(async () => []),
        onCreated: downloadCreated,
        onChanged: downloadChanged
      },
      offscreen: {
        hasDocument: vi.fn(async () => false),
        createDocument: vi.fn(async () => undefined)
      },
      runtime: {
        getManifest: () => ({ version: "0.2.0" }),
        onMessage: runtimeMessage,
        sendMessage: vi.fn(async () => ({ ok: true }))
      },
      tabs: {
        query: vi.fn(async () => []),
        onCreated: tabCreated,
        onRemoved: tabRemoved
      }
    },
    clearInterval: vi.fn(),
    clearTimeout: (timer: number) => scheduledTimers.delete(timer),
    console,
    importScripts,
    setInterval: vi.fn(() => 1),
    setTimeout: (listener: Listener) => {
      const timer = nextTimer++
      scheduledTimers.set(timer, listener)
      return timer
    },
    self: { addEventListener: vi.fn() },
    URL
  })
  runInContext(await extensionScript("relay-candidates.js"), context)
  runInContext(await extensionScript("background.js"), context)
  return { alarm, alarms, importScripts, retryScheduled, runtimeMessage }
}

describe("browser extension background connection", () => {
  it("keeps one socket active, schedules durable retries, and supports manual reconnect", async () => {
    const { alarm, alarms, importScripts, retryScheduled, runtimeMessage } = await startBackground(
      "ws://127.0.0.1:51000/relay"
    )
    expect(importScripts).toHaveBeenCalledWith(
      "relay-config.js",
      "relay-candidates.js",
      "tab-groups.js"
    )
    expect(FakeWebSocket.instances).toHaveLength(1)
    const first = FakeWebSocket.instances[0]!
    await first.error()
    await retryScheduled.promise

    expect(alarms.create).toHaveBeenCalledOnce()
    expect(FakeWebSocket.instances).toHaveLength(1)

    alarm.emit({ name: "codevisor-reconnect" })
    expect(FakeWebSocket.instances).toHaveLength(2)
    alarm.emit({ name: "codevisor-reconnect" })
    expect(FakeWebSocket.instances).toHaveLength(2)

    const second = FakeWebSocket.instances[1]!
    await second.open()

    const connected = vi.fn()
    runtimeMessage.emit({ type: "status" }, {}, connected)
    expect(connected).toHaveBeenCalledWith(
      expect.objectContaining({
        connected: true,
        state: "connected",
        controlledTabs: 0,
        version: "0.2.0"
      })
    )

    const reconnecting = vi.fn()
    runtimeMessage.emit({ type: "reconnect" }, {}, reconnecting)
    expect(FakeWebSocket.instances).toHaveLength(3)
    expect(reconnecting).toHaveBeenCalledWith(
      expect.objectContaining({ connected: false, state: "connecting" })
    )
  })

  it("looks for Codevisor across its port range before backing off", async () => {
    const { alarms, retryScheduled, runtimeMessage } = await startBackground(
      "ws://127.0.0.1:49361/v1/browser-use/extension/socket"
    )

    await FakeWebSocket.instances[0]!.error()
    await FakeWebSocket.instances[1]!.error()
    expect(FakeWebSocket.instances.map((socket) => new URL(socket.url).port)).toEqual([
      "49361",
      "49362",
      "49363"
    ])
    expect(alarms.create).not.toHaveBeenCalled()

    await FakeWebSocket.instances[2]!.open()
    const status = vi.fn()
    runtimeMessage.emit({ type: "status" }, {}, status)
    expect(status).toHaveBeenCalledWith(
      expect.objectContaining({
        connected: true,
        relay: "ws://127.0.0.1:49363/v1/browser-use/extension/socket"
      })
    )

    await FakeWebSocket.instances[2]!.close()
    await retryScheduled.promise
    expect(FakeWebSocket.instances).toHaveLength(3)
  })

  it("starts from a moved server's port and still covers the rest of the range", async () => {
    await startBackground("ws://127.0.0.1:49363/v1/browser-use/extension/socket")

    await FakeWebSocket.instances[0]!.error()
    await FakeWebSocket.instances[1]!.error()

    expect(FakeWebSocket.instances.map((socket) => new URL(socket.url).port)).toEqual([
      "49363",
      "49361",
      "49362"
    ])
  })

  it("backs off after every port in the range refuses", async () => {
    const { alarms, retryScheduled } = await startBackground(
      "ws://127.0.0.1:49361/v1/browser-use/extension/socket"
    )

    for (let index = 0; index < 39; index += 1) await FakeWebSocket.instances[index]!.error()
    await retryScheduled.promise

    expect(FakeWebSocket.instances.map((socket) => new URL(socket.url).port).at(-1)).toBe("49399")
    expect(FakeWebSocket.instances).toHaveLength(39)
    expect(alarms.create).toHaveBeenCalledOnce()
  })
})
