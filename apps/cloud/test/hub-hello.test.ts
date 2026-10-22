import { CLOUD_PROTOCOL_VERSION, encodeCloudFrame } from "@codevisor/api"
import { env, runInDurableObject } from "cloudflare:test"
import { afterEach, expect, it, vi } from "vitest"

import { SocketAttachment } from "../src/hub-schema.js"
import {
  CLOSE_DELIVERY_FAILED,
  CLOSE_UNSUPPORTED_PROTOCOL,
  HUB_DEVICE_ID_HEADER,
  HUB_KIND_HEADER,
  type UserHub
} from "../src/user-hub.js"

afterEach(() => vi.restoreAllMocks())

const kinds = ["app", "machine"] as const
type Kind = (typeof kinds)[number]

const hubNamed = (name: string) => env.USER_HUB.get(env.USER_HUB.idFromName(name))

const connectToHub = async (
  hub: UserHub,
  state: DurableObjectState,
  kind: Kind
): Promise<WebSocket> => {
  const response = await hub.fetch(
    new Request("https://hub.test/connect", {
      headers: {
        [HUB_KIND_HEADER]: kind,
        [HUB_DEVICE_ID_HEADER]: `${kind}-device`,
        Upgrade: "websocket"
      }
    })
  )
  response.webSocket?.accept()
  const [socket] = state.getWebSockets(kind)
  if (socket === undefined) throw new Error(`hub did not accept the ${kind} socket`)
  return socket
}

const hello = (kind: Kind, protocol = CLOUD_PROTOCOL_VERSION): string =>
  encodeCloudFrame({
    t: "hello",
    protocol,
    device: {
      deviceId: `${kind}-device`,
      kind,
      name: `${kind} under test`,
      publicKey: `${kind}-key`
    }
  })

const holdFirstDigest = () => {
  let signalEntered!: () => void
  const entered = new Promise<void>((resolve) => {
    signalEntered = resolve
  })
  let release!: () => void
  const released = new Promise<void>((resolve) => {
    release = resolve
  })
  const digest = crypto.subtle.digest.bind(crypto.subtle)
  vi.spyOn(crypto.subtle, "digest").mockImplementationOnce(async (algorithm, data) => {
    signalEntered()
    await released
    return digest(algorithm, data)
  })
  return { entered, release }
}

const rowCount = (state: DurableObjectState, table: "sessions" | "machines"): number =>
  state.storage.sql.exec(`SELECT * FROM ${table}`).toArray().length

const sessionExpiry = (state: DurableObjectState): SqlStorageValue | undefined =>
  state.storage.sql.exec("SELECT expires_at FROM sessions").one().expires_at

const helloDone = (socket: WebSocket): boolean =>
  SocketAttachment.parse(socket.deserializeAttachment()).helloDone

const sentFrames = (send: { mock: { calls: unknown[][] } }): unknown[] =>
  send.mock.calls.map(([message]) => JSON.parse(String(message)))

it.each(kinds)("answers a ping from the %s that the auto-response does not match", async (kind) => {
  await runInDurableObject(hubNamed(`unmatched-ping-${kind}`), async (hub, state) => {
    const socket = await connectToHub(hub, state, kind)
    const sent = vi.spyOn(socket, "send")

    await hub.webSocketMessage(socket, '{ "t": "ping" }')

    expect(sentFrames(sent)).toEqual([{ t: "pong" }])
  })
})

it.each([
  ["app", "update Codevisor to use this relay"],
  ["machine", "update the Codevisor server to use this relay"]
] as const)(
  "tells the %s on an unsupported protocol to update, then closes it",
  async (kind, hint) => {
    await runInDurableObject(hubNamed(`unsupported-protocol-${kind}`), async (hub, state) => {
      const socket = await connectToHub(hub, state, kind)
      const sent = vi.spyOn(socket, "send")
      const closed = vi.spyOn(socket, "close")

      await hub.webSocketMessage(socket, hello(kind, CLOUD_PROTOCOL_VERSION + 1))

      expect(sentFrames(sent)).toEqual([
        { t: "error", code: "unsupported-protocol", message: hint }
      ])
      expect(closed).toHaveBeenCalledWith(CLOSE_UNSUPPORTED_PROTOCOL, "unsupported protocol")
      expect(rowCount(state, "sessions")).toBe(0)
    })
  }
)

it.each(kinds)("ignores the %s hello when the account is deleted during adoption", async (kind) => {
  await runInDurableObject(hubNamed(`deleted-mid-hello-${kind}`), async (hub, state) => {
    const socket = await connectToHub(hub, state, kind)
    const adoption = holdFirstDigest()
    const handled = hub.webSocketMessage(socket, hello(kind))
    try {
      await adoption.entered
      await hub.deleteAccount()
    } finally {
      adoption.release()
      await handled
    }

    expect(rowCount(state, "sessions")).toBe(0)
    expect(rowCount(state, "machines")).toBe(0)
    expect(helloDone(socket)).toBe(false)
  })
})

it.each(kinds)("retires the %s socket whose welcome cannot be delivered", async (kind) => {
  await runInDurableObject(hubNamed(`undeliverable-welcome-${kind}`), async (hub, state) => {
    const socket = await connectToHub(hub, state, kind)
    const sent = vi.spyOn(socket, "send").mockImplementation(() => {
      throw new Error("peer reset")
    })
    const closed = vi.spyOn(socket, "close")

    await hub.webSocketMessage(socket, hello(kind))

    expect(sentFrames(sent)).toMatchObject([{ t: "welcome" }])
    expect(closed).toHaveBeenCalledWith(CLOSE_DELIVERY_FAILED, "relay delivery failed")
    expect(helloDone(socket)).toBe(false)
    expect(sessionExpiry(state)).not.toBeNull()
  })
})
