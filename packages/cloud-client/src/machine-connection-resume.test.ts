import { CLOUD_PROTOCOL_VERSION } from "@codevisor/api"
import { generateDeviceKeyPair, openChannel, openJson, sealJson } from "@codevisor/cloud-crypto"
import { describe, expect, it } from "vitest"

import { makePeerKeyPinStore } from "./index.js"
import type { IncomingChannel } from "./index.js"
import {
  FakeSocket,
  machineKeys,
  harness,
  activeTimeout,
  connect,
  openEcho
} from "./machine-connection-test-support.js"
import type { Harness } from "./machine-connection-test-support.js"

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

describe("session resume", () => {
  it("holds channels across a resumed reconnect and replays retained frames in order", () => {
    const h = harness()
    const socket = connectResumable(h, "tok-1")
    const { opened } = openEcho(socket, "peer-1", "ch-1")
    const channel = h.channels[0]!
    const closes: string[] = []
    channel.onClosed = (reason) => closes.push(reason)

    socket.onclose?.(1006)
    channel.send({ output: "during-gap-1" })
    channel.send({ output: "during-gap-2" })
    expect(closes).toEqual([])

    h.reconnects[0]!.callback()
    const revived = h.sockets.at(-1)!
    revived.onopen?.()
    const hello = revived.hello()
    expect(hello.resume).toBe("tok-1")

    revived.receive({
      t: "welcome",
      protocol: CLOUD_PROTOCOL_VERSION,
      connectionId: "conn-m",
      resume: "tok-2",
      resumed: true
    })
    const frames = revived.sentRelay.filter((envelope) => envelope.header.frame.t === "data")
    expect(frames.map((envelope) => envelope.header.frame.seq)).toEqual([0, 1])
    expect(openJson(opened.cipher, "ch-1", "responder-to-opener", 1, frames[1]!.payload)).toEqual({
      output: "during-gap-2"
    })
    expect(closes).toEqual([])

    channel.send({ output: "after-resume" })
    expect(
      revived.sentRelay.findLast((envelope) => envelope.header.frame.t === "data")!.header.frame.seq
    ).toEqual(2)
    expect(h.welcomes).toEqual([
      { resumed: false, replayedFrames: 0 },
      { resumed: true, replayedFrames: 2 }
    ])
  })

  it("drains a coalescing outbox into the retention buffer on suspend", () => {
    const h = harness({ relayCoalesceMs: 5 })
    const socket = connectResumable(h, "tok-1")
    const { opened } = openEcho(socket, "peer-1", "ch-1")
    const channel = h.channels[0]!

    channel.send({ output: "unflushed" })
    expect(socket.relayMessages).toHaveLength(0)
    const flushTimer = activeTimeout(h, 5)
    socket.onclose?.(1006)
    flushTimer.invoke()

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

    h.reconnects[0]!.callback()
    const revived = h.sockets.at(-1)!
    revived.onopen?.()
    const hello = revived.hello()
    expect(hello.resume).toBeUndefined()
  })

  it("answers pre-welcome relay frames on the young socket", () => {
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
