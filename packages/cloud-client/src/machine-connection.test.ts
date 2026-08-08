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
  reconnectDelayMs,
  type CloudSocket,
  type IncomingChannel,
  type MachineConnectionState
} from "./index.js"

class FakeSocket implements CloudSocket {
  sent: MachineToHub[] = []
  closed: { code?: number; reason?: string } | undefined
  onopen: (() => void) | null = null
  onmessage: ((data: string) => void) | null = null
  onclose: ((code: number) => void) | null = null

  send(data: string): void {
    this.sent.push(decodeMachineToHub(data))
  }

  close(code?: number, reason?: string): void {
    this.closed = code !== undefined ? { code, ...(reason !== undefined ? { reason } : {}) } : {}
  }

  receive(frame: HubToMachine): void {
    this.onmessage?.(encodeCloudFrame(frame))
  }
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
  channels: IncomingChannel[]
}

const harness = (
  overrides: {
    handlers?: Record<string, (channel: IncomingChannel) => void>
    device?: { name: string; os?: string; appVersion?: string }
  } = {}
): Harness => {
  const sockets: FakeSocket[] = []
  const urls: string[] = []
  const headers: Record<string, string>[] = []
  const states: MachineConnectionState[] = []
  const reconnects: { callback: () => void; delayMs: number }[] = []
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
    onStateChange: (state) => states.push(state),
    scheduleReconnect: (callback, delayMs) => reconnects.push({ callback, delayMs }),
    random: () => 0.5
  })
  return { connection, sockets, urls, headers, states, reconnects, channels }
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
  params: unknown = { hello: true }
) => {
  const appKeys = generateDeviceKeyPair()
  const opened = openChannel(appKeys.secretKey, machineKeys.publicKey)
  socket.receive({
    t: "relay",
    peerId,
    peerPublicKey: appKeys.publicKey,
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
    // Send after close is a no-op: still just the two data frames.
    channel.send({ late: true })
    expect(socket.sent.filter((f) => f.t === "relay")).toHaveLength(2)
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
      // Max backoff is 30s; a fresh connection must exist by then.
      vi.advanceTimersByTime(30_001)
      expect(sockets).toHaveLength(2)
      connection.stop()
    } finally {
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
