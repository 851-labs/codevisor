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
  readonly sent: unknown[] = []
  private sendWaiters: Array<() => void> = []
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

  send(data: string) {
    const parsed: unknown = JSON.parse(data)
    this.sent.push(parsed)
    for (const resolve of this.sendWaiters.splice(0)) resolve()
  }

  nextSend(): Promise<void> {
    return new Promise((resolve) => this.sendWaiters.push(resolve))
  }

  message(data: Record<string, unknown>) {
    for (const listener of this.listeners.get("message") ?? []) {
      listener({ data: JSON.stringify(data) })
    }
  }

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
  const tabsQueried = Promise.withResolvers<void>()
  const tabs = {
    create: vi.fn(async ({ url }: { url: string }) => ({ id: 7, windowId: 3, url })),
    query: vi.fn(async () => {
      tabsQueried.resolve()
      return []
    }),
    update: vi.fn(async (id: number) => ({ id, windowId: 3 })),
    onCreated: tabCreated,
    onRemoved: tabRemoved
  }
  const windows = { update: vi.fn(async () => ({})) }
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
      tabs,
      windows
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
  return {
    alarm,
    alarms,
    tabs,
    importScripts,
    retryScheduled,
    runtimeMessage,
    tabCreated,
    tabsQueried,
    windows
  }
}

const isTargetCreated = (sent: unknown): boolean =>
  typeof sent === "object" &&
  sent !== null &&
  "method" in sent &&
  sent.method === "Target.targetCreated"

const connectedBackground = async () => {
  const background = await startBackground("ws://127.0.0.1:51000/relay")
  const socket = FakeWebSocket.instances[0]!
  await socket.open()
  await background.tabsQueried.promise
  await Promise.resolve()
  const command = async (id: number, method: string, params: Record<string, unknown>) => {
    const replied = socket.nextSend()
    socket.message({ id, method, params })
    await replied
    return socket.sent.at(-1)
  }
  return { ...background, command, socket }
}

describe("browser extension background tabs", () => {
  it("adopts popups from a Codevisor tab but not new tabs the user opens from it", async () => {
    const { command, socket, tabCreated } = await connectedBackground()
    expect(await command(1, "Target.createTarget", { url: "https://form.test/" })).toEqual({
      id: 1,
      result: { targetId: "7" }
    })

    tabCreated.emit({ id: 8, openerTabId: 7, url: "", pendingUrl: "chrome://newtab/" })
    tabCreated.emit({ id: 9, openerTabId: 7, pendingUrl: "https://popup.test/" })

    expect(socket.sent.filter((sent) => isTargetCreated(sent))).toEqual([
      {
        method: "Target.targetCreated",
        params: {
          targetInfo: {
            targetId: "9",
            type: "page",
            title: "",
            url: "https://popup.test/",
            openerId: "7"
          }
        }
      }
    ])
  })

  it("brings a shared tab to the front in a focused window", async () => {
    const { command, tabs, windows } = await connectedBackground()
    await command(1, "Target.createTarget", { url: "https://form.test/" })

    expect(await command(2, "Target.activateTarget", { targetId: "7" })).toEqual({
      id: 2,
      result: {}
    })
    expect(tabs.update).toHaveBeenCalledWith(7, { active: true })
    expect(windows.update).toHaveBeenCalledWith(3, { focused: true })

    expect(await command(3, "Target.activateTarget", { targetId: "8" })).toEqual({
      id: 3,
      error: { message: "That tab is not shared with Codevisor" }
    })
    expect(tabs.update).toHaveBeenCalledOnce()
  })
})

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
    expect(importScripts).toHaveBeenCalledWith(
      "native-relay.js",
      "clipboard-commands.js",
      "history-commands.js"
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
