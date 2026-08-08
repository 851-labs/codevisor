import { describe, expect, it } from "vitest"
import {
  CLOUD_PROTOCOL_VERSION,
  TERMINAL_CHANNEL_TYPE,
  decodeAppToHub,
  decodeHubToApp,
  decodeHubToMachine,
  decodeMachineToHub,
  encodeCloudFrame,
  type AppToHub,
  type CloudDeviceInfo,
  type CloudMachinePresence,
  type HubToApp,
  type HubToMachine,
  type MachineToHub,
  type RelayFrame
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

const sealed = { box: "Ym94" }

const relayFrames: RelayFrame[] = [
  { t: "open", channelId: "ch-1", seq: 0, ephemeralKey: "eph", sealed },
  { t: "data", channelId: "ch-1", seq: 1, sealed },
  { t: "credit", channelId: "ch-1", seq: 2, bytes: 65536 },
  { t: "close", channelId: "ch-1", seq: 3, reason: "done" }
]

describe("app plane", () => {
  it("round-trips every app→hub frame", () => {
    const frames: AppToHub[] = [
      { t: "hello", protocol: CLOUD_PROTOCOL_VERSION, device: appDevice },
      ...relayFrames.map((frame): AppToHub => ({ t: "relay", machineId: "m-1", frame })),
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
      { t: "relay", machineId: "m-1", frame: relayFrames[1]! },
      { t: "error", code: "machine-offline", message: "gone", machineId: "m-1", channelId: "ch-1" },
      { t: "error", code: "unsupported-protocol", message: "too old" },
      { t: "pong" }
    ]
    for (const frame of frames) {
      expect(decodeHubToApp(encodeCloudFrame(frame))).toEqual(frame)
    }
  })
})

describe("machine plane", () => {
  it("round-trips every machine→hub frame", () => {
    const frames: MachineToHub[] = [
      {
        t: "hello",
        protocol: CLOUD_PROTOCOL_VERSION,
        device: { deviceId: "m-1", kind: "machine", name: "dev-vps", publicKey: "machine-pub" }
      },
      ...relayFrames.map((frame): MachineToHub => ({ t: "relay", peerId: "conn-1", frame })),
      { t: "ping" }
    ]
    for (const frame of frames) {
      expect(decodeMachineToHub(encodeCloudFrame(frame))).toEqual(frame)
    }
  })

  it("round-trips every hub→machine frame", () => {
    const frames: HubToMachine[] = [
      { t: "welcome", protocol: CLOUD_PROTOCOL_VERSION, connectionId: "conn-2" },
      { t: "relay", peerId: "conn-1", peerPublicKey: "app-pub", frame: relayFrames[0]! },
      { t: "relay", peerId: "conn-1", frame: relayFrames[3]! },
      { t: "peer-gone", peerId: "conn-1" },
      { t: "error", code: "invalid-frame", message: "bad json" },
      { t: "pong" }
    ]
    for (const frame of frames) {
      expect(decodeHubToMachine(encodeCloudFrame(frame))).toEqual(frame)
    }
  })
})

describe("validation", () => {
  it("rejects malformed frames", () => {
    expect(() => decodeAppToHub("{}")).toThrow()
    expect(() => decodeAppToHub('{"t":"relay","machineId":"m-1","frame":{"t":"data"}}')).toThrow()
    expect(() => decodeHubToApp('{"t":"nope"}')).toThrow()
    expect(() => decodeMachineToHub('{"t":"hello","protocol":"1"}')).toThrow()
    expect(() => decodeHubToMachine("not json")).toThrow()
    expect(() =>
      decodeAppToHub(
        JSON.stringify({
          t: "relay",
          machineId: "m-1",
          frame: { t: "close", channelId: "ch-1", seq: 0, reason: "because" }
        })
      )
    ).toThrow()
  })

  it("exports the terminal channel contract", () => {
    expect(TERMINAL_CHANNEL_TYPE).toBe("terminal")
    expect(CLOUD_PROTOCOL_VERSION).toBe(1)
  })
})
