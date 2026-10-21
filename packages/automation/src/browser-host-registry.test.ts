import { EventEmitter } from "node:events"

import { afterEach, describe, expect, it, vi } from "vitest"
import { WebSocket } from "ws"

import {
  BROWSER_HOST_HANDSHAKE_MS,
  makeBrowserHostRegistry,
  type BrowserHostSocket
} from "./browser-host-registry.js"
import { recordOrEmpty } from "./unknown-values.js"

class FakeHostSocket extends EventEmitter implements BrowserHostSocket {
  readyState: number = WebSocket.OPEN
  readonly sent: Array<{ header: Record<string, unknown>; body?: string }> = []
  closedWith: number | undefined

  constructor(private readonly available: boolean | "silent" = true) {
    super()
  }

  send(data: string): void {
    const newline = data.indexOf("\n")
    const header = recordOrEmpty(JSON.parse(newline === -1 ? data : data.slice(0, newline)))
    const body = newline === -1 ? undefined : data.slice(newline + 1)
    this.sent.push({ header, ...(body === undefined ? {} : { body }) })
    if (body === undefined || this.available === "silent") return
    const command = recordOrEmpty(JSON.parse(body))
    if (command.method === "Codevisor.connect")
      this.fromApp(
        { type: "data", channel: header.channel },
        JSON.stringify({ id: command.id, result: { available: this.available } })
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

  hello(hostId: string, name: string): this {
    this.fromApp({ type: "hello", hostId, name })
    return this
  }
}

afterEach(() => {
  vi.useRealTimers()
})

describe("browser host registry", () => {
  it("relays CDP over a channel to the most recently active Mac app", async () => {
    let clock = 0
    const registry = makeBrowserHostRegistry(() => clock)
    const studio = new FakeHostSocket()
    const macbook = new FakeHostSocket()
    registry.accept(studio)
    registry.accept(macbook)
    expect(registry.hosts().map((host) => host.name)).toEqual([])

    studio.fromApp({ type: "hello", hostId: "studio", name: "Mac Studio" })
    clock = 2
    macbook.fromApp({ type: "hello", hostId: "macbook", name: "MacBook Pro", idleMs: 5 })
    expect(registry.state("chat").host?.name).toBe("Mac Studio")
    macbook.fromApp({ type: "activity" })
    expect(registry.state("chat").host?.name).toBe("MacBook Pro")
    clock = 3
    studio.fromApp({ type: "activity" })
    expect(registry.state("chat").host?.name).toBe("Mac Studio")

    const connected = await registry.connect("chat")
    if (connected.connection === undefined) throw new Error(connected.reason)
    expect(connected.host.name).toBe("Mac Studio")
    const open = studio.sent.find((frame) => frame.header.type === "open")
    expect(open?.header).toMatchObject({ sessionId: "chat" })
    const channel = open?.header.channel

    const reply = connected.connection.send("Target.getTargets")
    const request = recordOrEmpty(JSON.parse(studio.sent.at(-1)?.body ?? "{}"))
    expect(request.method).toBe("Target.getTargets")
    studio.fromApp({ type: "data", channel: "elsewhere" }, "{}")
    studio.fromApp({ type: "unknown" })
    studio.fromApp({ type: "data", channel }, JSON.stringify({ id: request.id, result: { ok: 1 } }))
    await expect(reply).resolves.toEqual({ ok: 1 })

    clock = 4
    macbook.fromApp({ type: "activity" })
    expect(registry.state("chat").host?.name).toBe("Mac Studio")
    expect(registry.state("other").host?.name).toBe("MacBook Pro")

    await connected.connection.close()
    expect(studio.sent.at(-1)?.header).toEqual({ type: "close", channel })
    expect((await registry.connect("other")).host?.name).toBe("MacBook Pro")
    registry.close()
    expect(registry.state("other")).toEqual({ lostHost: "MacBook Pro" })
    expect(studio.closedWith).toBe(1001)
  })

  it("reports lost tabs when the chat's Mac app disconnects, until the chat reconnects", async () => {
    const registry = makeBrowserHostRegistry()
    const studio = new FakeHostSocket()
    registry.accept(studio)
    studio.hello("studio", "Mac Studio")
    const connected = await registry.connect("chat")
    if (connected.connection === undefined) throw new Error(connected.reason)

    studio.close()
    expect(connected.connection.closed).toBe(true)
    expect(registry.state("chat")).toEqual({ lostHost: "Mac Studio" })
    await expect(registry.connect("chat")).resolves.toEqual({
      reason: "No Codevisor Mac app is connected to this server."
    })

    const macbook = new FakeHostSocket()
    registry.accept(macbook)
    macbook.hello("macbook", "MacBook Pro")
    expect(registry.state("chat")).toMatchObject({ lostHost: "Mac Studio" })
    const moved = await registry.connect("chat")
    expect(moved.host?.name).toBe("MacBook Pro")
    expect(registry.state("chat").lostHost).toBeUndefined()

    registry.forgetSession("chat")
    expect(registry.state("chat").host?.name).toBe("MacBook Pro")
  })

  it("reports a Mac app that refuses, ignores, or drops the channel", async () => {
    vi.useFakeTimers()
    const refusing = makeBrowserHostRegistry()
    const refused = new FakeHostSocket(false)
    refusing.accept(refused)
    refused.hello("studio", "")
    await expect(refusing.connect("chat")).resolves.toEqual({
      reason: "The Codevisor app on Mac can't open this chat."
    })

    const ignoring = makeBrowserHostRegistry()
    const silent = new FakeHostSocket("silent")
    ignoring.accept(silent)
    silent.hello("studio", "Mac Studio")
    const timedOut = ignoring.connect("chat")
    await vi.advanceTimersByTimeAsync(BROWSER_HOST_HANDSHAKE_MS)
    await expect(timedOut).resolves.toEqual({
      reason:
        "The Codevisor app on Mac Studio did not respond. Check that Mac for a blocking dialog."
    })

    const dropping = makeBrowserHostRegistry()
    const dropped = new FakeHostSocket("silent")
    dropping.accept(dropped)
    dropped.hello("studio", "Mac Studio")
    const pending = dropping.connect("chat")
    const channel = dropped.sent.find((frame) => frame.header.type === "open")?.header.channel
    dropped.fromApp({ type: "close", channel })
    await expect(pending).resolves.toEqual({
      reason: "The Codevisor app on Mac Studio disconnected."
    })
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
