import { openChannel, acceptChannel } from "@codevisor/cloud-crypto"
import { generateDeviceKeyPair } from "@codevisor/cloud-crypto"
import { describe, expect, it } from "vitest"

import { makeLiveChannel, type LiveChannel } from "./incoming-channel.js"

const makeGated = (ready: () => boolean) => {
  const machineKeys = generateDeviceKeyPair()
  const appKeys = generateDeviceKeyPair()
  const opened = openChannel(appKeys.secretKey, machineKeys.publicKey)
  const cipher = acceptChannel(machineKeys.secretKey, appKeys.publicKey, opened.ephemeralPublicKey)
  const sent: unknown[] = []
  let current: LiveChannel | undefined
  const live = makeLiveChannel({
    channelId: "c-1",
    peerId: "app-1",
    peer: { deviceId: "app-1", publicKey: appKeys.publicKey },
    channelType: "echo",
    params: undefined,
    cipher,
    compressed: false,
    flowControl: true,
    current: () => current,
    remove: () => {
      current = undefined
    },
    ready,
    sendEnvelope: (frame) => sent.push(frame)
  })
  current = live
  return { live, sent, drop: () => (current = undefined) }
}

describe("makeLiveChannel", () => {
  it("holds queued sends while the pipe is unready, even with credit in hand", () => {
    let ready = true
    const { live, sent } = makeGated(() => ready)
    live.channel.send({ n: 1 })
    expect(sent).toHaveLength(0)

    ready = false
    expect(live.receiveCredit(10_000)).toBe(true)
    expect(sent).toHaveLength(0)
    expect(live.channel.queuedOutboundBytes()).toBeGreaterThan(0)
  })

  it("treats credit for an already-removed channel as a harmless no-op", () => {
    const { live, sent, drop } = makeGated(() => true)
    drop()
    expect(live.receiveCredit(1024)).toBe(true)
    expect(sent).toHaveLength(0)
  })
})
