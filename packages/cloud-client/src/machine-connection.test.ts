import { CLOUD_PROTOCOL_VERSION } from "@codevisor/api"
import type { MachineToHub } from "@codevisor/api"
import { CloudMachineConnection, reconnectDelayMs } from "./index.js"
import { describe, expect, it, vi } from "vitest"
import {
  FakeSocket,
  machineKeys,
  credentials,
  harness,
  activeTimeout,
  connect,
  openEcho
} from "./machine-connection-test-support.js"

describe("connection lifecycle", () => {
  it("connects, greets, and reaches connected", () => {
    const h = harness()
    connect(h)
    expect(h.urls).toEqual(["wss://cloud.example/connect"])
    expect(h.headers[0]).toEqual({ "x-api-key": "api-key" })
    expect(h.sockets[0]!.sent[0]).toEqual({
      t: "hello",
      protocol: CLOUD_PROTOCOL_VERSION,
      device: {
        deviceId: "machine-1",
        kind: "machine",
        name: "vps",
        os: "linux",
        appVersion: "1.0.0",
        publicKey: machineKeys.publicKey
      }
    })
    expect(h.states).toEqual(["connecting", "connected"])
    expect(h.connection.state).toBe("connected")
    // start() while running is a no-op.
    h.connection.start()
    expect(h.sockets).toHaveLength(1)
  })

  it("omits optional device fields", () => {
    const h = harness({ device: { name: "bare" } })
    connect(h)
    const hello = h.sockets[0]!.sent[0] as Extract<MachineToHub, { t: "hello" }>
    expect(hello.device.os).toBeUndefined()
    expect(hello.device.appVersion).toBeUndefined()
  })

  it("reconnects with jittered backoff and resets attempts on welcome", () => {
    const h = harness()
    connect(h)
    h.sockets[0]!.onclose?.(1006)
    expect(h.connection.state).toBe("reconnecting")
    expect(h.reconnects[0]!.delayMs).toBe(250) // 0.5 * 500 * 2^0
    h.reconnects[0]!.callback()
    h.sockets[1]!.onclose?.(1006)
    expect(h.reconnects[1]!.delayMs).toBe(500) // 0.5 * 500 * 2^1
    h.reconnects[1]!.callback()
    const socket = h.sockets[2]!
    socket.onopen?.()
    socket.receive({ t: "welcome", protocol: CLOUD_PROTOCOL_VERSION, connectionId: "c" })
    expect(h.connection.state).toBe("connected")
    socket.onclose?.(1006)
    expect(h.reconnects[2]!.delayMs).toBe(250) // attempts reset by welcome
  })

  it("reconnects when a half-open socket misses its heartbeat pong", () => {
    const h = harness()
    const socket = connect(h)
    openEcho(socket, "peer-1", "ch-1")
    const channelCloses: string[] = []
    h.channels[0]!.onClosed = (reason) => channelCloses.push(reason)
    activeTimeout(h, 30_000).run()
    expect(socket.sent.at(-1)).toEqual({ t: "ping" })

    activeTimeout(h, 10_000).run()
    expect(socket.terminated).toBe(true)
    expect(channelCloses).toEqual(["peer-gone"])
    expect(h.disconnects).toEqual([{ kind: "heartbeat-timeout" }])
    expect(h.connection.state).toBe("reconnecting")
    expect(h.reconnects).toHaveLength(1)
    expect(h.reconnects[0]!.delayMs).toBe(250)

    // Reconnect does not depend on the zombie socket ever emitting close.
    h.reconnects[0]!.callback()
    expect(h.sockets).toHaveLength(2)
  })

  it("keeps a healthy socket alive while pongs arrive", () => {
    const h = harness()
    const socket = connect(h)
    activeTimeout(h, 30_000).run()
    const firstDeadline = activeTimeout(h, 10_000)
    socket.receive({ t: "pong" })

    expect(firstDeadline.cancelled).toBe(true)
    expect(socket.terminated).toBe(false)
    expect(h.reconnects).toHaveLength(0)
    activeTimeout(h, 30_000).run()
    expect(socket.sent.filter((frame) => frame.t === "ping")).toHaveLength(2)
  })

  it("measures relay RTT from heartbeat ping/pong", () => {
    let now = 10_000
    const h = harness({ now: () => now })
    const socket = connect(h)
    expect(h.connection.lastRttMs).toBeUndefined()

    activeTimeout(h, 30_000).run() // heartbeat ping leaves at t=10s
    now += 42
    socket.receive({ t: "pong" })
    expect(h.connection.lastRttMs).toBe(42)

    // An unsolicited pong never fabricates a measurement.
    now += 100
    socket.receive({ t: "pong" })
    expect(h.connection.lastRttMs).toBe(42)
  })

  it("reconnects when a socket never completes the welcome handshake", () => {
    const h = harness()
    h.connection.start()
    const socket = h.sockets[0]!
    socket.onopen?.()
    activeTimeout(h, 15_000).run()

    expect(socket.terminated).toBe(true)
    expect(h.disconnects).toEqual([{ kind: "welcome-timeout" }])
    expect(h.connection.state).toBe("reconnecting")
    expect(h.reconnects[0]!.delayMs).toBe(250)
  })

  it("reconnects when hello or heartbeat sends fail", () => {
    const hello = harness()
    hello.connection.start()
    hello.sockets[0]!.sendError = new Error("hello failed")
    hello.sockets[0]!.onopen?.()
    expect(hello.sockets[0]!.terminated).toBe(true)
    expect(hello.disconnects).toEqual([{ kind: "send-failed", phase: "hello" }])
    expect(hello.connection.state).toBe("reconnecting")

    const heartbeat = harness()
    const socket = connect(heartbeat)
    socket.sendError = new Error("heartbeat failed")
    activeTimeout(heartbeat, 30_000).run()
    expect(socket.terminated).toBe(true)
    expect(heartbeat.disconnects).toEqual([{ kind: "send-failed", phase: "heartbeat" }])
    expect(heartbeat.connection.state).toBe("reconnecting")
  })

  it("falls back to a graceful close when immediate termination is unavailable", () => {
    const h = harness()
    h.connection.start()
    const socket = h.sockets[0]!
    Reflect.set(socket, "terminate", undefined)
    activeTimeout(h, 15_000).run()

    expect(socket.closed).toEqual({ code: 4001, reason: "welcome-timeout" })
    expect(h.connection.state).toBe("reconnecting")
  })

  it("ignores stale socket and queued liveness callbacks", () => {
    const h = harness()
    h.connection.start()
    const first = h.sockets[0]!
    const staleWelcome = activeTimeout(h, 15_000)
    first.onclose?.(1006)

    // These may already be queued by an event loop when the socket is
    // superseded. None may revive or disturb the detached transport.
    first.onopen?.()
    first.receive({ t: "pong" })
    staleWelcome.invoke()
    expect(h.reconnects).toHaveLength(1)

    h.reconnects[0]!.callback()
    const second = h.sockets[1]!
    second.onopen?.()
    second.receive({ t: "welcome", protocol: CLOUD_PROTOCOL_VERSION, connectionId: "next" })
    const staleHeartbeat = activeTimeout(h, 30_000)
    second.onclose?.(1006)
    staleHeartbeat.invoke()
    expect(h.reconnects).toHaveLength(2)
  })

  it("does not arm a pong deadline after send synchronously closes the socket", () => {
    const h = harness()
    const socket = connect(h)
    socket.onSend = (frame) => {
      if (frame.t === "ping") socket.onclose?.(1006)
    }
    activeTimeout(h, 30_000).run()

    expect(h.reconnects).toHaveLength(1)
    expect(
      h.timeouts.some(
        (timeout) => timeout.delayMs === 10_000 && !timeout.cancelled && !timeout.fired
      )
    ).toBe(false)
  })

  it("treats hub 42xx close codes as fatal", () => {
    const revoked = harness()
    connect(revoked)
    revoked.sockets[0]!.onclose?.(4201)
    expect(revoked.connection.state).toBe("revoked")
    expect(revoked.reconnects).toHaveLength(0)

    const outdated = harness()
    connect(outdated)
    outdated.sockets[0]!.onclose?.(4200)
    expect(outdated.connection.state).toBe("unsupported-protocol")
  })

  it("stops cleanly and ignores the resulting close event", () => {
    const h = harness()
    const socket = connect(h)
    openEcho(socket, "peer-1", "ch-1")
    const closes: string[] = []
    h.channels[0]!.onClosed = (reason) => closes.push(reason)
    h.connection.stop()
    expect(socket.closed?.code).toBe(1000)
    expect(h.connection.state).toBe("stopped")
    expect(closes).toEqual(["peer-gone"])
    expect(h.timeouts.every((timeout) => timeout.cancelled || timeout.fired)).toBe(true)
    socket.onclose?.(1000)
    expect(h.reconnects).toHaveLength(0)
    // stop() twice is a no-op.
    h.connection.stop()
  })

  it("does not reconnect when stopped before the backoff fires", () => {
    const h = harness()
    connect(h)
    h.sockets[0]!.onclose?.(1006)
    expect(h.reconnects).toHaveLength(1)
    h.connection.stop()
    h.reconnects[0]!.callback()
    expect(h.sockets).toHaveLength(1)
  })

  it("ignores stale backoff after the connection is stopped and restarted", () => {
    const h = harness()
    connect(h)
    h.sockets[0]!.onclose?.(1006)
    const staleReconnect = h.reconnects[0]!.callback

    h.connection.stop()
    h.connection.start()
    expect(h.sockets).toHaveLength(2)
    staleReconnect()
    expect(h.sockets).toHaveLength(2)
  })

  it("ignores close events from superseded sockets and stray frames", () => {
    const h = harness()
    const first = connect(h)
    first.onclose?.(1006)
    h.reconnects[0]!.callback()
    const second = h.sockets[1]!
    // The first socket's late close must not trigger another reconnect.
    first.onclose?.(1006)
    expect(h.reconnects).toHaveLength(1)
    second.onopen?.()
    second.receive({ t: "welcome", protocol: CLOUD_PROTOCOL_VERSION, connectionId: "c" })
    second.receive({ t: "pong" })
    second.receive({ t: "error", code: "rate-limited", message: "slow down" })
    // Frames for unknown channels are answered with a close, not a crash.
    second.receiveRelay({
      peerId: "peer-x",
      frame: { t: "credit", channelId: "nope", seq: 0, bytes: 1 }
    })
    // Malformed binary messages and headers are dropped.
    second.onmessage?.(new Uint8Array([0, 0]))
    second.receiveRelay({ frame: { t: "data", channelId: "x", seq: 0 } })
    expect(h.connection.state).toBe("connected")
  })
})

describe("defaults", () => {
  it("falls back to real timers and Math.random for reconnects", () => {
    vi.useFakeTimers()
    const random = vi.spyOn(Math, "random").mockReturnValue(1)
    try {
      const sockets: FakeSocket[] = []
      const connection = new CloudMachineConnection({
        credentials,
        device: { name: "defaults" },
        socketFactory: () => {
          const socket = new FakeSocket()
          sockets.push(socket)
          return socket
        },
        channelHandlers: {}
      })
      connection.start()
      sockets[0]!.onclose?.(1006)
      vi.advanceTimersByTime(501)
      expect(sockets).toHaveLength(2)
      connection.stop()
    } finally {
      random.mockRestore()
      vi.useRealTimers()
    }
  })
})

describe("reconnectDelayMs", () => {
  it("grows exponentially with full jitter and caps", () => {
    expect(reconnectDelayMs(0, () => 1)).toBe(500)
    expect(reconnectDelayMs(3, () => 0.5)).toBe(2000)
    expect(reconnectDelayMs(20, () => 1)).toBe(30_000)
    expect(reconnectDelayMs(2, () => 0)).toBe(0)
    expect(reconnectDelayMs(1, () => 0.25, 1000, 1500)).toBe(375)
  })
})
