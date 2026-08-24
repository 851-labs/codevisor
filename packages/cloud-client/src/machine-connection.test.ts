import {
  CLOUD_PROTOCOL_VERSION,
  decodeMachineToHub,
  decodeRelayEnvelopes,
  encodeCloudFrame,
  encodeRelayEnvelopes,
  type HubToMachine,
  type MachineRelayHeader,
  type MachineToHub,
  type RelayFrameHeader
} from "@codevisor/api"
import { generateDeviceKeyPair, openChannel, openJson, sealJson } from "@codevisor/cloud-crypto"
import { deflateRawSync, inflateRawSync } from "node:zlib"
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

interface SentEnvelope {
  header: MachineRelayHeader
  payload: Uint8Array
}

class FakeSocket implements CloudSocket {
  /// JSON control frames, in order.
  sent: MachineToHub[] = []
  /// Binary relay messages, one entry per WebSocket message (each may carry
  /// several envelopes when the sender coalesces).
  relayMessages: SentEnvelope[][] = []
  closed: { code?: number; reason?: string } | undefined
  terminated = false
  sendError: Error | undefined
  onSend: ((frame: MachineToHub) => void) | undefined
  onopen: (() => void) | null = null
  onmessage: ((data: string | Uint8Array) => void) | null = null
  onclose: ((code: number) => void) | null = null

  send(data: string | Uint8Array): void {
    if (this.sendError !== undefined) throw this.sendError
    if (typeof data === "string") {
      const frame = decodeMachineToHub(data)
      this.sent.push(frame)
      this.onSend?.(frame)
      return
    }
    this.relayMessages.push(
      decodeRelayEnvelopes(data).map((envelope) => ({
        header: envelope.header as MachineRelayHeader,
        payload: new Uint8Array(envelope.payload)
      }))
    )
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

  /// Delivers one hub→machine relay envelope as its own binary message.
  receiveRelay(header: Record<string, unknown>, payload: Uint8Array = new Uint8Array(0)): void {
    this.onmessage?.(encodeRelayEnvelopes([{ header, payload }]))
  }

  /// Every sent relay envelope across all messages, in order.
  get sentRelay(): SentEnvelope[] {
    return this.relayMessages.flat()
  }

  relayFrames(): RelayFrameHeader[] {
    return this.sentRelay.map((envelope) => envelope.header.frame)
  }

  closeFrames(): Extract<RelayFrameHeader, { t: "close" }>[] {
    return this.relayFrames().filter(
      (frame): frame is Extract<RelayFrameHeader, { t: "close" }> => frame.t === "close"
    )
  }

  lastClose(): Extract<RelayFrameHeader, { t: "close" }> {
    const frame = this.closeFrames().at(-1)
    if (frame === undefined) throw new Error("no close frame sent")
    return frame
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
    relayCoalesceMs?: number
    compressPayload?: (bytes: Uint8Array) => Uint8Array | undefined
    decompressPayload?: (bytes: Uint8Array) => Uint8Array
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
    ...(overrides.relayCoalesceMs === undefined
      ? {}
      : { relayCoalesceMs: overrides.relayCoalesceMs }),
    ...(overrides.compressPayload === undefined
      ? {}
      : { compressPayload: overrides.compressPayload }),
    ...(overrides.decompressPayload === undefined
      ? {}
      : { decompressPayload: overrides.decompressPayload }),
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
  identity: {
    appKeys?: ReturnType<typeof generateDeviceKeyPair>
    peerDeviceId?: string
    compress?: boolean
  } = {}
) => {
  const appKeys = identity.appKeys ?? generateDeviceKeyPair()
  const opened = openChannel(appKeys.secretKey, machineKeys.publicKey)
  socket.receiveRelay(
    {
      peerId,
      peerPublicKey: appKeys.publicKey,
      ...(identity.peerDeviceId === undefined ? {} : { peerDeviceId: identity.peerDeviceId }),
      frame: { t: "open", channelId, seq: 0, ephemeralKey: opened.ephemeralPublicKey }
    },
    sealJson(opened.cipher, channelId, "opener-to-responder", 0, {
      channelType: "echo",
      params,
      ...(identity.compress === true ? { compress: true } : {})
    })
  )
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
    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-1", seq: 1 } },
      sealJson(opened.cipher, "ch-1", "opener-to-responder", 1, { input: "ls\n" })
    )
    expect(received).toEqual([{ input: "ls\n" }])

    channel.send({ output: "file.txt\n" })
    channel.send({ output: "done\n" })
    const dataEnvelopes = socket.sentRelay.filter((envelope) => envelope.header.frame.t === "data")
    expect(dataEnvelopes.map((envelope) => envelope.header.frame.seq)).toEqual([0, 1])
    expect(dataEnvelopes.every((envelope) => envelope.header.peerId === "peer-1")).toBe(true)
    expect(
      openJson(opened.cipher, "ch-1", "responder-to-opener", 0, dataEnvelopes[0]!.payload)
    ).toEqual({ output: "file.txt\n" })

    const credits: number[] = []
    channel.onCredit = (bytes) => credits.push(bytes)
    socket.receiveRelay({
      peerId: "peer-1",
      frame: { t: "credit", channelId: "ch-1", seq: 2, bytes: 4096 }
    })
    expect(credits).toEqual([4096])

    const closes: string[] = []
    channel.onClosed = (reason) => closes.push(reason)
    socket.receiveRelay({
      peerId: "peer-1",
      frame: { t: "close", channelId: "ch-1", seq: 3, reason: "done" }
    })
    expect(closes).toEqual(["done"])
    // Every outbound operation after close is a no-op: still just the two data frames.
    channel.send({ late: true })
    expect(channel.sendBytes(new Uint8Array([1]))).toBeUndefined()
    channel.deferInboundCredit()
    channel.grantCredit(1)
    expect(socket.sentRelay).toHaveLength(2)
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

    const box = opened.cipher.seal(
      "ch-bytes",
      "opener-to-responder",
      1,
      new Uint8Array([0, 1, 255])
    )
    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-bytes", seq: 1 } },
      box
    )
    expect(received).toEqual([{ bytes: [0, 1, 255], cost: box.byteLength }])

    const sentCost = channel.sendBytes(new Uint8Array([9, 8, 7]))
    const envelopes = socket.sentRelay
    expect(envelopes[0]!.header.frame).toEqual({
      t: "credit",
      channelId: "ch-bytes",
      seq: 0,
      bytes: 100
    })
    const response = envelopes[1]!
    expect(response.header.frame).toEqual({ t: "data", channelId: "ch-bytes", seq: 1 })
    // Ciphertext cost = plaintext + 16-byte tag, no encoding expansion.
    expect(sentCost).toBe(response.payload.byteLength)
    expect(sentCost).toBe(3 + 16)
    expect([...opened.cipher.open("ch-bytes", "responder-to-opener", 1, response.payload)]).toEqual(
      [9, 8, 7]
    )
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
    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-overrun", seq: 1 } },
      opened.cipher.seal("ch-overrun", "opener-to-responder", 1, new Uint8Array([1]))
    )
    expect(closes).toEqual(["protocol-error"])
    expect(socket.lastClose()).toMatchObject({ t: "close", reason: "protocol-error" })
  })

  it("machine-side close notifies the peer once", () => {
    const h = harness()
    const socket = connect(h)
    openEcho(socket, "peer-1", "ch-1")
    const channel = h.channels[0]!
    channel.close("done")
    channel.close("done") // second close is a no-op
    expect(socket.closeFrames()).toHaveLength(1)
  })

  it("answers frames for unknown channels with a peer-disconnected close", () => {
    const h = harness()
    const socket = connect(h)

    // The app kept this channel alive across a machine reconnect: we never saw
    // its open, so its frames must be answered with a close — not dropped —
    // or the app waits forever on a channel we no longer know about.
    socket.receiveRelay({
      peerId: "peer-1",
      frame: { t: "credit", channelId: "ch-lost", seq: 7, bytes: 1024 }
    })
    expect(socket.closeFrames()).toHaveLength(1)
    expect(socket.closeFrames()[0]!.channelId).toBe("ch-lost")
    expect(socket.closeFrames()[0]!.reason).toBe("peer-disconnected")

    // Data frames get the same treatment (the check precedes decryption).
    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-lost-2", seq: 3 } },
      new Uint8Array([0, 0, 0, 0])
    )
    expect(socket.closeFrames()).toHaveLength(2)
    expect(socket.closeFrames()[1]!.channelId).toBe("ch-lost-2")
    expect(socket.closeFrames()[1]!.reason).toBe("peer-disconnected")

    // A close for an unknown channel is ignored — no close-for-close loops.
    socket.receiveRelay({
      peerId: "peer-1",
      frame: { t: "close", channelId: "ch-lost-3", seq: 0, reason: "done" }
    })
    expect(socket.closeFrames()).toHaveLength(2)
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

    // Open relayed without the peer's public key.
    socket.receiveRelay(
      {
        peerId: "p",
        frame: { t: "open", channelId: "c1", seq: 0, ephemeralKey: opened.ephemeralPublicKey }
      },
      sealedOpen("echo", "c1")
    )
    expect(socket.lastClose().reason).toBe("protocol-error")

    // Undecryptable open payload.
    socket.receiveRelay(
      {
        peerId: "p",
        peerPublicKey: appKeys.publicKey,
        frame: { t: "open", channelId: "c2", seq: 0, ephemeralKey: opened.ephemeralPublicKey }
      },
      new Uint8Array([0, 0, 0])
    )
    expect(socket.lastClose().reason).toBe("crypto-error")

    // Non-string channelType.
    socket.receiveRelay(
      {
        peerId: "p",
        peerPublicKey: appKeys.publicKey,
        frame: { t: "open", channelId: "c3", seq: 0, ephemeralKey: opened.ephemeralPublicKey }
      },
      sealedOpen(42, "c3")
    )
    expect(socket.lastClose().reason).toBe("protocol-error")

    // Unknown channel type.
    socket.receiveRelay(
      {
        peerId: "p",
        peerPublicKey: appKeys.publicKey,
        frame: { t: "open", channelId: "c4", seq: 0, ephemeralKey: opened.ephemeralPublicKey }
      },
      sealJson(opened.cipher, "c4", "opener-to-responder", 0, { channelType: "screensaver" })
    )
    expect(socket.lastClose().reason).toBe("unsupported")
  })

  it("refuses duplicate channel ids per peer", () => {
    const h = harness()
    const socket = connect(h)
    openEcho(socket, "peer-1", "ch-1")
    openEcho(socket, "peer-1", "ch-1")
    expect(socket.closeFrames()).toHaveLength(1)
    expect(h.channels).toHaveLength(1)
  })

  it("kills channels on seq gaps and crypto failures", () => {
    const h = harness()
    const socket = connect(h)
    const first = openEcho(socket, "peer-1", "ch-gap")
    const gapCloses: string[] = []
    h.channels[0]!.onClosed = (reason) => gapCloses.push(reason)
    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-gap", seq: 5 } }, // expected 1
      sealJson(first.opened.cipher, "ch-gap", "opener-to-responder", 5, {})
    )
    expect(gapCloses).toEqual(["protocol-error"])

    openEcho(socket, "peer-1", "ch-bad")
    const badCloses: string[] = []
    h.channels[1]!.onClosed = (reason) => badCloses.push(reason)
    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-bad", seq: 1 } },
      new Uint8Array([0, 0, 0])
    )
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
    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-credit", seq: 1 } },
      sealJson(opened.cipher, "ch-credit", "opener-to-responder", 1, { key: "a" })
    )
    socket.receiveRelay({
      peerId: "peer-1",
      frame: { t: "credit", channelId: "ch-credit", seq: 2, bytes: 64 }
    })
    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-credit", seq: 3 } },
      sealJson(opened.cipher, "ch-credit", "opener-to-responder", 3, { key: "b" })
    )
    expect(received).toEqual([{ key: "a" }, { key: "b" }])
    expect(closes).toEqual([])
  })

  it("kills channels on credit seq gaps", () => {
    const h = harness()
    const socket = connect(h)
    openEcho(socket, "peer-1", "ch-credit-gap")
    const closes: string[] = []
    h.channels[0]!.onClosed = (reason) => closes.push(reason)
    socket.receiveRelay({
      peerId: "peer-1",
      frame: { t: "credit", channelId: "ch-credit-gap", seq: 4, bytes: 64 } // expected 1
    })
    expect(closes).toEqual(["protocol-error"])
    expect(socket.lastClose()).toMatchObject({ t: "close", reason: "protocol-error" })
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
    expect(socket.sentRelay).toHaveLength(1)
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

describe("relay coalescing", () => {
  it("buffers outgoing envelopes and flushes them as one message", () => {
    const h = harness({ relayCoalesceMs: 5 })
    const socket = connect(h)
    const { opened } = openEcho(socket, "peer-1", "ch-1")
    const channel = h.channels[0]!

    channel.send({ output: "a" })
    channel.send({ output: "b" })
    channel.send({ output: "c" })
    expect(socket.relayMessages).toHaveLength(0)

    activeTimeout(h, 5).run()
    expect(socket.relayMessages).toHaveLength(1)
    const envelopes = socket.relayMessages[0]!
    expect(envelopes.map((envelope) => envelope.header.frame.seq)).toEqual([0, 1, 2])
    expect(
      openJson(opened.cipher, "ch-1", "responder-to-opener", 2, envelopes[2]!.payload)
    ).toEqual({ output: "c" })
  })

  it("drops buffered envelopes when the socket dies before the flush", () => {
    const h = harness({ relayCoalesceMs: 5 })
    const socket = connect(h)
    openEcho(socket, "peer-1", "ch-1")
    h.channels[0]!.send({ output: "never" })
    const flushTimer = activeTimeout(h, 5)
    socket.onclose?.(1006)
    // Even a queued flush callback firing late must not resurrect the frames.
    flushTimer.invoke()
    expect(socket.relayMessages).toHaveLength(0)
  })
})

describe("negotiated compression", () => {
  const framed = (prefix: number, body: Uint8Array): Uint8Array => {
    const plaintext = new Uint8Array(body.byteLength + 1)
    plaintext[0] = prefix
    plaintext.set(body, 1)
    return plaintext
  }
  const compressingHarness = () =>
    harness({
      compressPayload: (bytes) =>
        bytes.byteLength > 64 ? new Uint8Array(deflateRawSync(bytes)) : undefined,
      decompressPayload: (bytes) => new Uint8Array(inflateRawSync(bytes))
    })

  it("frames payloads in both directions and deflates large bodies", () => {
    const h = compressingHarness()
    const socket = connect(h)
    const { opened } = openEcho(socket, "peer-1", "ch-z", { hello: true }, { compress: true })
    const channel = h.channels[0]!
    const received: unknown[] = []
    channel.onData = (value) => received.push(value)

    // Inbound RAW-framed and DEFLATE-framed payloads both decode.
    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-z", seq: 1 } },
      opened.cipher.seal(
        "ch-z",
        "opener-to-responder",
        1,
        framed(0, new TextEncoder().encode(JSON.stringify({ input: "raw" })))
      )
    )
    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-z", seq: 2 } },
      opened.cipher.seal(
        "ch-z",
        "opener-to-responder",
        2,
        framed(1, new Uint8Array(deflateRawSync(JSON.stringify({ input: "deflated" }))))
      )
    )
    expect(received).toEqual([{ input: "raw" }, { input: "deflated" }])

    // Outbound: a large repetitive body goes out DEFLATE-framed and smaller;
    // a small one stays RAW.
    channel.send({ output: "x".repeat(4096) })
    channel.send({ output: "tiny" })
    const [big, small] = socket.sentRelay
    const bigPlain = opened.cipher.open("ch-z", "responder-to-opener", 0, big!.payload)
    expect(bigPlain[0]).toBe(1)
    expect(big!.payload.byteLength).toBeLessThan(1024)
    expect(JSON.parse(inflateRawSync(bigPlain.subarray(1)).toString())).toEqual({
      output: "x".repeat(4096)
    })
    const smallPlain = opened.cipher.open("ch-z", "responder-to-opener", 1, small!.payload)
    expect(smallPlain[0]).toBe(0)
    expect(JSON.parse(new TextDecoder().decode(smallPlain.subarray(1)))).toEqual({
      output: "tiny"
    })
  })

  it("honours the framing without a compressor and kills bad framing", () => {
    // No compressor wired: outbound stays RAW-framed; inbound DEFLATE frames
    // cannot be inflated and abort the channel like any undecodable payload.
    const h = harness()
    const socket = connect(h)
    const { opened } = openEcho(socket, "peer-1", "ch-z", { hello: true }, { compress: true })
    const channel = h.channels[0]!
    const closes: string[] = []
    channel.onClosed = (reason) => closes.push(reason)
    channel.send({ output: "plain" })
    const sent = opened.cipher.open("ch-z", "responder-to-opener", 0, socket.sentRelay[0]!.payload)
    expect(sent[0]).toBe(0)

    socket.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-z", seq: 1 } },
      opened.cipher.seal(
        "ch-z",
        "opener-to-responder",
        1,
        framed(1, new Uint8Array(deflateRawSync("{}")))
      )
    )
    expect(closes).toEqual(["crypto-error"])

    // Unknown framing byte and empty plaintexts are refused the same way.
    const again = compressingHarness()
    const socket2 = connect(again)
    const second = openEcho(socket2, "peer-1", "ch-y", { hello: true }, { compress: true })
    const closes2: string[] = []
    again.channels[0]!.onClosed = (reason) => closes2.push(reason)
    socket2.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-y", seq: 1 } },
      second.opened.cipher.seal("ch-y", "opener-to-responder", 1, framed(7, new Uint8Array(0)))
    )
    expect(closes2).toEqual(["crypto-error"])

    const third = compressingHarness()
    const socket3 = connect(third)
    const gone = openEcho(socket3, "peer-1", "ch-x", { hello: true }, { compress: true })
    const closes3: string[] = []
    third.channels[0]!.onClosed = (reason) => closes3.push(reason)
    socket3.receiveRelay(
      { peerId: "peer-1", frame: { t: "data", channelId: "ch-x", seq: 1 } },
      gone.opened.cipher.seal("ch-x", "opener-to-responder", 1, new Uint8Array(0))
    )
    expect(closes3).toEqual(["crypto-error"])
  })
})

describe("session resume", () => {
  const connectResumable = (h: Harness, token: string): FakeSocket => {
    h.connection.start()
    const socket = h.sockets.at(-1)!
    socket.onopen?.()
    socket.receive({
      t: "welcome",
      protocol: CLOUD_PROTOCOL_VERSION,
      connectionId: "conn-m",
      resume: token
    })
    return socket
  }

  it("holds channels across a resumed reconnect and replays retained frames in order", () => {
    const h = harness()
    const socket = connectResumable(h, "tok-1")
    const { opened } = openEcho(socket, "peer-1", "ch-1")
    const channel = h.channels[0]!
    const closes: string[] = []
    channel.onClosed = (reason) => closes.push(reason)

    socket.onclose?.(1006)
    // Suspended, not dead: sends keep sealing into the retention buffer.
    channel.send({ output: "during-gap-1" })
    channel.send({ output: "during-gap-2" })
    expect(closes).toEqual([])

    h.reconnects[0]!.callback()
    const revived = h.sockets.at(-1)!
    revived.onopen?.()
    const hello = revived.sent[0] as Extract<MachineToHub, { t: "hello" }>
    expect(hello.resume).toBe("tok-1")

    revived.receive({
      t: "welcome",
      protocol: CLOUD_PROTOCOL_VERSION,
      connectionId: "conn-m",
      resume: "tok-2",
      resumed: true
    })
    // The retained backlog replays on the new socket, in order.
    const frames = revived.sentRelay.filter((envelope) => envelope.header.frame.t === "data")
    expect(frames.map((envelope) => envelope.header.frame.seq)).toEqual([0, 1])
    expect(openJson(opened.cipher, "ch-1", "responder-to-opener", 1, frames[1]!.payload)).toEqual({
      output: "during-gap-2"
    })
    expect(closes).toEqual([])

    // The channel keeps flowing with continuous seqs.
    channel.send({ output: "after-resume" })
    expect(
      revived.sentRelay.filter((envelope) => envelope.header.frame.t === "data").at(-1)!.header
        .frame.seq
    ).toEqual(2)
  })

  it("drains a coalescing outbox into the retention buffer on suspend", () => {
    const h = harness({ relayCoalesceMs: 5 })
    const socket = connectResumable(h, "tok-1")
    const { opened } = openEcho(socket, "peer-1", "ch-1")
    const channel = h.channels[0]!

    // Frames still sitting in the coalescing window when the socket dies...
    channel.send({ output: "unflushed" })
    expect(socket.relayMessages).toHaveLength(0)
    const flushTimer = activeTimeout(h, 5)
    socket.onclose?.(1006)
    flushTimer.invoke()

    // ...survive the gap and replay after the resumed welcome.
    h.reconnects[0]!.callback()
    const revived = h.sockets.at(-1)!
    revived.onopen?.()
    revived.receive({
      t: "welcome",
      protocol: CLOUD_PROTOCOL_VERSION,
      connectionId: "conn-m",
      resume: "tok-2",
      resumed: true
    })
    activeTimeout(h, 5).run()
    const frames = revived.sentRelay.filter((envelope) => envelope.header.frame.t === "data")
    expect(frames).toHaveLength(1)
    expect(openJson(opened.cipher, "ch-1", "responder-to-opener", 0, frames[0]!.payload)).toEqual({
      output: "unflushed"
    })
  })

  it("drops held channels when the reconnect lands a fresh identity", () => {
    const h = harness()
    const socket = connectResumable(h, "tok-1")
    openEcho(socket, "peer-1", "ch-1")
    const closes: string[] = []
    h.channels[0]!.onClosed = (reason) => closes.push(reason)

    socket.onclose?.(1006)
    h.channels[0]!.send({ output: "never delivered" })
    h.reconnects[0]!.callback()
    const revived = h.sockets.at(-1)!
    revived.onopen?.()
    revived.receive({
      t: "welcome",
      protocol: CLOUD_PROTOCOL_VERSION,
      connectionId: "conn-DIFFERENT",
      resume: "tok-2"
    })

    expect(closes).toEqual(["peer-gone"])
    // The retained backlog referenced dead peer ids; nothing replays.
    expect(revived.sentRelay).toHaveLength(0)
  })

  it("overflowing the retention buffer falls back to plain teardown", () => {
    const channels: IncomingChannel[] = []
    const h = harness({
      handlers: {
        echo: (channel) => {
          channels.push(channel)
        }
      }
    })
    const socket = connectResumable(h, "tok-1")
    openEcho(socket, "peer-1", "ch-1")
    const closes: string[] = []
    channels[0]!.onClosed = (reason) => closes.push(reason)

    socket.onclose?.(1006)
    const chunk = new Uint8Array(60 * 1024)
    for (let index = 0; index < 5; index += 1) {
      channels[0]!.sendBytes(chunk)
    }
    expect(closes).toEqual(["peer-gone"])

    // The next welcome is treated as fresh (resume state was discarded).
    h.reconnects[0]!.callback()
    const revived = h.sockets.at(-1)!
    revived.onopen?.()
    const hello = revived.sent[0] as Extract<MachineToHub, { t: "hello" }>
    expect(hello.resume).toBeUndefined()
  })

  it("answers pre-welcome relay frames on the young socket", () => {
    // No resume state and not yet welcomed: refusals go straight out on the
    // fresh socket rather than into a retention buffer.
    const h = harness()
    h.connection.start()
    const socket = h.sockets[0]!
    socket.onopen?.()
    socket.receiveRelay({
      peerId: "p",
      frame: { t: "credit", channelId: "orphan", seq: 0, bytes: 1 }
    })
    expect(socket.lastClose()).toMatchObject({
      t: "close",
      channelId: "orphan",
      reason: "peer-disconnected"
    })
  })

  it("stop() during suspension tears everything down", () => {
    const h = harness()
    const socket = connectResumable(h, "tok-1")
    openEcho(socket, "peer-1", "ch-1")
    const closes: string[] = []
    h.channels[0]!.onClosed = (reason) => closes.push(reason)
    socket.onclose?.(1006)
    expect(closes).toEqual([])
    h.connection.stop()
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
      {
        appKeys: first.appKeys,
        peerDeviceId: "app-1"
      }
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
      {
        appKeys: attacker,
        peerDeviceId: "app-1"
      }
    )
    expect(h.channels).toHaveLength(2)
    expect(socket.lastClose()).toMatchObject({ t: "close", channelId: "ch-3", reason: "rejected" })
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
    expect(socket.lastClose()).toMatchObject({ t: "close", reason: "rejected" })
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
    socket.receiveRelay(
      {
        peerId: "peer-1",
        peerPublicKey: presented.publicKey,
        peerDeviceId: "app-1",
        frame: { t: "open", channelId: "ch-1", seq: 0, ephemeralKey: opened.ephemeralPublicKey }
      },
      sealJson(opened.cipher, "ch-1", "opener-to-responder", 0, { channelType: "echo" })
    )
    expect(socket.lastClose()).toMatchObject({ t: "close", reason: "crypto-error" })
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
