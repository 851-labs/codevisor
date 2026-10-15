import {
  CLOUD_PROTOCOL_VERSION,
  decodeHubToMachine,
  decodeRelayEnvelopes,
  encodeCloudFrame,
  encodeRelayEnvelopes,
  parseHubToAppRelayHeader,
  type HubToAppRelayHeader,
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

class FakeDirectSocket implements CloudSocket {
  controls: unknown[] = []
  envelopes: { header: HubToAppRelayHeader; payload: Uint8Array }[] = []
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
      const header = parseHubToAppRelayHeader(envelope.header)
      if (header === undefined) throw new Error("host sent a malformed relay header")
      this.envelopes.push({ header, payload: new Uint8Array(envelope.payload) })
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
  const frame = decodeHubToMachine(JSON.stringify(socket.controls.at(-1)))
  if (frame.t !== "welcome") throw new Error(`expected a welcome, got ${frame.t}`)
  return frame
}

describe("DirectChannelHost", () => {
  it("defers the identity decision to an injected gate with the pipe's peer", () => {
    const decisions: unknown[] = []
    const host = new DirectChannelHost({
      deviceId: "machine-1",
      secretKey: machineKeys.secretKey,
      channelHandlers: {},
      peerKeyPins: makePeerKeyPinStore({}),
      admitHello: (device, peer) => {
        decisions.push({ device, peer })
        return peer.endpointId === "e-trusted"
      }
    })
    const admitted = new FakeDirectSocket()
    host.accept(admitted, { endpointId: "e-trusted" })
    admitted.hello({ deviceId: "app-new", publicKey: appKeys.publicKey })
    expect(welcomeOf(admitted)).toMatchObject({ t: "welcome" })

    const refused = new FakeDirectSocket()
    host.accept(refused, { endpointId: "e-other" })
    refused.hello({ deviceId: "app-new", publicKey: appKeys.publicKey })
    expect(refused.closed?.code).toBe(DIRECT_CLOSE_UNPINNED)
    expect(decisions).toEqual([
      {
        device: { deviceId: "app-new", publicKey: appKeys.publicKey },
        peer: { endpointId: "e-trusted" }
      },
      {
        device: { deviceId: "app-new", publicKey: appKeys.publicKey },
        peer: { endpointId: "e-other" }
      }
    ])
  })

  it("welcomes a pinned device and serves a sealed channel round trip", () => {
    const { host, channels, timers } = makeHost()
    const socket = new FakeDirectSocket()
    host.accept(socket)
    socket.hello({ deviceId: "app-1", publicKey: appKeys.publicKey })

    const welcome = welcomeOf(socket)
    expect(welcome).toMatchObject({ t: "welcome", protocol: CLOUD_PROTOCOL_VERSION })
    expect(timers[0]!.cancelled).toBe(true)

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

    socket.relay("someone-else", { t: "credit", channelId: "d-1", seq: 2, bytes: 1 })
    expect(socket.envelopes.filter((envelope) => envelope.header.frame.t === "close")).toHaveLength(
      0
    )

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

  it("gates structured sends behind opener credit on flow-controlled channels", () => {
    const { host, channels } = makeHost()
    const socket = new FakeDirectSocket()
    host.accept(socket)
    socket.hello({ deviceId: "app-1", publicKey: appKeys.publicKey })
    const opened = openChannel(appKeys.secretKey, machineKeys.publicKey)
    socket.relay(
      "machine-1",
      { t: "open", channelId: "f-1", seq: 0, ephemeralKey: opened.ephemeralPublicKey },
      sealJson(opened.cipher, "f-1", "opener-to-responder", 0, {
        channelType: "echo",
        flowControl: true
      })
    )
    const channel = channels[0]!
    expect(channel.flowControlRequested).toBe(true)

    channel.send({ n: 1 })
    channel.send({ n: 2 })
    const dataFrames = () => socket.envelopes.filter((e) => e.header.frame.t === "data")
    expect(dataFrames()).toHaveLength(0)
    expect(channel.queuedOutboundBytes()).toBeGreaterThan(0)
    channel.close("done")
    expect(socket.envelopes.filter((e) => e.header.frame.t === "close")).toHaveLength(0)

    socket.relay("machine-1", { t: "credit", channelId: "f-1", seq: 1, bytes: 23 })
    expect(dataFrames()).toHaveLength(1)
    expect(
      openJson(opened.cipher, "f-1", "responder-to-opener", 0, dataFrames()[0]!.payload)
    ).toEqual({ n: 1 })

    socket.relay("machine-1", { t: "credit", channelId: "f-1", seq: 2, bytes: 10_000 })
    expect(dataFrames()).toHaveLength(2)
    expect(
      openJson(opened.cipher, "f-1", "responder-to-opener", 1, dataFrames()[1]!.payload)
    ).toEqual({ n: 2 })
    expect(channel.queuedOutboundBytes()).toBe(0)
    const close = socket.envelopes.find((e) => e.header.frame.t === "close")!
    expect(close.header.frame).toMatchObject({ t: "close", seq: 2, reason: "done" })
  })

  it("enforces the opener's own budget and rejects invalid grants", () => {
    const { host, channels } = makeHost()
    const socket = new FakeDirectSocket()
    host.accept(socket)
    socket.hello({ deviceId: "app-1", publicKey: appKeys.publicKey })

    const starved = openChannel(appKeys.secretKey, machineKeys.publicKey)
    socket.relay(
      "machine-1",
      { t: "open", channelId: "f-2", seq: 0, ephemeralKey: starved.ephemeralPublicKey },
      sealJson(starved.cipher, "f-2", "opener-to-responder", 0, {
        channelType: "echo",
        flowControl: true
      })
    )
    const closes: string[] = []
    channels[0]!.onClosed = (reason) => closes.push(reason)
    socket.relay(
      "machine-1",
      { t: "data", channelId: "f-2", seq: 1 },
      sealJson(starved.cipher, "f-2", "opener-to-responder", 1, { too: "eager" })
    )
    expect(closes).toEqual(["protocol-error"])

    const flooded = openChannel(appKeys.secretKey, machineKeys.publicKey)
    socket.relay(
      "machine-1",
      { t: "open", channelId: "f-3", seq: 0, ephemeralKey: flooded.ephemeralPublicKey },
      sealJson(flooded.cipher, "f-3", "opener-to-responder", 0, {
        channelType: "echo",
        flowControl: true
      })
    )
    const floodCloses: string[] = []
    channels[1]!.onClosed = (reason) => floodCloses.push(reason)
    const huge = Number.MAX_SAFE_INTEGER
    socket.relay("machine-1", { t: "credit", channelId: "f-3", seq: 1, bytes: huge })
    expect(floodCloses).toEqual([])
    socket.relay("machine-1", { t: "credit", channelId: "f-3", seq: 2, bytes: huge })
    expect(floodCloses).toEqual(["protocol-error"])

    const budgeted = openChannel(appKeys.secretKey, machineKeys.publicKey)
    socket.relay(
      "machine-1",
      { t: "open", channelId: "f-4", seq: 0, ephemeralKey: budgeted.ephemeralPublicKey },
      sealJson(budgeted.cipher, "f-4", "opener-to-responder", 0, {
        channelType: "echo",
        flowControl: true
      })
    )
    const sizes: number[] = []
    channels[2]!.onData = (_value, sealedBytes) => sizes.push(sealedBytes)
    channels[2]!.grantCredit(1024)
    const sealed = sealJson(budgeted.cipher, "f-4", "opener-to-responder", 1, { ok: true })
    socket.relay("machine-1", { t: "data", channelId: "f-4", seq: 1 }, sealed)
    expect(sizes).toEqual([sealed.byteLength])

    socket.relay("machine-1", { t: "credit", channelId: "f-4", seq: 2, bytes: 10_000 })
    channels[2]!.send({ pong: true })
    expect(channels[2]!.queuedOutboundBytes()).toBe(0)
    const direct = socket.envelopes.filter(
      (e) => e.header.frame.channelId === "f-4" && e.header.frame.t === "data"
    )
    expect(direct).toHaveLength(1)
    expect(openJson(budgeted.cipher, "f-4", "responder-to-opener", 1, direct[0]!.payload)).toEqual({
      pong: true
    })
  })

  it("drops malformed relay batches and rides out socket send failures", () => {
    vi.useFakeTimers()
    try {
      const host = new DirectChannelHost({
        deviceId: "machine-1",
        secretKey: machineKeys.secretKey,
        channelHandlers: {},
        peerKeyPins: makePeerKeyPinStore({ initial: { "app-1": appKeys.publicKey } }),
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
      socket.hello({ deviceId: "app-1", publicKey: appKeys.publicKey })
      expect(socket.controls).toHaveLength(1)
      expect(socket.closed).toBeUndefined()
      socket.onmessage?.(new Uint8Array([1, 2, 3]))
      expect(socket.closed?.code).toBe(4000)

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

  it("drops control replies onto a socket that is already closing", () => {
    const { host } = makeHost()
    const closing = new FakeDirectSocket()
    closing.send = () => {
      throw new Error("tunnel stream is closed")
    }
    host.accept(closing)
    expect(() => closing.hello({ deviceId: "app-1", publicKey: appKeys.publicKey })).not.toThrow()
    expect(() => closing.onmessage?.(encodeCloudFrame({ t: "ping" }))).not.toThrow()
  })
})
