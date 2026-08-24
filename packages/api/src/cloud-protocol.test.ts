import { describe, expect, it } from "vitest"
import {
  CLOUD_PROTOCOL_VERSION,
  TERMINAL_CHANNEL_TYPE,
  decodeAppToHub,
  decodeHubToApp,
  decodeHubToMachine,
  decodeMachineToHub,
  decodeRelayEnvelopes,
  encodeCloudFrame,
  encodeRelayEnvelopes,
  parseAppRelayHeader,
  parseHubToAppRelayHeader,
  parseHubToMachineRelayHeader,
  parseMachineRelayHeader,
  parseRelayFrameHeader,
  type AppToHub,
  type CloudDeviceInfo,
  type CloudMachinePresence,
  type HubToApp,
  type HubToMachine,
  type MachineToHub,
  type RelayFrameHeader
} from "./cloud-protocol.js"

const appDevice: CloudDeviceInfo = {
  deviceId: "app-1",
  kind: "app",
  name: "Dylan's MacBook",
  os: "macOS",
  appVersion: "1.2.3",
  publicKey: "app-pub"
}

const machinePresence: CloudMachinePresence = {
  deviceId: "m-1",
  name: "dev-vps",
  os: "linux",
  publicKey: "machine-pub",
  online: true,
  lastSeenAt: "2026-08-07T00:00:00.000Z"
}

describe("control frames (JSON text)", () => {
  it("round-trips every app→hub frame", () => {
    const frames: AppToHub[] = [
      { t: "hello", protocol: CLOUD_PROTOCOL_VERSION, device: appDevice },
      { t: "ping" }
    ]
    for (const frame of frames) {
      expect(decodeAppToHub(encodeCloudFrame(frame))).toEqual(frame)
    }
  })

  it("round-trips every hub→app frame", () => {
    const frames: HubToApp[] = [
      {
        t: "welcome",
        protocol: CLOUD_PROTOCOL_VERSION,
        connectionId: "conn-1",
        machines: [machinePresence, { ...machinePresence, deviceId: "m-2", online: false }]
      },
      { t: "presence", machine: machinePresence },
      { t: "machine-reset", machineId: "m-1" },
      { t: "error", code: "machine-offline", message: "gone", machineId: "m-1", channelId: "ch-1" },
      { t: "error", code: "unsupported-protocol", message: "too old" },
      { t: "pong" }
    ]
    for (const frame of frames) {
      expect(decodeHubToApp(encodeCloudFrame(frame))).toEqual(frame)
    }
  })

  it("round-trips every machine-plane frame", () => {
    const toHub: MachineToHub[] = [
      {
        t: "hello",
        protocol: CLOUD_PROTOCOL_VERSION,
        device: { deviceId: "m-1", kind: "machine", name: "dev-vps", publicKey: "machine-pub" }
      },
      { t: "ping" }
    ]
    for (const frame of toHub) {
      expect(decodeMachineToHub(encodeCloudFrame(frame))).toEqual(frame)
    }
    const fromHub: HubToMachine[] = [
      { t: "welcome", protocol: CLOUD_PROTOCOL_VERSION, connectionId: "conn-2" },
      { t: "peer-gone", peerId: "conn-1" },
      { t: "error", code: "invalid-frame", message: "bad json" },
      { t: "pong" }
    ]
    for (const frame of fromHub) {
      expect(decodeHubToMachine(encodeCloudFrame(frame))).toEqual(frame)
    }
  })

  it("rejects malformed control frames", () => {
    expect(() => decodeAppToHub("{}")).toThrow()
    expect(() => decodeHubToApp('{"t":"nope"}')).toThrow()
    expect(() => decodeMachineToHub('{"t":"hello","protocol":"1"}')).toThrow()
    expect(() => decodeHubToMachine("not json")).toThrow()
  })

  it("exports the terminal channel contract", () => {
    expect(TERMINAL_CHANNEL_TYPE).toBe("terminal")
    expect(CLOUD_PROTOCOL_VERSION).toBe(2)
  })
})

describe("relay envelopes (binary)", () => {
  const frames: RelayFrameHeader[] = [
    { t: "open", channelId: "ch-1", seq: 0, ephemeralKey: "eph" },
    { t: "data", channelId: "ch-1", seq: 1 },
    { t: "credit", channelId: "ch-1", seq: 2, bytes: 65536 },
    { t: "close", channelId: "ch-1", seq: 3, reason: "done" }
  ]

  it("round-trips a batch of envelopes with zero-copy payloads", () => {
    const payloads = [
      new Uint8Array([1, 2, 3]),
      new Uint8Array(256).fill(7),
      new Uint8Array(0),
      new Uint8Array(0)
    ]
    const message = encodeRelayEnvelopes(
      frames.map((frame, index) => ({
        header: { machineId: "m-1", frame },
        payload: payloads[index]!
      }))
    )
    const decoded = decodeRelayEnvelopes(message)
    expect(decoded).toHaveLength(4)
    for (const [index, envelope] of decoded.entries()) {
      expect(envelope.header).toEqual({ machineId: "m-1", frame: frames[index] })
      expect(new Uint8Array(envelope.payload)).toEqual(payloads[index])
    }
  })

  it("decodes payload views at the right offsets within one message", () => {
    const message = encodeRelayEnvelopes([
      { header: { peerId: "p", frame: frames[1] }, payload: new Uint8Array([9, 9]) },
      { header: { peerId: "p", frame: frames[1] }, payload: new Uint8Array([8]) }
    ])
    const [first, second] = decodeRelayEnvelopes(message)
    expect([...first!.payload]).toEqual([9, 9])
    expect([...second!.payload]).toEqual([8])
  })

  it("rejects malformed messages", () => {
    expect(() => decodeRelayEnvelopes(new Uint8Array(0))).toThrow()
    expect(() => decodeRelayEnvelopes(new Uint8Array([0, 0]))).toThrow()
    // Header length pointing past the end.
    expect(() => decodeRelayEnvelopes(new Uint8Array([0, 0, 0, 99, 123]))).toThrow()
    // Valid header, truncated payload.
    const good = encodeRelayEnvelopes([
      { header: { machineId: "m", frame: frames[1] }, payload: new Uint8Array([1, 2, 3, 4]) }
    ])
    expect(() => decodeRelayEnvelopes(good.subarray(0, good.byteLength - 2))).toThrow()
    // Header bytes that are not JSON.
    const bad = new Uint8Array([0, 0, 0, 2, 123, 123, 0, 0, 0, 0])
    expect(() => decodeRelayEnvelopes(bad)).toThrow()
  })

  it("validates frame headers and preserves additive fields", () => {
    for (const frame of frames) {
      expect(parseRelayFrameHeader(frame)).toBe(frame)
    }
    const extended = { t: "data", channelId: "ch", seq: 0, future: true }
    expect(parseRelayFrameHeader(extended)).toBe(extended)

    expect(parseRelayFrameHeader(undefined)).toBeUndefined()
    expect(parseRelayFrameHeader({ t: "data", channelId: "ch" })).toBeUndefined()
    expect(parseRelayFrameHeader({ t: "data", channelId: "ch", seq: -1 })).toBeUndefined()
    expect(parseRelayFrameHeader({ t: "data", channelId: "ch", seq: 0.5 })).toBeUndefined()
    expect(parseRelayFrameHeader({ t: "open", channelId: "ch", seq: 0 })).toBeUndefined()
    expect(parseRelayFrameHeader({ t: "credit", channelId: "ch", seq: 0 })).toBeUndefined()
    expect(
      parseRelayFrameHeader({ t: "credit", channelId: "ch", seq: 0, bytes: 0 })
    ).toBeUndefined()
    expect(
      parseRelayFrameHeader({ t: "close", channelId: "ch", seq: 0, reason: "because" })
    ).toBeUndefined()
    expect(parseRelayFrameHeader({ t: "nope", channelId: "ch", seq: 0 })).toBeUndefined()
  })

  it("validates addressed headers per direction", () => {
    const frame = frames[1]!
    expect(parseAppRelayHeader({ machineId: "m-1", frame })).toEqual({ machineId: "m-1", frame })
    expect(parseAppRelayHeader({ peerId: "p", frame })).toBeUndefined()
    expect(parseAppRelayHeader("nope")).toBeUndefined()
    expect(parseAppRelayHeader({ machineId: "m-1", frame: { t: "data" } })).toBeUndefined()

    expect(parseMachineRelayHeader({ peerId: "conn-1", frame })).toEqual({
      peerId: "conn-1",
      frame
    })
    expect(parseHubToAppRelayHeader({ machineId: "m-1", frame })).toEqual({
      machineId: "m-1",
      frame
    })

    const open = frames[0]!
    expect(
      parseHubToMachineRelayHeader({
        peerId: "conn-1",
        peerPublicKey: "pk",
        peerDeviceId: "app-1",
        frame: open
      })
    ).toEqual({ peerId: "conn-1", peerPublicKey: "pk", peerDeviceId: "app-1", frame: open })
    expect(parseHubToMachineRelayHeader({ peerId: "conn-1", frame })).toEqual({
      peerId: "conn-1",
      frame
    })
    expect(
      parseHubToMachineRelayHeader({ peerId: "conn-1", peerPublicKey: 7, frame })
    ).toBeUndefined()
    expect(
      parseHubToMachineRelayHeader({ peerId: "conn-1", peerDeviceId: 7, frame })
    ).toBeUndefined()
    expect(parseHubToMachineRelayHeader({ machineId: "m-1", frame })).toBeUndefined()
  })
})
