// @boundaries-ignore intentionally resolved to package source: this app bundles @codevisor/api from src (tsconfig paths / vite alias)
import {
  CLOUD_PROTOCOL_VERSION,
  decodeHubToApp,
  decodeHubToMachine,
  decodeRelayEnvelopes,
  encodeCloudFrame,
  encodeRelayEnvelopes,
  type CloudMachinePresence,
  type HubToApp,
  type HubToMachine,
  type HubToAppRelayHeader,
  type HubToMachineRelayHeader,
  type WireRelayEnvelope
} from "@codevisor/api"
import {
  acceptChannel,
  fromBase64Url,
  generateDeviceKeyPair,
  openChannel,
  openJson,
  sealJson,
  toBase64Url
} from "@codevisor/cloud-crypto"
import { env, SELF } from "cloudflare:test"
import { describe, expect, it } from "vitest"

const BASE = "http://localhost:8787"

// -- Small helpers -----------------------------------------------------------

const devLogin = async (): Promise<string> => {
  const response = await SELF.fetch(`${BASE}/dev/login`, { method: "POST" })
  expect(response.status).toBe(200)
  const body = (await response.json()) as { token: string }
  expect(body.token).toBeTruthy()
  return body.token
}

const authed = (token: string): Record<string, string> => ({
  authorization: `Bearer ${token}`
})

/// Buffered async queue: items arrive before or after we await them.
class Queue<Item> {
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
    return new Promise<Item>((resolve, reject) => {
      this.#waiters.push(resolve)
      setTimeout(() => reject(new Error("timed out waiting for frame")), 5000)
    })
  }
}

/// Splits a hub socket's traffic into its two wire planes: JSON text control
/// frames and binary relay envelopes (batches flattened, boundaries counted).
class SocketReader<Frame> {
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
const sendRelay = (
  socket: WebSocket,
  header: unknown,
  payload: Uint8Array = new Uint8Array(0)
): void => socket.send(encodeRelayEnvelopes([{ header, payload }]))

const connectSocket = async (headers: Record<string, string>): Promise<WebSocket> => {
  const response = await SELF.fetch(`${BASE}/connect`, {
    headers: { Upgrade: "websocket", ...headers }
  })
  expect(response.status).toBe(101)
  const socket = response.webSocket
  if (socket === null) throw new Error("no websocket on upgrade response")
  socket.accept()
  return socket
}

interface MachineSetup {
  token: string
  apiKey: string
  deviceId: string
  keys: ReturnType<typeof generateDeviceKeyPair>
  socket: WebSocket
  reader: SocketReader<HubToMachine>
}

/// Full machine onboarding: session → api key with device metadata → hub
/// connection → hello/welcome.
const connectMachine = async (
  token: string,
  name: string,
  deviceId = crypto.randomUUID()
): Promise<MachineSetup> => {
  const keys = generateDeviceKeyPair()
  const created = await SELF.fetch(`${BASE}/api/auth/api-key/create`, {
    method: "POST",
    headers: { "content-type": "application/json", ...authed(token) },
    body: JSON.stringify({ name, metadata: { deviceId, publicKey: keys.publicKey } })
  })
  expect(created.status).toBe(200)
  const { key } = (await created.json()) as { key: string }
  const socket = await connectSocket({ "x-api-key": key })
  const reader = new SocketReader(socket, decodeHubToMachine)
  socket.send(
    encodeCloudFrame({
      t: "hello",
      protocol: CLOUD_PROTOCOL_VERSION,
      device: { deviceId, kind: "machine", name, os: "linux", publicKey: keys.publicKey }
    })
  )
  const welcome = await reader.next()
  expect(welcome).toMatchObject({ t: "welcome", protocol: CLOUD_PROTOCOL_VERSION })
  return { token, apiKey: key, deviceId, keys, socket, reader }
}

interface AppSetup {
  keys: ReturnType<typeof generateDeviceKeyPair>
  socket: WebSocket
  reader: SocketReader<HubToApp>
  welcome: Extract<HubToApp, { t: "welcome" }>
  deviceId: string
}

const connectApp = async (token: string): Promise<AppSetup> => {
  const keys = generateDeviceKeyPair()
  const deviceId = crypto.randomUUID()
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
      }
    })
  )
  const welcome = (await reader.next()) as AppSetup["welcome"]
  expect(welcome.t).toBe("welcome")
  return { keys, socket, reader, welcome, deviceId }
}

// -- Discovery & pages -------------------------------------------------------

describe("discovery", () => {
  it("serves instance metadata", async () => {
    const response = await SELF.fetch(`${BASE}/.well-known/codevisor`)
    expect(response.status).toBe(200)
    const body = (await response.json()) as Record<string, unknown>
    expect(body.service).toBe("codevisor-cloud")
    expect(body.protocols).toEqual([CLOUD_PROTOCOL_VERSION])
    expect(body.authProviders).toContain("dev")
  })

  it("serves health and human pages", async () => {
    expect((await SELF.fetch(`${BASE}/health`)).status).toBe(200)
    for (const path of ["/", "/login", "/device"]) {
      const response = await SELF.fetch(`${BASE}${path}`)
      expect(response.status).toBe(200)
      expect(await response.text()).toContain("<html")
    }
  })
})

// -- Auth --------------------------------------------------------------------

describe("auth", () => {
  it("dev login issues a bearer-usable session token", async () => {
    const token = await devLogin()
    const session = await SELF.fetch(`${BASE}/api/auth/get-session`, { headers: authed(token) })
    const body = (await session.json()) as { user?: { email?: string } } | null
    expect(body?.user?.email).toBe("dev@codevisor.local")
  })

  it("completes the RFC 8628 device flow end-to-end", async () => {
    const requested = await SELF.fetch(`${BASE}/api/auth/device/code`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ client_id: "codevisor-machine" })
    })
    expect(requested.status).toBe(200)
    const grant = (await requested.json()) as {
      device_code: string
      user_code: string
      verification_uri: string
    }
    expect(grant.verification_uri).toContain("/device")

    // Polling before approval → authorization_pending.
    const pending = await SELF.fetch(`${BASE}/api/auth/device/token`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
        device_code: grant.device_code,
        client_id: "codevisor-machine"
      })
    })
    expect(pending.status).toBe(400)
    expect(((await pending.json()) as { error: string }).error).toBe("authorization_pending")

    // User approves in the browser (session-authenticated): the verification
    // page first claims the code for this session, then approves it.
    const token = await devLogin()
    const claimed = await SELF.fetch(
      `${BASE}/api/auth/device?user_code=${encodeURIComponent(grant.user_code)}`,
      { headers: authed(token) }
    )
    expect(claimed.status).toBeLessThan(400)
    const approved = await SELF.fetch(`${BASE}/api/auth/device/approve`, {
      method: "POST",
      headers: { "content-type": "application/json", ...authed(token) },
      body: JSON.stringify({ userCode: grant.user_code })
    })
    expect(approved.status).toBe(200)

    // Machine polls again → session token.
    const granted = await SELF.fetch(`${BASE}/api/auth/device/token`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
        device_code: grant.device_code,
        client_id: "codevisor-machine"
      })
    })
    expect(granted.status).toBe(200)
    const { access_token } = (await granted.json()) as { access_token: string }
    const session = await SELF.fetch(`${BASE}/api/auth/get-session`, {
      headers: authed(access_token)
    })
    const body = (await session.json()) as { user?: { id?: string } } | null
    expect(body?.user?.id).toBeTruthy()
  })

  it("rejects unknown device-flow clients", async () => {
    const response = await SELF.fetch(`${BASE}/api/auth/device/code`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ client_id: "not-codevisor" })
    })
    expect(response.status).toBeGreaterThanOrEqual(400)
  })

  it("refuses unauthenticated connections and API calls", async () => {
    expect((await SELF.fetch(`${BASE}/api/machines`)).status).toBe(401)
    expect(
      (await SELF.fetch(`${BASE}/connect`, { headers: { Upgrade: "websocket" } })).status
    ).toBe(401)
    expect(
      (
        await SELF.fetch(`${BASE}/connect`, {
          headers: { Upgrade: "websocket", "x-api-key": "bogus" }
        })
      ).status
    ).toBe(401)
    expect((await SELF.fetch(`${BASE}/connect`)).status).toBe(426)
  })
})

// -- Hub: presence + registry -------------------------------------------------

describe("hub presence", () => {
  it("registers machines and reflects live presence to apps", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "vps-1")

    const app = await connectApp(token)
    const listed = app.welcome.machines.find((m) => m.deviceId === machine.deviceId)
    expect(listed).toMatchObject({ name: "vps-1", online: true, publicKey: machine.keys.publicKey })

    // Disconnect → offline presence broadcast.
    machine.socket.close(1000, "bye")
    const presence = (await app.reader.next()) as Extract<HubToApp, { t: "presence" }>
    expect(presence.t).toBe("presence")
    expect(presence.machine).toMatchObject({ deviceId: machine.deviceId, online: false })
  })

  it("lists, renames, and removes machines over REST", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "vps-rest")

    const list = async (): Promise<CloudMachinePresence[]> => {
      const response = await SELF.fetch(`${BASE}/api/machines`, { headers: authed(token) })
      expect(response.status).toBe(200)
      return ((await response.json()) as { machines: CloudMachinePresence[] }).machines
    }
    expect((await list()).some((m) => m.deviceId === machine.deviceId && m.online)).toBe(true)

    const renamed = await SELF.fetch(`${BASE}/api/machines/${machine.deviceId}/rename`, {
      method: "POST",
      headers: { "content-type": "application/json", ...authed(token) },
      body: JSON.stringify({ name: "office-vps" })
    })
    expect(renamed.status).toBe(200)
    expect((await list()).find((m) => m.deviceId === machine.deviceId)?.name).toBe("office-vps")

    const removed = await SELF.fetch(`${BASE}/api/machines/${machine.deviceId}`, {
      method: "DELETE",
      headers: authed(token)
    })
    expect(removed.status).toBe(200)
    expect((await list()).some((m) => m.deviceId === machine.deviceId)).toBe(false)
    // The machine's credential is revoked with it.
    expect(
      (
        await SELF.fetch(`${BASE}/connect`, {
          headers: { Upgrade: "websocket", "x-api-key": machine.apiKey }
        })
      ).status
    ).toBe(401)

    const missing = await SELF.fetch(`${BASE}/api/machines/nope/rename`, {
      method: "POST",
      headers: { "content-type": "application/json", ...authed(token) },
      body: JSON.stringify({ name: "x" })
    })
    expect(missing.status).toBe(404)
  })

  it("closes connections that speak an unsupported protocol", async () => {
    const token = await devLogin()
    const socket = await connectSocket(authed(token))
    const closed = new Promise<number>((resolve) =>
      socket.addEventListener("close", (event) => resolve(event.code))
    )
    socket.send(
      encodeCloudFrame({
        t: "hello",
        protocol: 999,
        device: { deviceId: "d", kind: "app", name: "old app", publicKey: "pk" }
      })
    )
    expect(await closed).toBe(4200)
  })
})

// -- Hub: end-to-end encrypted relay ------------------------------------------

describe("hub relay", () => {
  it("relays sealed channel traffic app↔machine without reading it", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "relay-vps")
    const app = await connectApp(token)

    // App opens a terminal channel, E2E encrypted to the machine's static key.
    const channel = openChannel(app.keys.secretKey, machine.keys.publicKey)
    const openPayload = {
      channelType: "terminal",
      params: { terminalId: "term-1", sinceSeq: 7 }
    }
    sendRelay(
      app.socket,
      {
        machineId: machine.deviceId,
        frame: { t: "open", channelId: "ch-1", seq: 0, ephemeralKey: channel.ephemeralPublicKey }
      },
      sealJson(channel.cipher, "ch-1", "opener-to-responder", 0, openPayload)
    )

    const opened = await machine.reader.nextEnvelope()
    const openHeader = opened.header as HubToMachineRelayHeader
    expect(openHeader.peerPublicKey).toBe(app.keys.publicKey)
    // The opener's stable device id rides along so the machine can TOFU-pin
    // the key under it.
    expect(openHeader.peerDeviceId).toBe(app.deviceId)
    const openFrame = openHeader.frame as Extract<typeof openHeader.frame, { t: "open" }>
    // Machine authenticates the opener and decrypts the channel intent.
    const responder = acceptChannel(
      machine.keys.secretKey,
      openHeader.peerPublicKey!,
      openFrame.ephemeralKey
    )
    expect(openJson(responder, "ch-1", "opener-to-responder", 0, opened.payload)).toEqual(
      openPayload
    )

    // Machine answers with sealed terminal output.
    sendRelay(
      machine.socket,
      { peerId: openHeader.peerId, frame: { t: "data", channelId: "ch-1", seq: 0 } },
      sealJson(responder, "ch-1", "responder-to-opener", 0, {
        type: "output",
        seq: 8,
        data: "hello from the machine"
      })
    )
    const answered = await app.reader.nextEnvelope()
    const answeredHeader = answered.header as HubToAppRelayHeader
    expect(answeredHeader.machineId).toBe(machine.deviceId)
    expect(openJson(channel.cipher, "ch-1", "responder-to-opener", 0, answered.payload)).toEqual({
      type: "output",
      seq: 8,
      data: "hello from the machine"
    })

    // Credit + close flow through untouched (empty payloads; header-only).
    sendRelay(app.socket, {
      machineId: machine.deviceId,
      frame: { t: "credit", channelId: "ch-1", seq: 1, bytes: 65536 }
    })
    const credit = await machine.reader.nextEnvelope()
    expect((credit.header as HubToMachineRelayHeader).frame).toMatchObject({
      t: "credit",
      bytes: 65536
    })
    sendRelay(app.socket, {
      machineId: machine.deviceId,
      frame: { t: "close", channelId: "ch-1", seq: 2, reason: "done" }
    })
    const closeRelay = await machine.reader.nextEnvelope()
    expect((closeRelay.header as HubToMachineRelayHeader).frame.t).toBe("close")
  })

  it("keeps a coalesced envelope batch one message through the hop", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "batch-vps")
    const app = await connectApp(token)
    const before = machine.reader.binaryMessages

    // Three envelopes for the same machine in ONE binary message — the hub
    // must forward them as one message, preserving order.
    app.socket.send(
      encodeRelayEnvelopes([
        {
          header: { machineId: machine.deviceId, frame: { t: "data", channelId: "b", seq: 0 } },
          payload: new Uint8Array([1])
        },
        {
          header: { machineId: machine.deviceId, frame: { t: "data", channelId: "b", seq: 1 } },
          payload: new Uint8Array([2, 2])
        },
        {
          header: {
            machineId: machine.deviceId,
            frame: { t: "credit", channelId: "b", seq: 2, bytes: 64 }
          },
          payload: new Uint8Array(0)
        }
      ])
    )
    const first = await machine.reader.nextEnvelope()
    const second = await machine.reader.nextEnvelope()
    const third = await machine.reader.nextEnvelope()
    expect([...first.payload]).toEqual([1])
    expect([...second.payload]).toEqual([2, 2])
    expect((third.header as HubToMachineRelayHeader).frame).toMatchObject({ t: "credit" })
    expect(machine.reader.binaryMessages - before).toBe(1)
  })

  it("routes opaque byte-stream data and credit through hibernatable sockets", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "byte-stream-vps")
    const app = await connectApp(token)
    const channel = openChannel(app.keys.secretKey, machine.keys.publicKey)
    const channelId = "bytes-1"
    sendRelay(
      app.socket,
      {
        machineId: machine.deviceId,
        frame: { t: "open", channelId, seq: 0, ephemeralKey: channel.ephemeralPublicKey }
      },
      sealJson(channel.cipher, channelId, "opener-to-responder", 0, {
        channelType: "byte-stream",
        params: { service: "codevisor-loopback", version: 1 }
      })
    )
    const opened = await machine.reader.nextEnvelope()
    const openHeader = opened.header as HubToMachineRelayHeader
    const openFrame = openHeader.frame as Extract<typeof openHeader.frame, { t: "open" }>
    const responder = acceptChannel(
      machine.keys.secretKey,
      openHeader.peerPublicKey!,
      openFrame.ephemeralKey
    )

    const requestBytes = new Uint8Array([0, 255, 13, 10, 128, 1])
    sendRelay(
      app.socket,
      { machineId: machine.deviceId, frame: { t: "data", channelId, seq: 1 } },
      channel.cipher.seal(channelId, "opener-to-responder", 1, requestBytes)
    )
    const request = await machine.reader.nextEnvelope()
    expect([...responder.open(channelId, "opener-to-responder", 1, request.payload)]).toEqual([
      ...requestBytes
    ])

    sendRelay(machine.socket, {
      peerId: openHeader.peerId,
      frame: { t: "credit", channelId, seq: 0, bytes: request.payload.byteLength }
    })
    const credit = await app.reader.nextEnvelope()
    expect((credit.header as HubToAppRelayHeader).frame).toEqual({
      t: "credit",
      channelId,
      seq: 0,
      bytes: request.payload.byteLength
    })

    // Protocol pings are answered by the WebSocket auto-response pair used
    // by the hibernation API; the byte stream remains routable afterwards.
    app.socket.send(encodeCloudFrame({ t: "ping" }))
    expect((await app.reader.next()).t).toBe("pong")
    const responseBytes = new Uint8Array([9, 8, 7, 0, 255])
    sendRelay(
      machine.socket,
      { peerId: openHeader.peerId, frame: { t: "data", channelId, seq: 1 } },
      responder.seal(channelId, "responder-to-opener", 1, responseBytes)
    )
    const response = await app.reader.nextEnvelope()
    expect([...channel.cipher.open(channelId, "responder-to-opener", 1, response.payload)]).toEqual(
      [...responseBytes]
    )
  })

  it("carries an http channel round-trip through sealed frames", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "http-vps")
    const app = await connectApp(token)

    // The machine's stub local server, standing in for the real loopback API.
    const localServer = (method: string, path: string) => {
      expect(method).toBe("GET")
      expect(path).toBe("/v1/info")
      return {
        status: 200,
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ name: "http-vps" })
      }
    }

    // App opens an http channel and ends its (empty) request body.
    const channel = openChannel(app.keys.secretKey, machine.keys.publicKey)
    const openPayload = {
      channelType: "http",
      params: { method: "GET", path: "/v1/info", headers: { accept: "application/json" } }
    }
    sendRelay(
      app.socket,
      {
        machineId: machine.deviceId,
        frame: { t: "open", channelId: "http-1", seq: 0, ephemeralKey: channel.ephemeralPublicKey }
      },
      sealJson(channel.cipher, "http-1", "opener-to-responder", 0, openPayload)
    )
    sendRelay(
      app.socket,
      { machineId: machine.deviceId, frame: { t: "data", channelId: "http-1", seq: 1 } },
      sealJson(channel.cipher, "http-1", "opener-to-responder", 1, { kind: "end" })
    )

    // Machine side: accept the channel, decrypt the request, answer per the
    // http contract — head, one chunk, end, close("done").
    const opened = await machine.reader.nextEnvelope()
    const openHeader = opened.header as HubToMachineRelayHeader
    const openFrame = openHeader.frame as Extract<typeof openHeader.frame, { t: "open" }>
    const responder = acceptChannel(
      machine.keys.secretKey,
      openHeader.peerPublicKey!,
      openFrame.ephemeralKey
    )
    const request = openJson(responder, "http-1", "opener-to-responder", 0, opened.payload) as {
      params: { method: string; path: string }
    }
    expect(request).toEqual(openPayload)
    const ended = await machine.reader.nextEnvelope()
    expect(openJson(responder, "http-1", "opener-to-responder", 1, ended.payload)).toEqual({
      kind: "end"
    })

    const response = localServer(request.params.method, request.params.path)
    const answer = (seq: number, value: unknown): void =>
      sendRelay(
        machine.socket,
        { peerId: openHeader.peerId, frame: { t: "data", channelId: "http-1", seq } },
        sealJson(responder, "http-1", "responder-to-opener", seq, value)
      )
    answer(0, { kind: "head", status: response.status, headers: response.headers })
    answer(1, { kind: "chunk", data: toBase64Url(new TextEncoder().encode(response.body)) })
    answer(2, { kind: "end" })
    sendRelay(machine.socket, {
      peerId: openHeader.peerId,
      frame: { t: "close", channelId: "http-1", seq: 3, reason: "done" }
    })

    // App decrypts the full choreography back out of the relay.
    const read = async (seq: number): Promise<unknown> => {
      const relayed = await app.reader.nextEnvelope()
      return openJson(channel.cipher, "http-1", "responder-to-opener", seq, relayed.payload)
    }
    expect(await read(0)).toEqual({
      kind: "head",
      status: 200,
      headers: { "content-type": "application/json" }
    })
    const chunk = (await read(1)) as { kind: string; data: string }
    expect(chunk.kind).toBe("chunk")
    expect(new TextDecoder().decode(fromBase64Url(chunk.data))).toBe(response.body)
    expect(await read(2)).toEqual({ kind: "end" })
    const closed = await app.reader.nextEnvelope()
    expect((closed.header as HubToAppRelayHeader).frame).toMatchObject({
      t: "close",
      channelId: "http-1",
      reason: "done"
    })
  })

  it("reports offline and unknown machines to the app", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "flaky-vps")
    const app = await connectApp(token)
    machine.socket.close(1000, "gone")
    expect((await app.reader.next()).t).toBe("presence")
    // The proactive broadcast: receive-only streams can never provoke the
    // reactive error below, so the hub reports the loss unprompted.
    const broadcast = (await app.reader.next()) as Extract<HubToApp, { t: "error" }>
    expect(broadcast).toMatchObject({
      t: "error",
      code: "machine-offline",
      machineId: machine.deviceId
    })

    const frame = { t: "data", channelId: "ch-x", seq: 0 } as const
    sendRelay(app.socket, { machineId: machine.deviceId, frame }, new Uint8Array([1]))
    const offline = (await app.reader.next()) as Extract<HubToApp, { t: "error" }>
    expect(offline).toMatchObject({ t: "error", code: "machine-offline", channelId: "ch-x" })

    sendRelay(app.socket, { machineId: "never-existed", frame }, new Uint8Array([1]))
    const unknown = (await app.reader.next()) as Extract<HubToApp, { t: "error" }>
    expect(unknown.code).toBe("unknown-machine")
  })

  it("resets app channels and supersedes zombie sockets when a machine re-hellos", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "reconnect-vps")
    const app = await connectApp(token)

    const superseded = new Promise<number>((resolve) =>
      machine.socket.addEventListener("close", (event) => resolve(event.code))
    )
    // The same device reconnects while its previous socket lingers half-open.
    const reborn = await connectMachine(token, "reconnect-vps", machine.deviceId)

    // The zombie is closed with the non-fatal supersede code so it cannot
    // black-hole routed frames or suppress a later offline broadcast.
    expect(await superseded).toBe(4003)
    // Apps are told to drop dead channels before the machine turns online, so
    // re-opens park briefly and then dispatch to the fresh socket.
    const reset = (await app.reader.next()) as Extract<HubToApp, { t: "machine-reset" }>
    expect(reset).toMatchObject({ t: "machine-reset", machineId: machine.deviceId })
    const presence = (await app.reader.next()) as Extract<HubToApp, { t: "presence" }>
    expect(presence.machine).toMatchObject({ deviceId: machine.deviceId, online: true })

    // The superseded socket's close is not an outage: relaying through the
    // fresh socket works immediately, with no offline error in between.
    sendRelay(
      app.socket,
      { machineId: machine.deviceId, frame: { t: "data", channelId: "ch-fresh", seq: 0 } },
      new Uint8Array([1])
    )
    const relayed = await reborn.reader.nextEnvelope()
    expect((relayed.header as HubToMachineRelayHeader).frame).toMatchObject({
      channelId: "ch-fresh"
    })
  })

  it("notifies machines when an app peer disconnects", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "peer-vps")
    const app = await connectApp(token)
    app.socket.close(1000, "app quit")
    const gone = (await machine.reader.next()) as Extract<HubToMachine, { t: "peer-gone" }>
    expect(gone).toMatchObject({ t: "peer-gone" })
  })

  it("answers protocol pings and rejects garbage frames", async () => {
    const token = await devLogin()
    const app = await connectApp(token)
    app.socket.send(encodeCloudFrame({ t: "ping" }))
    expect((await app.reader.next()).t).toBe("pong")

    // Machine heartbeats use the same hibernation-safe auto-response. This is
    // the liveness contract that lets a machine detect a half-open socket
    // without periodically waking the account's Durable Object.
    const machine = await connectMachine(token, "heartbeat-vps")
    expect((await app.reader.next()).t).toBe("machine-reset")
    expect((await app.reader.next()).t).toBe("presence")
    machine.socket.send(encodeCloudFrame({ t: "ping" }))
    expect((await machine.reader.next()).t).toBe("pong")

    app.socket.send("this is not json")
    const notJson = (await app.reader.next()) as Extract<HubToApp, { t: "error" }>
    expect(notJson.code).toBe("invalid-frame")

    // Truncated binary relay messages are refused the same way.
    app.socket.send(new Uint8Array([0, 0, 0, 99]).buffer)
    const truncated = (await app.reader.next()) as Extract<HubToApp, { t: "error" }>
    expect(truncated.code).toBe("invalid-frame")

    // Well-formed envelope, malformed header.
    app.socket.send(encodeRelayEnvelopes([{ header: { nope: true }, payload: new Uint8Array(0) }]))
    const badHeader = (await app.reader.next()) as Extract<HubToApp, { t: "error" }>
    expect(badHeader.code).toBe("invalid-frame")
  })
})

// -- Environment gating --------------------------------------------------------

describe("machine credential probe", () => {
  it("confirms valid keys and rejects missing or invalid ones", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "probe-vps")
    const valid = await SELF.fetch(`${BASE}/api/machine/credential`, {
      headers: { "x-api-key": machine.apiKey }
    })
    expect(valid.status).toBe(200)
    expect((await SELF.fetch(`${BASE}/api/machine/credential`)).status).toBe(401)
    const bogus = await SELF.fetch(`${BASE}/api/machine/credential`, {
      headers: { "x-api-key": "not-a-key" }
    })
    expect(bogus.status).toBe(401)
  })
})

describe("direct GitHub sign-in", () => {
  it("redirects straight to GitHub with state cookies when configured", async () => {
    const { default: worker } = await import("../src/index.js")
    const githubEnv = {
      ...env,
      GITHUB_CLIENT_ID: "Iv23test",
      GITHUB_CLIENT_SECRET: "secret"
    }
    const response = await worker.fetch(
      new Request(`${BASE}/login/github?redirect=%2Fauth%2Fhandoff%3Fapp%3Dcodevisor-dev`),
      githubEnv
    )
    expect(response.status).toBe(302)
    const location = response.headers.get("location") ?? ""
    expect(location).toContain("github.com/login/oauth/authorize")
    expect(location).toContain("client_id=Iv23test")
    // Better Auth's state/PKCE cookie must ride along into the browser.
    expect(response.headers.getSetCookie().join(";")).toContain("state")
  })

  it("falls back to the login page without GitHub, and rejects absolute redirects", async () => {
    const fallback = await SELF.fetch(`${BASE}/login/github`, { redirect: "manual" })
    expect(fallback.status).toBe(302)
    expect(fallback.headers.get("location")).toContain("/login?redirect=")

    const evil = await SELF.fetch(`${BASE}/login/github?redirect=https%3A%2F%2Fevil.example`, {
      redirect: "manual"
    })
    expect(evil.status).toBe(400)
    const schemeless = await SELF.fetch(`${BASE}/login/github?redirect=%2F%2Fevil.example`, {
      redirect: "manual"
    })
    expect(schemeless.status).toBe(400)
  })
})

describe("dev auth gating", () => {
  it("hides dev login when DEV_AUTH is not enabled", async () => {
    const { default: worker } = await import("../src/index.js")
    const { DEV_AUTH: _devAuth, ...prodEnv } = { ...env, BETTER_AUTH_SECRET: "x".repeat(40) }
    const response = await worker.fetch(
      new Request(`${BASE}/dev/login`, { method: "POST" }),
      prodEnv
    )
    expect(response.status).toBe(404)
    const discovery = await worker.fetch(new Request(`${BASE}/.well-known/codevisor`), prodEnv)
    const body = (await discovery.json()) as { authProviders: string[] }
    expect(body.authProviders).not.toContain("dev")
  })
})
