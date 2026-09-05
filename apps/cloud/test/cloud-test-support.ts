// @boundaries-ignore intentionally resolved to package source: this app bundles @codevisor/api from src (tsconfig paths / vite alias)
import {
  CLOUD_PROTOCOL_VERSION,
  decodeHubToApp,
  decodeHubToMachine,
  decodeRelayEnvelopes,
  encodeCloudFrame,
  encodeRelayEnvelopes,
  type HubToApp,
  type HubToMachine,
  type WireRelayEnvelope
} from "@codevisor/api"
import { afterEach, beforeEach, expect, vi } from "vitest"
import { generateDeviceKeyPair } from "@codevisor/cloud-crypto"
import { env, runInDurableObject, SELF } from "cloudflare:test"
import type { UserHub } from "../src/user-hub.js"

/// Shared scaffolding for the hub integration tests: dev login, sockets,
/// frame readers, and machine/app connection setup.

export const BASE = "http://localhost:8787"

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] })
  // Keep real workerd alarms dormant; expiry is invoked explicitly below.
  vi.setSystemTime(new Date("2100-01-01T00:00:00Z"))
})
afterEach(() => vi.useRealTimers())

// -- Small helpers -----------------------------------------------------------

export const devLogin = async (): Promise<string> => {
  const response = await SELF.fetch(`${BASE}/dev/login`, { method: "POST" })
  expect(response.status).toBe(200)
  const body = (await response.json()) as { token: string }
  expect(body.token).toBeTruthy()
  return body.token
}

export const authed = (token: string): Record<string, string> => ({
  authorization: `Bearer ${token}`
})

const hubStub = async (token: string): Promise<DurableObjectStub<UserHub>> => {
  const session = await SELF.fetch(`${BASE}/api/auth/get-session`, { headers: authed(token) })
  const body = (await session.json()) as { user?: { id?: string } } | null
  const userId = body?.user?.id
  if (userId === undefined) throw new Error("no session user for hub stub")
  const namespace = env.USER_HUB as unknown as DurableObjectNamespace
  return namespace.get(namespace.idFromName(userId)) as DurableObjectStub<UserHub>
}

/// A client close is asynchronous: acknowledge the server handler before resuming or expiring.
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
  let restore = () => {}
  await runInDurableObject(stub, (hub) => {
    const close = hub.webSocketClose.bind(hub)
    const observed = vi.spyOn(hub, "webSocketClose").mockImplementation(async (socket) => {
      await close(socket)
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
      restore()
    })
  }
}

/// Advances the frozen clock past resume grace and explicitly runs expiry.
export const expireResumeGrace = async (token: string): Promise<void> => {
  const stub = await hubStub(token)
  await runInDurableObject(stub, async (hub, state) => {
    const deadline = await state.storage.getAlarm()
    expect(deadline).not.toBeNull()
    vi.setSystemTime(deadline! + 1)
    await hub.alarm()
  })
}

/// Buffered async queue: items arrive before or after we await them.
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

/// Splits a hub socket's traffic into its two wire planes: JSON text control
/// frames and binary relay envelopes (batches flattened, boundaries counted).
export class SocketReader<Frame> {
  readonly #controls = new Queue<Frame>()
  readonly #envelopes = new Queue<WireRelayEnvelope>()
  binaryMessages = 0
  // The test client delivers binary messages as Blobs; reading them is async,
  // so chain the reads to keep envelope order identical to wire order.
  #chain: Promise<void> = Promise.resolve()

  constructor(socket: WebSocket, decode: (raw: string) => Frame) {
    socket.addEventListener("message", (event) => {
      if (typeof event.data === "string") {
        this.#controls.push(decode(event.data))
        return
      }
      this.binaryMessages += 1
      const data = event.data
      this.#chain = this.#chain.then(async () => {
        const buffer =
          data instanceof ArrayBuffer ? data : await (data as unknown as Blob).arrayBuffer()
        for (const envelope of decodeRelayEnvelopes(new Uint8Array(buffer))) {
          this.#envelopes.push({ ...envelope, payload: new Uint8Array(envelope.payload) })
        }
      })
    })
  }

  async next(): Promise<Frame> {
    return this.#controls.next()
  }

  async nextEnvelope(): Promise<WireRelayEnvelope> {
    return this.#envelopes.next()
  }
}

/// Sends one relay envelope as its own binary message.
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

/// Full machine onboarding: session → api key with device metadata → hub
/// connection → hello/welcome.
export const connectMachine = async (
  token: string,
  name: string,
  deviceId = crypto.randomUUID(),
  options: {
    apiKey?: string
    keys?: ReturnType<typeof generateDeviceKeyPair>
    resume?: string
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
    apiKey = ((await created.json()) as { key: string }).key
  }
  const socket = await connectSocket({ "x-api-key": apiKey })
  const reader = new SocketReader(socket, decodeHubToMachine)
  socket.send(
    encodeCloudFrame({
      t: "hello",
      protocol: CLOUD_PROTOCOL_VERSION,
      device: { deviceId, kind: "machine", name, os: "linux", publicKey: keys.publicKey },
      ...(options.resume === undefined ? {} : { resume: options.resume })
    })
  )
  const welcome = (await reader.next()) as MachineSetup["welcome"]
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
  } = {}
): Promise<AppSetup> => {
  const keys = options.keys ?? generateDeviceKeyPair()
  const deviceId = options.deviceId ?? crypto.randomUUID()
  const socket = await connectSocket(authed(token))
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
        publicKey: keys.publicKey
      },
      ...(options.resume === undefined ? {} : { resume: options.resume })
    })
  )
  const welcome = (await reader.next()) as AppSetup["welcome"]
  expect(welcome.t).toBe("welcome")
  return { keys, socket, reader, welcome, deviceId }
}

// -- Discovery & pages -------------------------------------------------------
