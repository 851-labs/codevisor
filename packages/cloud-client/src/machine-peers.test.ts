import {
  CLOUD_PROTOCOL_VERSION,
  GATEWAY_CHANNEL_TYPE,
  MACHINE_PEERS_FEATURE,
  type CloudMachinePresence
} from "@codevisor/api"
import { generateDeviceKeyPair } from "@codevisor/cloud-crypto"
import { describe, expect, it } from "vitest"

import {
  ChannelKeyMismatchError,
  ChannelOpenError,
  GATEWAY_CHUNK_CHARS,
  makePeerKeyPinStore,
  type IncomingChannel
} from "./index.js"
import { harness } from "./machine-connection-test-support.js"
import {
  failure,
  gatewayRequest,
  makePeer,
  pair,
  presence,
  welcome
} from "./machine-peers-test-support.js"

describe("machine peers", () => {
  it("advertises peer support and tracks the account's machines", () => {
    const seen: string[][] = []
    const h = harness({
      device: { name: "vps", serverId: "machine-vps" },
      onMachinesChanged: (machines) => seen.push(machines.map((m) => `${m.name}:${m.online}`))
    })
    h.connection.start()
    const socket = h.sockets[0]!
    socket.onopen?.()
    expect(socket.sent[0]).toMatchObject({
      t: "hello",
      device: { serverId: "machine-vps" },
      features: [MACHINE_PEERS_FEATURE]
    })
    const other = generateDeviceKeyPair()
    const studio: CloudMachinePresence = {
      deviceId: "studio",
      name: "Studio",
      publicKey: other.publicKey,
      online: true,
      lastSeenAt: "2100-01-01T00:00:00.000Z"
    }
    socket.receive({
      t: "welcome",
      protocol: CLOUD_PROTOCOL_VERSION,
      connectionId: "c",
      machines: [studio]
    })
    socket.receive({ t: "presence", machine: { ...studio, online: false } })
    expect(seen).toEqual([["Studio:true"], ["Studio:false"]])
    expect(h.connection.machines()).toEqual([{ ...studio, online: false }])
    h.connection.stop()
    expect(h.connection.machines()).toBeUndefined()
  })

  it("round-trips a chunked gateway exchange end to end and pins both keys", async () => {
    const aPins = makePeerKeyPinStore({})
    const bPins = makePeerKeyPinStore({})
    const { a, b } = pair({ a: { pins: aPins }, b: { pins: bPins } })
    const body = "x".repeat(GATEWAY_CHUNK_CHARS + 5)

    const answer = await gatewayRequest(a, b, body)

    expect(answer).toEqual({ status: 200, body: body.toUpperCase() })
    // Request and answer both spanned two chunk frames.
    const dataFrames = a.socket.relayFrames().filter((frame) => frame.t === "data")
    expect(dataFrames).toHaveLength(3)
    expect(aPins.get("b")).toBe(b.keys.publicKey)
    expect(bPins.get("a")).toBe(a.keys.publicKey)
  })

  it("refuses to open when the target is unknown, offline, outdated, itself, or unreachable", async () => {
    const { a, b } = pair()
    const reasonOf = (deviceId: string): string => {
      try {
        a.h.connection.openChannel(deviceId, GATEWAY_CHANNEL_TYPE)
      } catch (cause) {
        return (cause as ChannelOpenError).reason
      }
      return "opened"
    }
    expect(reasonOf("nobody")).toBe("unknown-machine")
    expect(reasonOf("a")).toBe("unknown-machine")
    a.socket.receive({ t: "presence", machine: presence(b, false) })
    expect(reasonOf("b")).toBe("machine-offline")
    // A target that never advertised machine peers would not restrict a
    // machine opener to the gateway: never open to it.
    a.socket.receive({ t: "presence", machine: { ...presence(b), machinePeers: undefined } })
    expect(reasonOf("b")).toBe("machine-outdated")
    const outdated = await failure(gatewayRequest(a, b, "{}"))
    expect(outdated).toMatchObject({ phase: "before-send", closeReason: "unsupported" })

    // A hub that predates machine peers sends no machine list.
    const legacy = makePeer("legacy")
    welcome(legacy)
    expect(() => legacy.h.connection.openChannel("b", GATEWAY_CHANNEL_TYPE)).toThrow(
      expect.objectContaining({ reason: "peers-unsupported" })
    )
    const idle = makePeer("idle")
    idle.h.connection.stop()
    expect(() => idle.h.connection.openChannel("b", GATEWAY_CHANNEL_TYPE)).toThrow(ChannelOpenError)
    expect(a.socket.relayFrames()).toEqual([])
  })

  it("refuses a target whose key changed since it was pinned, sending nothing", async () => {
    const mismatches: unknown[] = []
    const keys = generateDeviceKeyPair()
    const a = makePeer("a", { pins: makePeerKeyPinStore({ initial: { b: keys.publicKey } }) })
    const h = harness({
      credentials: {
        serverUrl: "https://cloud.example",
        deviceId: "a2",
        publicKey: keys.publicKey,
        secretKey: keys.secretKey,
        apiKey: "k"
      },
      peerKeyPins: makePeerKeyPinStore({ initial: { b: keys.publicKey } }),
      onPeerKeyMismatch: (info) => mismatches.push(info)
    })
    h.connection.start()
    h.sockets[0]!.onopen?.()
    const b = makePeer("b")
    h.sockets[0]!.receive({
      t: "welcome",
      protocol: CLOUD_PROTOCOL_VERSION,
      connectionId: "c",
      machines: [presence(b)]
    })
    expect(() => h.connection.openChannel("b", GATEWAY_CHANNEL_TYPE)).toThrow(
      ChannelKeyMismatchError
    )
    expect(mismatches).toEqual([
      { deviceId: "b", pinned: keys.publicKey, presented: b.keys.publicKey }
    ])
    expect(h.sockets[0]!.relayFrames()).toEqual([])
    // Surfaced to gateway callers as a before-send failure.
    welcome(a, [presence(b)])
    const error = await failure(gatewayRequest(a, b, "{}"))
    expect(error.phase).toBe("before-send")
  })

  it("lets machines open only gateway channels", () => {
    const opened: IncomingChannel[] = []
    const { a, hub } = pair({
      b: {
        handlers: {
          [GATEWAY_CHANNEL_TYPE]: (channel) => opened.push(channel),
          http: (channel) => opened.push(channel)
        }
      }
    })
    const ended: unknown[] = []
    const http = a.h.connection.openChannel("b", "http", { path: "/v1/info" })
    http.onEnded = (end) => ended.push(end)
    hub.flush()
    expect(ended).toEqual([{ kind: "peer-closed", reason: "rejected" }])
    a.h.connection.openChannel("b", GATEWAY_CHANNEL_TYPE)
    hub.flush()
    expect(opened.map((channel) => channel.channelType)).toEqual([GATEWAY_CHANNEL_TYPE])
  })
})

describe("channel opener framing", () => {
  it("rejects out-of-order, undecryptable, and stray answers", () => {
    const { a, hub } = pair()
    // Nothing reaches b: the test scripts b's answers by hand.
    hub.holding = true
    const next = () => {
      const fresh = a.h.connection.openChannel("b", GATEWAY_CHANNEL_TYPE)
      const events: unknown[] = []
      fresh.onEnded = (end) => events.push(end)
      return { fresh, events }
    }
    const gap = next()
    a.socket.receiveRelay({
      machineId: "b",
      frame: { t: "data", channelId: gap.fresh.channelId, seq: 5 }
    })
    expect(gap.events).toEqual([{ kind: "protocol-error" }])

    const garbled = next()
    a.socket.receiveRelay({
      machineId: "b",
      frame: { t: "credit", channelId: garbled.fresh.channelId, seq: 0, bytes: 10 }
    })
    a.socket.receiveRelay(
      { machineId: "b", frame: { t: "data", channelId: garbled.fresh.channelId, seq: 1 } },
      new Uint8Array([1, 2, 3])
    )
    expect(garbled.events).toEqual([{ kind: "protocol-error" }])
    expect(a.socket.lastClose().reason).toBe("crypto-error")

    // Frames for channels this side no longer holds get a close back; a
    // stray close gets nothing.
    const before = a.socket.closeFrames().length
    a.socket.receiveRelay({ machineId: "b", frame: { t: "data", channelId: "gone", seq: 0 } })
    a.socket.receiveRelay({
      machineId: "b",
      frame: { t: "close", channelId: "gone", seq: 1, reason: "done" }
    })
    expect(a.socket.closeFrames().slice(before)).toEqual([
      { t: "close", channelId: "gone", seq: 0, reason: "peer-disconnected" }
    ])
    // Sends and closes after the end are no-ops.
    const sentBefore = a.socket.relayFrames().length
    gap.fresh.send({ late: true })
    gap.fresh.close()
    expect(a.socket.relayFrames()).toHaveLength(sentBefore)
  })
})
