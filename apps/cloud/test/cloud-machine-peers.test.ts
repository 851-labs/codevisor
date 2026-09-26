import {
  MACHINE_PEERS_FEATURE,
  type HubToAppRelayHeader,
  type HubToMachine,
  type HubToMachineRelayHeader
} from "@codevisor/api"
import { acceptChannel, openChannel, openJson, sealJson } from "@codevisor/cloud-crypto"
import { describe, expect, it } from "vitest"

import {
  connectMachine,
  devLogin,
  disconnect,
  expireResumeGrace,
  sendRelay
} from "./cloud-test-support.js"

const peerAware = { features: [MACHINE_PEERS_FEATURE] }

const open = (channelId: string) => ({ t: "open", channelId, seq: 0, ephemeralKey: "key" }) as const

/// Skips unrelated presence noise (other machines connecting) up to the
/// first control frame of the wanted kind.
const nextOfKind = async <Kind extends HubToMachine["t"]>(
  reader: { next: () => Promise<HubToMachine> },
  kind: Kind
): Promise<Extract<HubToMachine, { t: Kind }>> => {
  for (;;) {
    const frame = await reader.next()
    if (frame.t === kind) return frame as Extract<HubToMachine, { t: Kind }>
  }
}

describe("machine peers", () => {
  it("gives peer-aware machines the account's machines and their presence", async () => {
    const token = await devLogin()
    const existing = await connectMachine(token, "studio", undefined, {
      serverId: "machine-studio"
    })
    const observer = await connectMachine(token, "laptop", undefined, peerAware)
    const listed = observer.welcome.machines?.find((m) => m.deviceId === existing.deviceId)
    expect(listed).toMatchObject({ name: "studio", serverId: "machine-studio", online: true })
    // It never advertised machine peers, so it is not a channel target.
    expect(listed?.machinePeers).toBeUndefined()
    // Machines that never advertised the feature keep the old welcome shape.
    expect(existing.welcome.machines).toBeUndefined()

    await disconnect(token, existing.socket, "bye")
    await expireResumeGrace(token)
    expect(await nextOfKind(observer.reader, "presence")).toMatchObject({
      t: "presence",
      machine: { deviceId: existing.deviceId, online: false }
    })
  })

  it("relays a sealed machine→machine channel within the account", async () => {
    const token = await devLogin()
    const target = await connectMachine(token, "target", undefined, peerAware)
    const opener = await connectMachine(token, "opener", undefined, peerAware)

    const channel = openChannel(opener.keys.secretKey, target.keys.publicKey)
    const request = { channelType: "gateway", params: { path: "search" } }
    sendRelay(
      opener.socket,
      {
        machineId: target.deviceId,
        frame: { t: "open", channelId: "g-1", seq: 0, ephemeralKey: channel.ephemeralPublicKey }
      },
      sealJson(channel.cipher, "g-1", "opener-to-responder", 0, request)
    )
    const opened = await target.reader.nextEnvelope()
    const header = opened.header as HubToMachineRelayHeader
    // The target learns the opener is a machine (it gates channel types on
    // that) and gets its key + device id to agree keys and TOFU-pin.
    expect(header).toMatchObject({
      peerKind: "machine",
      peerDeviceId: opener.deviceId,
      peerPublicKey: opener.keys.publicKey
    })
    const frame = header.frame as Extract<typeof header.frame, { t: "open" }>
    const responder = acceptChannel(
      target.keys.secretKey,
      header.peerPublicKey!,
      frame.ephemeralKey
    )
    expect(openJson(responder, "g-1", "opener-to-responder", 0, opened.payload)).toEqual(request)

    sendRelay(
      target.socket,
      { peerId: header.peerId, frame: { t: "data", channelId: "g-1", seq: 0 } },
      sealJson(responder, "g-1", "responder-to-opener", 0, { ok: true })
    )
    const answered = await opener.reader.nextEnvelope()
    expect((answered.header as HubToAppRelayHeader).machineId).toBe(target.deviceId)
    expect(openJson(channel.cipher, "g-1", "responder-to-opener", 0, answered.payload)).toEqual({
      ok: true
    })
  })

  it("refuses machine-opened channels to unknown, legacy, or self targets, and from legacy machines", async () => {
    const token = await devLogin()
    const opener = await connectMachine(token, "opener", undefined, peerAware)
    const legacy = await connectMachine(token, "legacy")

    // Another account's machine is not in this account's registry: to the
    // hub it is indistinguishable from an id that never existed.
    sendRelay(opener.socket, { machineId: "other-account-machine", frame: open("c-1") })
    expect(await nextOfKind(opener.reader, "error")).toMatchObject({
      code: "unknown-machine",
      machineId: "other-account-machine",
      channelId: "c-1"
    })
    sendRelay(opener.socket, { machineId: opener.deviceId, frame: open("c-2") })
    expect(await nextOfKind(opener.reader, "error")).toMatchObject({
      code: "unknown-machine",
      channelId: "c-2"
    })

    // A legacy machine would not restrict machine openers to the gateway
    // channel, so the hub never routes machine-opened channels to it.
    sendRelay(opener.socket, { machineId: legacy.deviceId, frame: open("c-4") })
    expect(await nextOfKind(opener.reader, "error")).toMatchObject({
      code: "unknown-machine",
      channelId: "c-4"
    })

    sendRelay(legacy.socket, { machineId: opener.deviceId, frame: open("c-3") })
    expect(await nextOfKind(legacy.reader, "error")).toMatchObject({ code: "invalid-frame" })
  })

  it("tells target machines when an opener machine is gone for good", async () => {
    const token = await devLogin()
    const target = await connectMachine(token, "target", undefined, peerAware)
    const opener = await connectMachine(token, "opener", undefined, peerAware)
    await disconnect(token, opener.socket, "quit")
    await expireResumeGrace(token)
    // Channels the opener held on the target die with it.
    expect(await nextOfKind(target.reader, "peer-gone")).toEqual({
      t: "peer-gone",
      peerId: opener.welcome.connectionId
    })
  })
})
