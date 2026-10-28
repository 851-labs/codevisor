import { EventEmitter } from "node:events"

import { afterEach, describe, expect, it, vi } from "vitest"
import { WebSocket } from "ws"

import {
  BROWSER_HOST_HANDSHAKE_MS,
  chosenBrowserHost,
  makeBrowserHostRegistry,
  probedBrowserHost,
  type BrowserHostSocket
} from "./browser-host-registry.js"
import { recordOrEmpty } from "./unknown-values.js"

interface AppAnswer {
  readonly available: boolean
  readonly showing?: boolean
  readonly focused?: boolean
}

class FakeHostSocket extends EventEmitter implements BrowserHostSocket {
  readyState: number = WebSocket.OPEN
  readonly sent: Array<{ header: Record<string, unknown>; body?: string }> = []
  closedWith: number | undefined

  constructor(public answer: AppAnswer | "silent" = { available: true }) {
    super()
  }

  send(data: string): void {
    const newline = data.indexOf("\n")
    const header = recordOrEmpty(JSON.parse(newline === -1 ? data : data.slice(0, newline)))
    const body = newline === -1 ? undefined : data.slice(newline + 1)
    this.sent.push({ header, ...(body === undefined ? {} : { body }) })
    if (body === undefined || this.answer === "silent") return
    const command = recordOrEmpty(JSON.parse(body))
    if (command.method === "Codevisor.connect")
      this.fromApp(
        { type: "data", channel: header.channel },
        JSON.stringify({ id: command.id, result: this.answer })
      )
  }

  close(code?: number): void {
    this.closedWith = code
    this.readyState = WebSocket.CLOSED
    this.emit("close")
  }

  fromApp(header: Record<string, unknown>, body?: string): void {
    this.emit(
      "message",
      Buffer.from(`${JSON.stringify(header)}${body === undefined ? "" : `\n${body}`}`)
    )
  }

  hello(hostId: string, name: string, idleMs?: number): this {
    this.fromApp({ type: "hello", hostId, name, ...(idleMs === undefined ? {} : { idleMs }) })
    return this
  }

  channelsClosed(): number {
    return this.sent.filter((frame) => frame.header.type === "close").length
  }
}

const connectedHost = async (
  registry: ReturnType<typeof makeBrowserHostRegistry>,
  sessionId: string
) => {
  const connected = await registry.connect(sessionId)
  if (connected.connection === undefined) throw new Error(connected.reason)
  return connected
}

afterEach(() => {
  vi.useRealTimers()
})

describe("browser host registry", () => {
  it("routes to the Mac app whose window shows the chat, not the one used last", async () => {
    let clock = 0
    const registry = makeBrowserHostRegistry(() => clock)
    const studio = new FakeHostSocket({ available: true, showing: true })
    const macbook = new FakeHostSocket({ available: true })
    registry.accept(studio)
    registry.accept(macbook)
    expect(registry.hosts()).toEqual([])
    studio.hello("studio", "Mac Studio")
    clock = 10
    macbook.hello("macbook", "MacBook Pro")
    macbook.fromApp({ type: "activity" })

    const connected = await connectedHost(registry, "chat")
    expect(connected).toMatchObject({ host: { name: "Mac Studio" }, showing: true })
    expect(connected.probes.map(({ host, answer }) => [host.name, answer])).toEqual([
      ["Mac Studio", "showing"],
      ["MacBook Pro", "available"]
    ])
    expect(macbook.channelsClosed()).toBe(1)
    expect(studio.channelsClosed()).toBe(0)

    const channel = studio.sent.find((frame) => frame.header.type === "open")?.header.channel
    const reply = connected.connection.send("Target.getTargets")
    const request = recordOrEmpty(JSON.parse(studio.sent.at(-1)?.body ?? "{}"))
    expect(request.method).toBe("Target.getTargets")
    studio.fromApp({ type: "data", channel: "elsewhere" }, "{}")
    studio.fromApp({ type: "unknown" })
    studio.fromApp({ type: "data", channel }, JSON.stringify({ id: request.id, result: { ok: 1 } }))
    await expect(reply).resolves.toEqual({ ok: 1 })

    await connected.connection.close()
    expect(studio.sent.at(-1)?.header).toEqual({ type: "close", channel })
    registry.close()
    expect(registry.lostHost("chat")).toBe("Mac Studio")
    expect(studio.closedWith).toBe(1001)
  })

  it("prefers the focused window, then the chat's current Mac, then the most recent activity", async () => {
    let clock = 100
    const registry = makeBrowserHostRegistry(() => clock)
    const studio = new FakeHostSocket({ available: true })
    const macbook = new FakeHostSocket({ available: true })
    const mini = new FakeHostSocket({ available: true })
    for (const socket of [studio, macbook, mini]) registry.accept(socket)
    studio.hello("studio", "Mac Studio", 50)
    macbook.hello("macbook", "MacBook Pro", 10)
    mini.hello("mini", "Mac mini", 90)

    expect((await connectedHost(registry, "chat")).host.name).toBe("MacBook Pro")
    clock = 200
    studio.fromApp({ type: "activity" })
    expect((await connectedHost(registry, "chat")).host.name).toBe("MacBook Pro")
    expect((await connectedHost(registry, "other")).host.name).toBe("Mac Studio")
    mini.close()
    expect(registry.lostHost("chat")).toBeUndefined()

    macbook.answer = { available: true, showing: true }
    studio.answer = { available: true, showing: true, focused: true }
    expect((await connectedHost(registry, "chat")).host.name).toBe("Mac Studio")
    registry.forgetSession("chat")
    expect(registry.lostHost("chat")).toBeUndefined()
  })

  it("probes every Mac app without keeping a channel open", async () => {
    const registry = makeBrowserHostRegistry()
    const studio = new FakeHostSocket({ available: true, showing: true })
    const macbook = new FakeHostSocket({ available: false })
    registry.accept(studio)
    registry.accept(macbook)
    studio.hello("studio", "Mac Studio")
    macbook.hello("macbook", "MacBook Pro")

    const probes = await registry.probe("chat")
    expect(probes.map(({ host, answer }) => [host.name, answer])).toEqual([
      ["Mac Studio", "showing"],
      ["MacBook Pro", "unavailable"]
    ])
    expect(chosenBrowserHost(probes)).toEqual({ id: "studio", name: "Mac Studio", showing: true })
    expect(studio.channelsClosed()).toBe(1)
    expect(macbook.channelsClosed()).toBe(1)
    expect(chosenBrowserHost(probes.slice(1))).toBeUndefined()
    expect(probedBrowserHost(probes, "macbook")).toBeUndefined()
    expect(probedBrowserHost(probes, "gone")).toBeUndefined()
    expect(probedBrowserHost(probes, "studio")?.showing).toBe(true)
    expect(chosenBrowserHost([])).toBeUndefined()
  })

  it("reports lost tabs when the chat's Mac app disconnects, until the chat reconnects", async () => {
    const registry = makeBrowserHostRegistry()
    const studio = new FakeHostSocket()
    registry.accept(studio)
    studio.hello("studio", "Mac Studio")
    const connected = await connectedHost(registry, "chat")

    studio.close()
    expect(connected.connection.closed).toBe(true)
    expect(registry.lostHost("chat")).toBe("Mac Studio")
    await expect(registry.connect("chat")).resolves.toEqual({
      reason: "No Codevisor Mac app is connected to this server.",
      probes: []
    })

    const macbook = new FakeHostSocket()
    registry.accept(macbook)
    macbook.hello("macbook", "MacBook Pro")
    expect(registry.lostHost("chat")).toBe("Mac Studio")
    expect((await connectedHost(registry, "chat")).host.name).toBe("MacBook Pro")
    expect(registry.lostHost("chat")).toBeUndefined()
  })

  it("names every Mac app that refuses, ignores, or drops the channel", async () => {
    vi.useFakeTimers()
    const registry = makeBrowserHostRegistry()
    const refused = new FakeHostSocket({ available: false })
    const silent = new FakeHostSocket("silent")
    const dropped = new FakeHostSocket("silent")
    for (const socket of [refused, silent, dropped]) registry.accept(socket)
    refused.hello("refused", "")
    silent.hello("silent", "Mac Studio")
    dropped.hello("dropped", "MacBook Pro")

    const pending = registry.connect("chat")
    const channel = dropped.sent.find((frame) => frame.header.type === "open")?.header.channel
    dropped.fromApp({ type: "close", channel })
    await vi.advanceTimersByTimeAsync(BROWSER_HOST_HANDSHAKE_MS)
    const failed = await pending
    for (const reason of [
      "The Codevisor app on Mac can't open this chat.",
      "The Codevisor app on Mac Studio did not respond. Check that Mac for a blocking dialog.",
      "The Codevisor app on MacBook Pro disconnected."
    ])
      expect(failed.reason).toContain(reason)
    expect(failed.probes.map(({ answer }) => answer).toSorted()).toEqual([
      "disconnected",
      "unavailable",
      "unresponsive"
    ])
  })

  it("closes sockets that never introduce themselves and replaces a reconnecting Mac app", async () => {
    vi.useFakeTimers()
    const registry = makeBrowserHostRegistry()
    const wrong = new FakeHostSocket()
    registry.accept(wrong)
    wrong.emit("message", Buffer.from("not json"))
    expect(wrong.closedWith).toBe(1008)

    const quiet = new FakeHostSocket()
    registry.accept(quiet)
    await vi.advanceTimersByTimeAsync(BROWSER_HOST_HANDSHAKE_MS)
    expect(quiet.closedWith).toBe(1008)

    const first = new FakeHostSocket()
    registry.accept(first)
    first.hello("studio", "Mac Studio")
    const second = new FakeHostSocket()
    registry.accept(second)
    second.hello("studio", "Mac Studio")
    first.close()
    expect(registry.hosts()).toHaveLength(1)
    const connected = await registry.connect("chat")
    expect(connected.host?.id).toBe("studio")
    expect(second.sent.some((frame) => frame.header.type === "open")).toBe(true)
  })
})
