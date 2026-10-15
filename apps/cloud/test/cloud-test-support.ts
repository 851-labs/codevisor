import {
  CLOUD_PROTOCOL_VERSION,
  decodeHubToApp,
  decodeHubToMachine,
  decodeRelayEnvelopes,
  encodeCloudFrame,
  encodeRelayEnvelopes,
  parseHubToAppRelayHeader,
  parseHubToMachineRelayHeader,
  type HubToApp,
  type HubToAppRelayHeader,
  type HubToMachine,
  type HubToMachineRelayHeader,
  type WireRelayEnvelope
} from "@codevisor/api"
import { generateDeviceKeyPair } from "@codevisor/cloud-crypto"
import { env, runInDurableObject, SELF } from "cloudflare:test"
import { afterEach, beforeEach, expect, vi } from "vitest"

import type { UserHub } from "../src/user-hub.js"
import { KeyBody, readJson, SessionUserBody, TokenBody } from "./json-test-support.js"

export const BASE = "http://localhost:8787"

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] })
  vi.setSystemTime(new Date("2100-01-01T00:00:00Z"))
})
afterEach(() => vi.useRealTimers())

export const devLogin = async (): Promise<string> => {
  const response = await SELF.fetch(`${BASE}/dev/login`, { method: "POST" })
  expect(response.status).toBe(200)
  const body = await readJson(response, TokenBody)
  expect(body.token).toBeTruthy()
  return body.token
}

export const authed = (token: string): Record<string, string> => ({
  authorization: `Bearer ${token}`
})

const hubStub = async (token: string): Promise<DurableObjectStub<UserHub>> => {
  const session = await SELF.fetch(`${BASE}/api/auth/get-session`, { headers: authed(token) })
  const body = await readJson(session, SessionUserBody)
  if (body === null) throw new Error("no session user for hub stub")
  return env.USER_HUB.get(env.USER_HUB.idFromName(body.user.id))
}

export const disconnect = async (
  token: string,
  socket: WebSocket,
  reason: string
): Promise<void> => {
  const stub = await hubStub(token)
  let acknowledgeClose!: () => void
  const closed = new Promise<void>((resolve) => {
    acknowledgeClose = resolve
  })
  let restore: (() => void) | undefined
  await runInDurableObject(stub, (hub) => {
    const close = hub.webSocketClose.bind(hub)
    const observed = vi.spyOn(hub, "webSocketClose").mockImplementation(async (closing) => {
      await close(closing)
      acknowledgeClose()
    })
    restore = () => observed.mockRestore()
  })
  try {
    socket.close(1000, reason)
    await runInDurableObject(stub, async () => {
      await closed
    })
  } finally {
    await runInDurableObject(stub, () => {
      restore?.()
    })
  }
}

export const expireResumeGrace = async (token: string): Promise<void> => {
  const stub = await hubStub(token)
  await runInDurableObject(stub, async (hub, state) => {
    const deadline = await state.storage.getAlarm()
    expect(deadline).not.toBeNull()
    vi.setSystemTime(deadline! + 1)
    await hub.alarm()
  })
}

export class Queue<Item> {
  #items: Item[] = []
  #waiters: ((item: Item) => void)[] = []

  push(item: Item): void {
    const waiter = this.#waiters.shift()
    if (waiter !== undefined) waiter(item)
    else this.#items.push(item)
  }

  async next(): Promise<Item> {
    const item = this.#items.shift()
    if (item !== undefined) return item
    return new Promise<Item>((resolve) => {
      this.#waiters.push(resolve)
    })
  }
}

export const expectDefined = <Value>(value: Value): NonNullable<Value> => {
  if (value === undefined || value === null) throw new Error("expected a defined value")
  return value
}

export const hasTag = <Value extends { t: string }, Tag extends Value["t"]>(
  value: Value,
  t: Tag
): value is Extract<Value, { t: Tag }> => value.t === t

export const expectTag = <Value extends { t: string }, Tag extends Value["t"]>(
  value: Value,
  t: Tag
): Extract<Value, { t: Tag }> => {
  if (!hasTag(value, t)) throw new Error(`expected a ${t} frame, got ${value.t}`)
  return value
}

export const machineRelayHeader = (envelope: WireRelayEnvelope): HubToMachineRelayHeader => {
  const header = parseHubToMachineRelayHeader(envelope.header)
  if (header === undefined) throw new Error("expected a hub-to-machine relay header")
  return header
}

export const appRelayHeader = (envelope: WireRelayEnvelope): HubToAppRelayHeader => {
  const header = parseHubToAppRelayHeader(envelope.header)
  if (header === undefined) throw new Error("expected a hub-to-app relay header")
  return header
}

export class SocketReader<Frame extends { t: string }> {
  readonly #controls = new Queue<Frame>()
  readonly #envelopes = new Queue<WireRelayEnvelope>()
  binaryMessages = 0
  #chain: Promise<void> = Promise.resolve()

  constructor(socket: WebSocket, decode: (raw: string) => Frame) {
    socket.addEventListener("message", (event) => {
      if (typeof event.data === "string") {
        this.#controls.push(decode(event.data))
        return
      }
      this.binaryMessages += 1
      const data: unknown = event.data
      this.#chain = this.#chain.then(async () => {
        const buffer = data instanceof Blob ? await data.arrayBuffer() : data
        if (!(buffer instanceof ArrayBuffer)) throw new Error("unexpected binary message type")
        for (const envelope of decodeRelayEnvelopes(new Uint8Array(buffer))) {
          this.#envelopes.push({ ...envelope, payload: new Uint8Array(envelope.payload) })
        }
      })
    })
  }

  async next(): Promise<Frame> {
    return this.#controls.next()
  }

  async nextFrame<Tag extends Frame["t"]>(t: Tag): Promise<Extract<Frame, { t: Tag }>> {
    return expectTag(await this.#controls.next(), t)
  }

  async nextEnvelope(): Promise<WireRelayEnvelope> {
    return this.#envelopes.next()
  }
}

export const sendRelay = (
  socket: WebSocket,
  header: unknown,
  payload: Uint8Array = new Uint8Array(0)
): void => socket.send(encodeRelayEnvelopes([{ header, payload }]))

export const connectSocket = async (headers: Record<string, string>): Promise<WebSocket> => {
  const response = await SELF.fetch(`${BASE}/connect`, {
    headers: { Upgrade: "websocket", ...headers }
  })
  expect(response.status).toBe(101)
  const socket = response.webSocket
  if (socket === null) throw new Error("no websocket on upgrade response")
  socket.accept()
  return socket
}

export interface MachineSetup {
  token: string
  apiKey: string
  deviceId: string
  keys: ReturnType<typeof generateDeviceKeyPair>
  socket: WebSocket
  reader: SocketReader<HubToMachine>
  welcome: Extract<HubToMachine, { t: "welcome" }>
}

export const connectMachine = async (
  token: string,
  name: string,
  deviceId = crypto.randomUUID(),
  options: {
    apiKey?: string
    keys?: ReturnType<typeof generateDeviceKeyPair>
    resume?: string
    features?: string[]
    serverId?: string
    tunnelEndpointId?: string
    releaseChannel?: "stable" | "alpha"
  } = {}
): Promise<MachineSetup> => {
  const keys = options.keys ?? generateDeviceKeyPair()
  let apiKey = options.apiKey
  if (apiKey === undefined) {
    const created = await SELF.fetch(`${BASE}/api/auth/api-key/create`, {
      method: "POST",
      headers: { "content-type": "application/json", ...authed(token) },
      body: JSON.stringify({ name, metadata: { deviceId, publicKey: keys.publicKey } })
    })
    expect(created.status).toBe(200)
    apiKey = (await readJson(created, KeyBody)).key
  }
  const tunnel = options.tunnelEndpointId
  const socket = await connectSocket({
    "x-api-key": apiKey,
    ...(tunnel === undefined ? {} : { "x-codevisor-tunnel-endpoint": tunnel })
  })
  const reader = new SocketReader(socket, decodeHubToMachine)
  socket.send(
    encodeCloudFrame({
      t: "hello",
      protocol: CLOUD_PROTOCOL_VERSION,
      device: {
        deviceId,
        kind: "machine",
        name,
        os: "linux",
        publicKey: keys.publicKey,
        ...(options.serverId === undefined ? {} : { serverId: options.serverId }),
        ...(tunnel === undefined ? {} : { tunnelEndpointId: tunnel }),
        ...(options.releaseChannel === undefined ? {} : { releaseChannel: options.releaseChannel })
      },
      ...(options.resume === undefined ? {} : { resume: options.resume }),
      ...(options.features === undefined ? {} : { features: options.features })
    })
  )
  const welcome = await reader.nextFrame("welcome")
  expect(welcome).toMatchObject({ t: "welcome", protocol: CLOUD_PROTOCOL_VERSION })
  return { token, apiKey, deviceId, keys, socket, reader, welcome }
}

export interface AppSetup {
  keys: ReturnType<typeof generateDeviceKeyPair>
  socket: WebSocket
  reader: SocketReader<HubToApp>
  welcome: Extract<HubToApp, { t: "welcome" }>
  deviceId: string
}

export const connectApp = async (
  token: string,
  options: {
    keys?: ReturnType<typeof generateDeviceKeyPair>
    deviceId?: string
    resume?: string
    tunnelEndpointId?: string
    releaseChannel?: "stable" | "alpha"
    tunnelOnly?: boolean
  } = {}
): Promise<AppSetup> => {
  const keys = options.keys ?? generateDeviceKeyPair()
  const deviceId = options.deviceId ?? crypto.randomUUID()
  const tunnel = options.tunnelEndpointId
  const socket = await connectSocket({
    ...authed(token),
    ...(tunnel === undefined ? {} : { "x-codevisor-tunnel-endpoint": tunnel })
  })
  const reader = new SocketReader(socket, decodeHubToApp)
  socket.send(
    encodeCloudFrame({
      t: "hello",
      protocol: CLOUD_PROTOCOL_VERSION,
      device: {
        deviceId,
        kind: "app",
        name: "Test App",
        os: "macOS",
        publicKey: keys.publicKey,
        ...(tunnel === undefined ? {} : { tunnelEndpointId: tunnel }),
        ...(options.releaseChannel === undefined ? {} : { releaseChannel: options.releaseChannel }),
        ...(options.tunnelOnly === undefined ? {} : { tunnelOnly: options.tunnelOnly })
      },
      ...(options.resume === undefined ? {} : { resume: options.resume })
    })
  )
  const welcome = await reader.nextFrame("welcome")
  expect(welcome.t).toBe("welcome")
  return { keys, socket, reader, welcome, deviceId }
}
