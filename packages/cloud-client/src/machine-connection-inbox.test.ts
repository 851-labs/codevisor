import { CLOUD_PROTOCOL_VERSION, type HubInboxItem } from "@codevisor/api"
import { generateDeviceKeyPair, openChannel, sealJson, toBase64Url } from "@codevisor/cloud-crypto"
import { describe, expect, it, vi } from "vitest"

import { CloudMachineConnection, openInboxItem } from "./index.js"
import { credentials, FakeSocket } from "./machine-connection-test-support.js"

const inboxConnection = (onInboxItem?: (item: HubInboxItem) => void) => {
  const sockets: FakeSocket[] = []
  const connection = new CloudMachineConnection({
    credentials,
    device: { name: "studio" },
    socketFactory: () => {
      const socket = new FakeSocket()
      sockets.push(socket)
      return socket
    },
    channelHandlers: {},
    ...(onInboxItem === undefined ? {} : { onInboxItem }),
    scheduleReconnect: vi.fn(),
    scheduleTimeout: () => () => undefined
  })
  connection.start()
  const socket = sockets[0]!
  socket.onopen?.()
  return { connection, socket }
}

const item: HubInboxItem = {
  t: "inbox-item",
  itemId: "item-1",
  kind: "webhook",
  sender: "sender",
  ephemeralKey: "ephemeral",
  sealed: "sealed"
}

describe("cloud inbox items on the machine connection", () => {
  it("hands sealed inbox items to the machine", () => {
    const received: HubInboxItem[] = []
    const { socket } = inboxConnection((frame) => received.push(frame))
    socket.receive(item)
    expect(received).toEqual([item])
    inboxConnection().socket.receive(item)
  })

  it("acks handled items only while connected", () => {
    const { connection, socket } = inboxConnection()
    expect(connection.ackInboxItems(["item-1"])).toBe(false)

    socket.receive({ t: "welcome", protocol: CLOUD_PROTOCOL_VERSION, connectionId: "c1" })
    expect(connection.ackInboxItems([])).toBe(true)
    expect(connection.ackInboxItems(["item-1", "item-2"])).toBe(true)
    expect(socket.sent.at(-1)).toEqual({ t: "inbox-ack", itemIds: ["item-1", "item-2"] })
  })
})

describe("opening sealed inbox items", () => {
  it("opens an item sealed by the hub to this device's key", () => {
    const device = generateDeviceKeyPair()
    const sender = generateDeviceKeyPair()
    const opened = openChannel(sender.secretKey, device.publicKey)
    const payload = { flowId: "flow-1", state: "flow-1.device.nonce", code: "abc" }
    const frame: HubInboxItem = {
      t: "inbox-item",
      itemId: "item-7",
      kind: "oauth",
      sender: sender.publicKey,
      ephemeralKey: opened.ephemeralPublicKey,
      sealed: toBase64Url(sealJson(opened.cipher, "item-7", "opener-to-responder", 0, payload))
    }
    expect(openInboxItem(device.secretKey, frame)).toEqual(payload)
  })
})
