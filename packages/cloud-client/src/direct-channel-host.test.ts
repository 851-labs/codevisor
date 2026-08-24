import {
  CLOUD_PROTOCOL_VERSION,
  decodeHubToMachine,
  decodeRelayEnvelopes,
  encodeCloudFrame,
  encodeRelayEnvelopes,
  type HubToMachine,
  type RelayFrameHeader
} from "@codevisor/api"
import { generateDeviceKeyPair, openChannel, openJson, sealJson } from "@codevisor/cloud-crypto"
import { describe, expect, it, vi } from "vitest"
import {
  DIRECT_CLOSE_HELLO_TIMEOUT,
  DIRECT_CLOSE_UNPINNED,
  DIRECT_CLOSE_UNSUPPORTED_PROTOCOL,
  DirectChannelHost,
  makePeerKeyPinStore,
  type CloudSocket,
  type IncomingChannel
} from "./index.js"

/// The direct pipe from the app's point of view: text control frames come
/// back as JSON, envelopes as binary batches.
class FakeDirectSocket implements CloudSocket {
  controls: unknown[] = []
  envelopes: { header: { machineId: string; frame: RelayFrameHeader }; payload: Uint8Array }[] = []
  closed: { code?: number; reason?: string } | undefined
  onopen: (() => void) | null = null
  onmessage: ((data: string | Uint8Array) => void) | null = null
  onclose: ((code: number) => void) | null = null

  send(data: string | Uint8Array): void {
    if (typeof data === "string") {
      this.controls.push(JSON.parse(data))
      return
    }
    for (const envelope of decodeRelayEnvelopes(data)) {
      this.envelopes.push({
        header: envelope.header as { machineId: string; frame: RelayFrameHeader },
        payload: new Uint8Array(envelope.payload)
      })
    }
  }

  close(code?: number, reason?: string): void {
    this.closed = { code: code ?? 0, ...(reason === undefined ? {} : { reason }) }
    this.onclose?.(code ?? 1000)
  }

  hello(device: {
    deviceId: string
    publicKey: string
    kind?: "app" | "machine"
    protocol?: number
  }): void {
    this.onmessage?.(
      JSON.stringify({
        t: "hello",
        protocol: device.protocol ?? CLOUD_PROTOCOL_VERSION,
        device: {
          deviceId: device.deviceId,
          kind: device.kind ?? "app",
          name: "Direct App",
          publicKey: device.publicKey
        }
      })
    )
  }

  relay(machineId: string, frame: RelayFrameHeader, payload: Uint8Array = new Uint8Array(0)): void {
    this.onmessage?.(encodeRelayEnvelopes([{ header: { machineId, frame }, payload }]))
  }
}

const machineKeys = generateDeviceKeyPair()
const appKeys = generateDeviceKeyPair()

const makeHost = (
  overrides: {
    handlers?: Record<string, (channel: IncomingChannel) => void>
    channels?: IncomingChannel[]
  } = {}
) => {
  const channels: IncomingChannel[] = overrides.channels ?? []
  const timers: { callback: () => void; delayMs: number; cancelled: boolean }[] = []
  const host = new DirectChannelHost({
    deviceId: "machine-1",
    secretKey: machineKeys.secretKey,
    channelHandlers: overrides.handlers ?? { echo: (channel) => channels.push(channel) },
    peerKeyPins: makePeerKeyPinStore({ initial: { "app-1": appKeys.publicKey } }),
    scheduleTimeout: (callback, delayMs) => {
      const timer = { callback, delayMs, cancelled: false }
      timers.push(timer)
      return () => {
        timer.cancelled = true
      }
    }
  })
  return { host, channels, timers }
}

const welcomeOf = (socket: FakeDirectSocket): Extract<HubToMachine, { t: "welcome" }> => {
  const raw = socket.controls.at(-1)
  return decodeHubToMachine(JSON.stringify(raw)) as Extract<HubToMachine, { t: "welcome" }>
}

describe("DirectChannelHost", () => {
  it("welcomes a pinned device and serves a sealed channel round trip", () => {
    const { host, channels, timers } = makeHost()
    const socket = new FakeDirectSocket()
    host.accept(socket)
    socket.hello({ deviceId: "app-1", publicKey: appKeys.publicKey })

    const welcome = welcomeOf(socket)
    expect(welcome).toMatchObject({ t: "welcome", protocol: CLOUD_PROTOCOL_VERSION })
    expect(timers[0]!.cancelled).toBe(true)

    // Open + data, sealed with the same crypto as the relay.
    const opened = openChannel(appKeys.secretKey, machineKeys.publicKey)
    socket.relay(
      "machine-1",
      { t: "open", channelId: "d-1", seq: 0, ephemeralKey: opened.ephemeralPublicKey },
      sealJson(opened.cipher, "d-1", "opener-to-responder", 0, { channelType: "echo" })
    )
    expect(channels).toHaveLength(1)
    const received: unknown[] = []
    channels[0]!.onData = (value) => received.push(value)
    socket.relay(
      "machine-1",
      { t: "data", channelId: "d-1", seq: 1 },
      sealJson(opened.cipher, "d-1", "opener-to-responder", 1, { input: "hi" })
    )
    expect(received).toEqual([{ input: "hi" }])

    channels[0]!.send({ output: "hello back" })
    const reply = socket.envelopes.at(-1)!
    expect(reply.header.machineId).toBe("machine-1")
    expect(openJson(opened.cipher, "d-1", "responder-to-opener", 0, reply.payload)).toEqual({
      output: "hello back"
    })

    // Envelopes addressed to some other machine are ignored.
    socket.relay("someone-else", { t: "credit", channelId: "d-1", seq: 2, bytes: 1 })
    expect(socket.envelopes.filter((envelope) => envelope.header.frame.t === "close")).toHaveLength(
      0
    )

    // Ping keeps the pipe warm; close drops the channels.
    socket.onmessage?.(encodeCloudFrame({ t: "ping" }))
    expect(socket.controls.at(-1)).toMatchObject({ t: "pong" })
    const closes: string[] = []
    channels[0]!.onClosed = (reason) => closes.push(reason)
    socket.close(1001)
    expect(closes).toEqual(["peer-gone"])
  })

  it("never trusts on first use: unpinned and mismatched devices are refused", () => {
    const { host } = makeHost()

    const unknown = new FakeDirectSocket()
    host.accept(unknown)
    unknown.hello({ deviceId: "app-unknown", publicKey: generateDeviceKeyPair().publicKey })
    expect(unknown.closed?.code).toBe(DIRECT_CLOSE_UNPINNED)

    const impostor = new FakeDirectSocket()
    host.accept(impostor)
    impostor.hello({ deviceId: "app-1", publicKey: generateDeviceKeyPair().publicKey })
    expect(impostor.closed?.code).toBe(DIRECT_CLOSE_UNPINNED)

    const machineKind = new FakeDirectSocket()
    host.accept(machineKind)
    machineKind.hello({ deviceId: "app-1", publicKey: appKeys.publicKey, kind: "machine" })
    expect(machineKind.closed?.code).toBe(DIRECT_CLOSE_UNPINNED)
  })

  it("enforces protocol version, hello ordering, and the hello deadline", () => {
    const { host, timers } = makeHost()

    const outdated = new FakeDirectSocket()
    host.accept(outdated)
    outdated.hello({ deviceId: "app-1", publicKey: appKeys.publicKey, protocol: 1 })
    expect(outdated.closed?.code).toBe(DIRECT_CLOSE_UNSUPPORTED_PROTOCOL)

    const eager = new FakeDirectSocket()
    host.accept(eager)
    eager.relay("machine-1", { t: "data", channelId: "d", seq: 0 }, new Uint8Array([1]))
    expect(eager.closed?.code).toBe(4000)

    const silent = new FakeDirectSocket()
    host.accept(silent)
    timers.at(-1)!.callback()
    expect(silent.closed?.code).toBe(DIRECT_CLOSE_HELLO_TIMEOUT)

    const garbage = new FakeDirectSocket()
    host.accept(garbage)
    garbage.onmessage?.("not json")
    expect(garbage.closed?.code).toBe(4000)
  })

  it("drops malformed relay batches and rides out socket send failures", () => {
    vi.useFakeTimers()
    try {
      // No injected scheduleTimeout: the real setTimeout path arms the
      // hello deadline.
      const host = new DirectChannelHost({
        deviceId: "machine-1",
        secretKey: machineKeys.secretKey,
        channelHandlers: {},
        peerKeyPins: makePeerKeyPinStore({ initial: { "app-1": appKeys.publicKey } }),
        // Same negotiated-compression hooks as the relay connection.
        compressPayload: (bytes) => bytes,
        decompressPayload: (bytes) => bytes
      })
      const silent = new FakeDirectSocket()
      host.accept(silent)
      vi.advanceTimersByTime(10_000)
      expect(silent.closed?.code).toBe(DIRECT_CLOSE_HELLO_TIMEOUT)

      const socket = new FakeDirectSocket()
      host.accept(socket)
      socket.hello({ deviceId: "app-1", publicKey: appKeys.publicKey })
      // A duplicate hello is ignored, not re-welcomed.
      socket.hello({ deviceId: "app-1", publicKey: appKeys.publicKey })
      expect(socket.controls).toHaveLength(1)
      expect(socket.closed).toBeUndefined()
      // A welcomed pipe that sends garbage envelopes is torn down.
      socket.onmessage?.(new Uint8Array([1, 2, 3]))
      expect(socket.closed?.code).toBe(4000)

      // A dying socket must not throw out of the host's send path: the
      // rejection open below answers onto a socket whose send explodes.
      const failing = new FakeDirectSocket()
      host.accept(failing)
      failing.hello({ deviceId: "app-1", publicKey: appKeys.publicKey })
      failing.send = () => {
        throw new Error("socket is gone")
      }
      const opened = openChannel(appKeys.secretKey, machineKeys.publicKey)
      expect(() =>
        failing.relay(
          "machine-1",
          { t: "open", channelId: "d-x", seq: 0, ephemeralKey: opened.ephemeralPublicKey },
          sealJson(opened.cipher, "d-x", "opener-to-responder", 0, { channelType: "unknown" })
        )
      ).not.toThrow()
    } finally {
      vi.useRealTimers()
    }
  })
})
