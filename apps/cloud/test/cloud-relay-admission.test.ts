import {
  CLOUD_PROTOCOL_VERSION,
  decodeHubToApp,
  decodeHubToMachine,
  encodeCloudFrame,
  encodeRelayEnvelopes,
  type HubToApp,
  type HubToMachine
} from "@codevisor/api"
import { generateDeviceKeyPair } from "@codevisor/cloud-crypto"
import { SELF } from "cloudflare:test"
import { expect, it, type TestContext } from "vitest"

import {
  authed,
  BASE,
  connectSocket,
  devLogin,
  disconnect,
  sendRelay,
  SocketReader
} from "./cloud-test-support.js"

// Register cleanup before any hello or reader assertion can fail.
const ownedSocket = async (
  context: TestContext,
  token: string,
  headers: Record<string, string>
) => {
  const socket = await connectSocket(headers)
  context.onTestFinished(() => disconnect(token, socket, "admission test complete"))
  return socket
}

const machineFixture = async (context: TestContext, token: string) => {
  const deviceId = crypto.randomUUID()
  const keys = generateDeviceKeyPair()
  const created = await SELF.fetch(`${BASE}/api/auth/api-key/create`, {
    method: "POST",
    headers: { "content-type": "application/json", ...authed(token) },
    body: JSON.stringify({
      name: "admission-machine",
      metadata: { deviceId, publicKey: keys.publicKey }
    })
  })
  expect(created.status).toBe(200)
  const { key } = (await created.json()) as { key: string }
  const socket = await ownedSocket(context, token, { "x-api-key": key })
  const reader = new SocketReader<HubToMachine>(socket, decodeHubToMachine)
  socket.send(
    encodeCloudFrame({
      t: "hello",
      protocol: CLOUD_PROTOCOL_VERSION,
      device: {
        deviceId,
        kind: "machine",
        name: "admission-machine",
        os: "linux",
        publicKey: keys.publicKey
      }
    })
  )
  expect(await reader.next()).toMatchObject({ t: "welcome", protocol: CLOUD_PROTOCOL_VERSION })
  return { deviceId, reader }
}

const helloApp = async (socket: WebSocket, reader: SocketReader<HubToApp>) => {
  socket.send(
    encodeCloudFrame({
      t: "hello",
      protocol: CLOUD_PROTOCOL_VERSION,
      device: {
        deviceId: crypto.randomUUID(),
        kind: "app",
        name: "Admission App",
        os: "macOS",
        publicKey: generateDeviceKeyPair().publicKey
      }
    })
  )
  const welcome = await reader.next()
  expect(welcome).toMatchObject({ t: "welcome", protocol: CLOUD_PROTOCOL_VERSION })
  if (welcome.t !== "welcome") throw new Error("expected app welcome")
  return welcome
}

it("orders size, hello and decoding diagnostics and recovers on the same socket", async (context) => {
  const token = await devLogin()
  const machine = await machineFixture(context, token)
  const socket = await ownedSocket(context, token, authed(token))
  const reader = new SocketReader<HubToApp>(socket, decodeHubToApp)
  for (const [size, message] of [
    [2097153, "relay message exceeds the size limit"],
    [4, "hello required before relaying"],
    [2097152, "hello required before relaying"]
  ] as const) {
    const malformed = new Uint8Array(size)
    malformed.fill(255, 0, 4) // Impossible header length, regardless of trailing bytes.
    expect(malformed.byteLength).toBe(size)
    const error = reader.next()
    socket.send(malformed)
    expect(await error).toEqual({ t: "error", code: "invalid-frame", message })
  }

  const welcome = await helloApp(socket, reader)
  for (const [bytes, message] of [
    [new Uint8Array(0), "malformed relay message"],
    [new Uint8Array([0, 0, 0, 99]), "malformed relay message"],
    [
      encodeRelayEnvelopes([{ header: { nope: true }, payload: new Uint8Array(0) }]),
      "malformed relay header"
    ]
  ] as const) {
    const error = reader.next()
    socket.send(bytes)
    expect(await error).toEqual({ t: "error", code: "invalid-frame", message })
    // Delivery acknowledges recovery after each distinct rejection.
    const relayed = machine.reader.nextEnvelope()
    sendRelay(
      socket,
      {
        machineId: machine.deviceId,
        frame: { t: "data", channelId: "diagnostic-recovery", seq: 7 }
      },
      new Uint8Array([19, 0, 255])
    )
    expect(await relayed).toEqual({
      header: {
        peerId: welcome.connectionId,
        frame: { t: "data", channelId: "diagnostic-recovery", seq: 7 }
      },
      payload: new Uint8Array([19, 0, 255])
    })
  }
})

it("accepts an actual 2097152-byte relay and refuses 2097153 bytes with recovery", async (context) => {
  const token = await devLogin()
  const machine = await machineFixture(context, token)
  const socket = await ownedSocket(context, token, authed(token))
  const reader = new SocketReader<HubToApp>(socket, decodeHubToApp)
  const welcome = await helloApp(socket, reader)
  const frame = { t: "data", channelId: "exact-limit", seq: 11 } as const
  const header = { machineId: machine.deviceId, frame }
  const overhead = encodeRelayEnvelopes([{ header, payload: new Uint8Array(0) }]).byteLength
  const payload = Uint8Array.from({ length: 2097152 - overhead }, (_, index) => index % 251)
  const accepted = encodeRelayEnvelopes([{ header, payload }])
  expect(accepted.byteLength).toBe(2097152)
  const delivered = machine.reader.nextEnvelope()
  socket.send(accepted)
  const envelope = await delivered
  expect(envelope.header).toEqual({
    peerId: welcome.connectionId,
    frame: { t: "data", channelId: "exact-limit", seq: 11 }
  })
  expect(envelope.payload.byteLength).toBe(2097152 - overhead)
  // Deep object equality enumerates millions of properties for this payload.
  expect(envelope.payload.every((byte, index) => byte === payload[index])).toBe(true)

  const refused = encodeRelayEnvelopes([{ header, payload: new Uint8Array(payload.length + 1) }])
  expect(refused.byteLength).toBe(2097153)
  const error = reader.next()
  socket.send(refused)
  expect(await error).toEqual({
    t: "error",
    code: "invalid-frame",
    message: "relay message exceeds the size limit"
  })
  const recovered = machine.reader.nextEnvelope()
  sendRelay(
    socket,
    {
      machineId: machine.deviceId,
      frame: { t: "data", channelId: "size-recovery", seq: 12 }
    },
    new Uint8Array([42, 128, 0])
  )
  expect(await recovered).toEqual({
    header: {
      peerId: welcome.connectionId,
      frame: { t: "data", channelId: "size-recovery", seq: 12 }
    },
    payload: new Uint8Array([42, 128, 0])
  })
  expect(machine.reader.binaryMessages).toBe(2)
})
