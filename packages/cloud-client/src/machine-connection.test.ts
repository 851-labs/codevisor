import {
  CLOUD_PROTOCOL_VERSION,
  decodeMachineToHub,
  encodeCloudFrame,
  type HubToMachine,
  type MachineToHub,
  type RelayFrame
} from "@codevisor/api"
import { generateDeviceKeyPair, openChannel, openJson, sealJson } from "@codevisor/cloud-crypto"
import { describe, expect, it, vi } from "vitest"
import {
  CloudMachineConnection,
  makePeerKeyPinStore,
  reconnectDelayMs,
  type CloudSocket,
  type IncomingChannel,
  type MachineDisconnectReason,
  type MachineConnectionState,
  type PeerKeyPinStore
} from "./index.js"

class FakeSocket implements CloudSocket {
  sent: MachineToHub[] = []
  closed: { code?: number; reason?: string } | undefined
  terminated = false
  sendError: Error | undefined
  onSend: ((frame: MachineToHub) => void) | undefined
  onopen: (() => void) | null = null
  onmessage: ((data: string) => void) | null = null
  onclose: ((code: number) => void) | null = null

  send(data: string): void {
    if (this.sendError !== undefined) throw this.sendError
    const frame = decodeMachineToHub(data)
    this.sent.push(frame)
    this.onSend?.(frame)
  }

  close(code?: number, reason?: string): void {
    this.closed = code !== undefined ? { code, ...(reason !== undefined ? { reason } : {}) } : {}
  }

  terminate(): void {
    this.terminated = true
  }

  receive(frame: HubToMachine): void {
    this.onmessage?.(encodeCloudFrame(frame))
  }
}

interface ScheduledTimeout {
  delayMs: number
  cancelled: boolean
  fired: boolean
  run(): void
  invoke(): void
}

const machineKeys = generateDeviceKeyPair()

const credentials = {
  serverUrl: "https://cloud.example",
  deviceId: "machine-1",
  publicKey: machineKeys.publicKey,
  secretKey: machineKeys.secretKey,
  apiKey: "api-key"
}

interface Harness {
  connection: CloudMachineConnection
  sockets: FakeSocket[]
  urls: string[]
  headers: Record<string, string>[]
  states: MachineConnectionState[]
  reconnects: { callback: () => void; delayMs: number }[]
  timeouts: ScheduledTimeout[]
  disconnects: MachineDisconnectReason[]
  channels: IncomingChannel[]
}

const harness = (
  overrides: {
    handlers?: Record<string, (channel: IncomingChannel) => void>
    device?: { name: string; os?: string; appVersion?: string }
    peerKeyPins?: PeerKeyPinStore
    onPeerKeyMismatch?: (info: { deviceId: string; pinned: string; presented: string }) => void
  } = {}
): Harness => {
  const sockets: FakeSocket[] = []
  const urls: string[] = []
  const headers: Record<string, string>[] = []
  const states: MachineConnectionState[] = []
  const reconnects: { callback: () => void; delayMs: number }[] = []
  const timeouts: ScheduledTimeout[] = []
  const disconnects: MachineDisconnectReason[] = []
  const channels: IncomingChannel[] = []
  const connection = new CloudMachineConnection({
    credentials,
    device: overrides.device ?? { name: "vps", os: "linux", appVersion: "1.0.0" },
    socketFactory: (url, requestHeaders) => {
      urls.push(url)
      headers.push(requestHeaders)
      const socket = new FakeSocket()
      sockets.push(socket)
      return socket
    },
    channelHandlers: overrides.handlers ?? { echo: (channel) => channels.push(channel) },
    ...(overrides.peerKeyPins === undefined ? {} : { peerKeyPins: overrides.peerKeyPins }),
    ...(overrides.onPeerKeyMismatch === undefined
      ? {}
      : { onPeerKeyMismatch: overrides.onPeerKeyMismatch }),
    onStateChange: (state) => states.push(state),
    onDisconnect: (reason) => disconnects.push(reason),
    scheduleReconnect: (callback, delayMs) => reconnects.push({ callback, delayMs }),
    scheduleTimeout: (callback, delayMs) => {
      const timeout: ScheduledTimeout = {
        delayMs,
        cancelled: false,
        fired: false,
        run: () => {
          if (timeout.cancelled || timeout.fired) return
          timeout.invoke()
        },
        invoke: () => {
          if (timeout.fired) return
          timeout.fired = true
          callback()
        }
      }
      timeouts.push(timeout)
      return () => {
        timeout.cancelled = true
      }
    },
    random: () => 0.5
  })
  return {
    connection,
    sockets,
    urls,
    headers,
    states,
    reconnects,
    timeouts,
    disconnects,
    channels
  }
}

const activeTimeout = (h: Harness, delayMs: number): ScheduledTimeout => {
  const timeout = h.timeouts.find(
    (candidate) => candidate.delayMs === delayMs && !candidate.cancelled && !candidate.fired
  )
  if (timeout === undefined) throw new Error(`No active ${delayMs}ms timeout`)
  return timeout
}

const connect = (h: Harness): FakeSocket => {
  h.connection.start()
  const socket = h.sockets.at(-1)!
  socket.onopen?.()
  socket.receive({ t: "welcome", protocol: CLOUD_PROTOCOL_VERSION, connectionId: "conn-m" })
  return socket
}

/// Simulates the app side of a channel open, returning the opener's cipher.
const openEcho = (
  socket: FakeSocket,
  peerId: string,
  channelId: string,
  params: unknown = { hello: true },
  identity: { appKeys?: ReturnType<typeof generateDeviceKeyPair>; peerDeviceId?: string } = {}
) => {
  const appKeys = identity.appKeys ?? generateDeviceKeyPair()
  const opened = openChannel(appKeys.secretKey, machineKeys.publicKey)
  socket.receive({
    t: "relay",
    peerId,
    peerPublicKey: appKeys.publicKey,
    ...(identity.peerDeviceId === undefined ? {} : { peerDeviceId: identity.peerDeviceId }),
    frame: {
      t: "open",
      channelId,
      seq: 0,
      ephemeralKey: opened.ephemeralPublicKey,
      sealed: sealJson(opened.cipher, channelId, "opener-to-responder", 0, {
        channelType: "echo",
        params
      })
    }
  })
  return { appKeys, opened }
}

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
    // Frames for unknown channels are dropped.
    second.receive({
      t: "relay",
      peerId: "peer-x",
      frame: { t: "credit", channelId: "nope", seq: 0, bytes: 1 }
    })
    expect(h.connection.state).toBe("connected")
  })
})

describe("incoming channels", () => {
  it("accepts an open, decrypts params, and round-trips sealed data", () => {
    const h = harness()
    const socket = connect(h)
    const { opened } = openEcho(socket, "peer-1", "ch-1", { terminalId: "t1" })
    const channel = h.channels[0]!
    expect(channel.channelType).toBe("echo")
    expect(channel.params).toEqual({ terminalId: "t1" })

    const received: unknown[] = []
    channel.onData = (value) => received.push(value)
    socket.receive({
      t: "relay",
      peerId: "peer-1",
      frame: {
        t: "data",
        channelId: "ch-1",
        seq: 1,
        sealed: sealJson(opened.cipher, "ch-1", "opener-to-responder", 1, { input: "ls\n" })
      }
    })
    expect(received).toEqual([{ input: "ls\n" }])

    channel.send({ output: "file.txt\n" })
    channel.send({ output: "done\n" })
    const dataFrames = socket.sent
      .filter((f): f is Extract<MachineToHub, { t: "relay" }> => f.t === "relay")
      .map((f) => f.frame)
      .filter((f): f is Extract<RelayFrame, { t: "data" }> => f.t === "data")
    expect(dataFrames.map((f) => f.seq)).toEqual([0, 1])
    expect(
      openJson(opened.cipher, "ch-1", "responder-to-opener", 0, dataFrames[0]!.sealed)
    ).toEqual({ output: "file.txt\n" })

    const credits: number[] = []
    channel.onCredit = (bytes) => credits.push(bytes)
    socket.receive({
      t: "relay",
      peerId: "peer-1",
      frame: { t: "credit", channelId: "ch-1", seq: 2, bytes: 4096 }
    })
    expect(credits).toEqual([4096])

    const closes: string[] = []
    channel.onClosed = (reason) => closes.push(reason)
    socket.receive({
      t: "relay",
      peerId: "peer-1",
      frame: { t: "close", channelId: "ch-1", seq: 3, reason: "done" }
    })
    expect(closes).toEqual(["done"])
    // Every outbound operation after close is a no-op: still just the two data frames.
    channel.send({ late: true })
    expect(channel.sendBytes(new Uint8Array([1]))).toBeUndefined()
    channel.deferInboundCredit()
    channel.grantCredit(1)
    expect(socket.sent.filter((f) => f.t === "relay")).toHaveLength(2)
  })

  it("relays opaque bytes with explicit receive credit", () => {
    const channels: IncomingChannel[] = []
    const h = harness({
      handlers: {
        echo: (channel) => {
          channels.push(channel)
          channel.deferInboundCredit()
          channel.grantCredit(100)
        }
      }
    })
    const socket = connect(h)
    const { opened } = openEcho(socket, "peer-1", "ch-bytes")
    const channel = channels[0]!
    const received: { bytes: number[]; cost: number }[] = []
    channel.onBytes = (bytes, cost) => received.push({ bytes: [...bytes], cost })

    const sealed = opened.cipher.seal(
      "ch-bytes",
      "opener-to-responder",
      1,
      new Uint8Array([0, 1, 255])
    )
    socket.receive({
      t: "relay",
      peerId: "peer-1",
      frame: { t: "data", channelId: "ch-bytes", seq: 1, sealed }
    })
    expect(received).toEqual([{ bytes: [0, 1, 255], cost: sealed.box.length }])

    const sentCost = channel.sendBytes(new Uint8Array([9, 8, 7]))
    const relayFrames = socket.sent
      .filter((frame): frame is Extract<MachineToHub, { t: "relay" }> => frame.t === "relay")
      .map((frame) => frame.frame)
    expect(relayFrames[0]).toEqual({
      t: "credit",
      channelId: "ch-bytes",
      seq: 0,
      bytes: 100
    })
    const response = relayFrames[1] as Extract<RelayFrame, { t: "data" }>
    expect(response.seq).toBe(1)
    expect(sentCost).toBe(response.sealed.box.length)
    expect([
      ...opened.cipher.open("ch-bytes", "responder-to-opener", response.seq, response.sealed)
    ]).toEqual([9, 8, 7])
  })

  it("closes a byte channel that exceeds its granted receive window", () => {
    const channels: IncomingChannel[] = []
    const h = harness({
      handlers: {
        echo: (channel) => {
          channels.push(channel)
          channel.deferInboundCredit()
          channel.grantCredit(1)
          channel.onBytes = () => undefined
        }
      }
    })
    const socket = connect(h)
    const { opened } = openEcho(socket, "peer-1", "ch-overrun")
    const closes: string[] = []
    channels[0]!.onClosed = (reason) => closes.push(reason)
    socket.receive({
      t: "relay",
      peerId: "peer-1",
      frame: {
        t: "data",
        channelId: "ch-overrun",
        seq: 1,
        sealed: opened.cipher.seal("ch-overrun", "opener-to-responder", 1, new Uint8Array([1]))
      }
    })
    expect(closes).toEqual(["protocol-error"])
    expect((socket.sent.at(-1) as Extract<MachineToHub, { t: "relay" }>).frame).toMatchObject({
      t: "close",
      reason: "protocol-error"
    })
  })

  it("machine-side close notifies the peer once", () => {
    const h = harness()
    const socket = connect(h)
    openEcho(socket, "peer-1", "ch-1")
    const channel = h.channels[0]!
    channel.close("done")
    channel.close("done") // second close is a no-op
    const closeFrames = socket.sent
      .filter((f): f is Extract<MachineToHub, { t: "relay" }> => f.t === "relay")
      .filter((f) => f.frame.t === "close")
    expect(closeFrames).toHaveLength(1)
  })

  it("answers frames for unknown channels with a peer-disconnected close", () => {
    const h = harness()
    const socket = connect(h)
    const closeFrames = () =>
      socket.sent
        .filter((f): f is Extract<MachineToHub, { t: "relay" }> => f.t === "relay")
        .map((f) => f.frame)
        .filter((f): f is Extract<RelayFrame, { t: "close" }> => f.t === "close")

    // The app kept this channel alive across a machine reconnect: we never saw
    // its open, so its frames must be answered with a close — not dropped —
    // or the app waits forever on a channel we no longer know about.
    socket.receive({
      t: "relay",
      peerId: "peer-1",
      frame: { t: "credit", channelId: "ch-lost", seq: 7, bytes: 1024 }
    })
    expect(closeFrames()).toHaveLength(1)
    expect(closeFrames()[0]!.channelId).toBe("ch-lost")
    expect(closeFrames()[0]!.reason).toBe("peer-disconnected")

    // Data frames get the same treatment (the check precedes decryption).
    socket.receive({
      t: "relay",
      peerId: "peer-1",
      frame: { t: "data", channelId: "ch-lost-2", seq: 3, sealed: { box: "AAAA" } }
    })
    expect(closeFrames()).toHaveLength(2)
    expect(closeFrames()[1]!.channelId).toBe("ch-lost-2")
    expect(closeFrames()[1]!.reason).toBe("peer-disconnected")

    // A close for an unknown channel is ignored — no close-for-close loops.
    socket.receive({
      t: "relay",
      peerId: "peer-1",
      frame: { t: "close", channelId: "ch-lost-3", seq: 0, reason: "done" }
    })
    expect(closeFrames()).toHaveLength(2)
  })

  it("refuses malformed opens", () => {
    const h = harness({
      handlers: { echo: () => undefined }
    })
    const socket = connect(h)
    const appKeys = generateDeviceKeyPair()
    const opened = openChannel(appKeys.secretKey, machineKeys.publicKey)
    const sealedOpen = (channelType: unknown, channelId: string) =>
      sealJson(opened.cipher, channelId, "opener-to-responder", 0, { channelType })
    const lastClose = () =>
      (socket.sent.at(-1) as Extract<MachineToHub, { t: "relay" }>).frame as Extract<
        RelayFrame,
        { t: "close" }
      >

    // Open relayed without the peer's public key.
    socket.receive({
      t: "relay",
      peerId: "p",
      frame: {
        t: "open",
        channelId: "c1",
        seq: 0,
        ephemeralKey: opened.ephemeralPublicKey,
        sealed: sealedOpen("echo", "c1")
      }
    })
    expect(lastClose().reason).toBe("protocol-error")

    // Undecryptable open payload.
    socket.receive({
      t: "relay",
      peerId: "p",
      peerPublicKey: appKeys.publicKey,
      frame: {
        t: "open",
        channelId: "c2",
        seq: 0,
        ephemeralKey: opened.ephemeralPublicKey,
        sealed: { box: "AAAA" }
      }
    })
    expect(lastClose().reason).toBe("crypto-error")

    // Non-string channelType.
    socket.receive({
      t: "relay",
      peerId: "p",
      peerPublicKey: appKeys.publicKey,
      frame: {
        t: "open",
        channelId: "c3",
        seq: 0,
        ephemeralKey: opened.ephemeralPublicKey,
        sealed: sealedOpen(42, "c3")
      }
    })
    expect(lastClose().reason).toBe("protocol-error")

    // Unknown channel type.
    socket.receive({
      t: "relay",
      peerId: "p",
      peerPublicKey: appKeys.publicKey,
      frame: {
        t: "open",
        channelId: "c4",
        seq: 0,
        ephemeralKey: opened.ephemeralPublicKey,
        sealed: sealJson(opened.cipher, "c4", "opener-to-responder", 0, {
          channelType: "screensaver"
        })
      }
    })
    expect(lastClose().reason).toBe("unsupported")
  })

  it("refuses duplicate channel ids per peer", () => {
    const h = harness()
    const socket = connect(h)
    openEcho(socket, "peer-1", "ch-1")
    openEcho(socket, "peer-1", "ch-1")
    const closeFrames = socket.sent
      .filter((f): f is Extract<MachineToHub, { t: "relay" }> => f.t === "relay")
      .filter((f) => f.frame.t === "close")
    expect(closeFrames).toHaveLength(1)
    expect(h.channels).toHaveLength(1)
  })

  it("kills channels on seq gaps and crypto failures", () => {
    const h = harness()
    const socket = connect(h)
    const first = openEcho(socket, "peer-1", "ch-gap")
    const gapCloses: string[] = []
    h.channels[0]!.onClosed = (reason) => gapCloses.push(reason)
    socket.receive({
      t: "relay",
      peerId: "peer-1",
      frame: {
        t: "data",
        channelId: "ch-gap",
        seq: 5, // expected 1
        sealed: sealJson(first.opened.cipher, "ch-gap", "opener-to-responder", 5, {})
      }
    })
    expect(gapCloses).toEqual(["protocol-error"])

    openEcho(socket, "peer-1", "ch-bad")
    const badCloses: string[] = []
    h.channels[1]!.onClosed = (reason) => badCloses.push(reason)
    socket.receive({
      t: "relay",
      peerId: "peer-1",
      frame: {
        t: "data",
        channelId: "ch-bad",
        seq: 1,
        sealed: { box: "AAAA" }
      }
    })
    expect(badCloses).toEqual(["crypto-error"])
  })

  it("keeps the channel alive across interleaved credit frames (shared seq counter)", () => {
    // The keystroke-echo pattern: apps allocate credit seqs from the same
    // opener→responder counter as data seqs, so data(1), credit(2), data(3)
    // is a healthy channel — not a gap.
    const h = harness()
    const socket = connect(h)
    const { opened } = openEcho(socket, "peer-1", "ch-credit")
    const channel = h.channels[0]!
    const received: unknown[] = []
    const closes: string[] = []
    channel.onData = (value) => received.push(value)
    channel.onClosed = (reason) => closes.push(reason)
    socket.receive({
      t: "relay",
      peerId: "peer-1",
      frame: {
        t: "data",
        channelId: "ch-credit",
        seq: 1,
        sealed: sealJson(opened.cipher, "ch-credit", "opener-to-responder", 1, { key: "a" })
      }
    })
    socket.receive({
      t: "relay",
      peerId: "peer-1",
      frame: { t: "credit", channelId: "ch-credit", seq: 2, bytes: 64 }
    })
    socket.receive({
      t: "relay",
      peerId: "peer-1",
      frame: {
        t: "data",
        channelId: "ch-credit",
        seq: 3,
        sealed: sealJson(opened.cipher, "ch-credit", "opener-to-responder", 3, { key: "b" })
      }
    })
    expect(received).toEqual([{ key: "a" }, { key: "b" }])
    expect(closes).toEqual([])
  })

  it("kills channels on credit seq gaps", () => {
    const h = harness()
    const socket = connect(h)
    openEcho(socket, "peer-1", "ch-credit-gap")
    const closes: string[] = []
    h.channels[0]!.onClosed = (reason) => closes.push(reason)
    socket.receive({
      t: "relay",
      peerId: "peer-1",
      frame: { t: "credit", channelId: "ch-credit-gap", seq: 4, bytes: 64 } // expected 1
    })
    expect(closes).toEqual(["protocol-error"])
    const refusal = (socket.sent.at(-1) as Extract<MachineToHub, { t: "relay" }>).frame
    expect(refusal).toMatchObject({ t: "close", reason: "protocol-error" })
  })

  it("tears down a peer's channels on peer-gone, leaving others untouched", () => {
    const h = harness()
    const socket = connect(h)
    openEcho(socket, "peer-1", "ch-1")
    openEcho(socket, "peer-2", "ch-1")
    const gone: string[] = []
    h.channels[0]!.onClosed = (reason) => gone.push(`peer-1:${reason}`)
    h.channels[1]!.onClosed = (reason) => gone.push(`peer-2:${reason}`)
    socket.receive({ t: "peer-gone", peerId: "peer-1" })
    expect(gone).toEqual(["peer-1:peer-gone"])
    // Survivor still works.
    h.channels[1]!.send({ still: "alive" })
    expect(socket.sent.filter((f) => f.t === "relay")).toHaveLength(1)
  })

  it("drops all channels when the socket drops", () => {
    const h = harness()
    const socket = connect(h)
    openEcho(socket, "peer-1", "ch-1")
    const closes: string[] = []
    h.channels[0]!.onClosed = (reason) => closes.push(reason)
    socket.onclose?.(1006)
    expect(closes).toEqual(["peer-gone"])
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

describe("peer key pinning", () => {
  const lastClose = (socket: FakeSocket): Extract<RelayFrame, { t: "close" }> => {
    const relay = socket.sent.at(-1) as Extract<MachineToHub, { t: "relay" }>
    return relay.frame as Extract<RelayFrame, { t: "close" }>
  }

  it("pins a key on first successful open and refuses a changed key", () => {
    const persisted: Record<string, string>[] = []
    const pins = makePeerKeyPinStore({ persist: (peers) => persisted.push({ ...peers }) })
    const mismatches: { deviceId: string; pinned: string; presented: string }[] = []
    const h = harness({ peerKeyPins: pins, onPeerKeyMismatch: (info) => mismatches.push(info) })
    const socket = connect(h)

    const first = openEcho(socket, "peer-1", "ch-1", { hello: true }, { peerDeviceId: "app-1" })
    expect(h.channels).toHaveLength(1)
    expect(pins.get("app-1")).toBe(first.appKeys.publicKey)
    expect(persisted).toEqual([{ "app-1": first.appKeys.publicKey }])

    // The same device re-opening with its pinned key stays welcome.
    openEcho(
      socket,
      "peer-1",
      "ch-2",
      { hello: true },
      { appKeys: first.appKeys, peerDeviceId: "app-1" }
    )
    expect(h.channels).toHaveLength(2)

    // A different key under the pinned device id is a substitution: refused
    // before any key agreement, and reported.
    const attacker = generateDeviceKeyPair()
    openEcho(
      socket,
      "peer-2",
      "ch-3",
      { hello: true },
      { appKeys: attacker, peerDeviceId: "app-1" }
    )
    expect(h.channels).toHaveLength(2)
    expect(lastClose(socket)).toMatchObject({ t: "close", channelId: "ch-3", reason: "rejected" })
    expect(mismatches).toEqual([
      { deviceId: "app-1", pinned: first.appKeys.publicKey, presented: attacker.publicKey }
    ])
    expect(pins.get("app-1")).toBe(first.appKeys.publicKey)
  })

  it("refuses silently when no mismatch listener is registered", () => {
    const pins = makePeerKeyPinStore({ initial: { "app-1": "pinned-key" } })
    const h = harness({ peerKeyPins: pins })
    const socket = connect(h)
    openEcho(socket, "peer-1", "ch-1", { hello: true }, { peerDeviceId: "app-1" })
    expect(h.channels).toHaveLength(0)
    expect(lastClose(socket)).toMatchObject({ t: "close", reason: "rejected" })
  })

  it("never pins a key from an open that fails crypto", () => {
    const pins = makePeerKeyPinStore({})
    const h = harness({ peerKeyPins: pins })
    const socket = connect(h)

    // The presented public key does not match the sealing secret: the sealed
    // payload cannot decrypt, so nothing gets pinned for the device.
    const sealer = generateDeviceKeyPair()
    const presented = generateDeviceKeyPair()
    const opened = openChannel(sealer.secretKey, machineKeys.publicKey)
    socket.receive({
      t: "relay",
      peerId: "peer-1",
      peerPublicKey: presented.publicKey,
      peerDeviceId: "app-1",
      frame: {
        t: "open",
        channelId: "ch-1",
        seq: 0,
        ephemeralKey: opened.ephemeralPublicKey,
        sealed: sealJson(opened.cipher, "ch-1", "opener-to-responder", 0, { channelType: "echo" })
      }
    })
    expect(lastClose(socket)).toMatchObject({ t: "close", reason: "crypto-error" })
    expect(pins.get("app-1")).toBeUndefined()

    // The legitimate device can still establish its pin afterwards.
    const legit = openEcho(socket, "peer-1", "ch-2", { hello: true }, { peerDeviceId: "app-1" })
    expect(h.channels).toHaveLength(1)
    expect(pins.get("app-1")).toBe(legit.appKeys.publicKey)
  })

  it("opens without a device id (older hubs) proceed unpinned", () => {
    const pins = makePeerKeyPinStore({ initial: { "app-1": "pinned-key" } })
    const h = harness({ peerKeyPins: pins })
    const socket = connect(h)
    openEcho(socket, "peer-1", "ch-1")
    expect(h.channels).toHaveLength(1)
    expect(pins.get("app-1")).toBe("pinned-key")
  })
})
