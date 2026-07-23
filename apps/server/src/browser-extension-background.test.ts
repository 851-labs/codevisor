import { readFile } from "node:fs/promises"
import { join } from "node:path"
import { runInNewContext } from "node:vm"
import { describe, expect, it, vi } from "vitest"

type Listener = (...arguments_: ReadonlyArray<unknown>) => void

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
    this.emit("open")
  }

  error() {
    this.emit("error")
  }

  close() {
    if (this.readyState === FakeWebSocket.CLOSED) return
    this.readyState = FakeWebSocket.CLOSED
    this.emit("close")
  }

  private emit(type: string) {
    const property = this[`on${type}` as "onmessage" | "onclose" | "onerror"]
    property?.()
    for (const listener of this.listeners.get(type) ?? []) listener()
  }
}

const flushPromises = async () => {
  await Promise.resolve()
  await Promise.resolve()
  await new Promise<void>((resolve) => setImmediate(resolve))
}

describe("browser extension background connection", () => {
  it("keeps one socket active, schedules durable retries, and supports manual reconnect", async () => {
    FakeWebSocket.instances.splice(0)
    const runtimeMessage = event()
    const alarm = event()
    const debuggerEvent = event()
    const debuggerDetach = event()
    const tabCreated = event()
    const tabRemoved = event()
    const downloadCreated = event()
    const downloadChanged = event()
    const alarms = {
      clear: vi.fn(async () => true),
      create: vi.fn(async () => undefined),
      onAlarm: alarm
    }
    const scheduledTimers = new Map<number, Listener>()
    let nextTimer = 1
    const source = await readFile(
      join(process.cwd(), "resources", "browser-extension", "background.js"),
      "utf8"
    )

    runInNewContext(source, {
      CODEVISOR_RELAY: "ws://127.0.0.1:49361/relay",
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
      importScripts: vi.fn(),
      setInterval: vi.fn(() => 1),
      setTimeout: (listener: Listener) => {
        const timer = nextTimer++
        scheduledTimers.set(timer, listener)
        return timer
      },
      self: { addEventListener: vi.fn() }
    })

    expect(FakeWebSocket.instances).toHaveLength(1)
    const first = FakeWebSocket.instances[0]!
    first.error()
    await flushPromises()

    expect(alarms.create).toHaveBeenCalledOnce()
    expect(FakeWebSocket.instances).toHaveLength(1)

    alarm.emit({ name: "codevisor-reconnect" })
    expect(FakeWebSocket.instances).toHaveLength(2)
    alarm.emit({ name: "codevisor-reconnect" })
    expect(FakeWebSocket.instances).toHaveLength(2)

    const second = FakeWebSocket.instances[1]!
    second.open()
    await flushPromises()

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
})
