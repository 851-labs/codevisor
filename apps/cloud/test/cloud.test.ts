import {
  CLOUD_PROTOCOL_VERSION,
  decodeHubToApp,
  decodeHubToMachine,
  encodeCloudFrame,
  type CloudMachinePresence,
  type HubToApp,
  type HubToMachine
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

/// Buffered WebSocket reader: frames arrive before or after we await them.
class SocketReader<Frame> {
  #queue: string[] = []
  #waiters: ((raw: string) => void)[] = []

  constructor(
    socket: WebSocket,
    private readonly decode: (raw: string) => Frame
  ) {
    socket.addEventListener("message", (event) => {
      const raw = event.data as string
      const waiter = this.#waiters.shift()
      if (waiter !== undefined) waiter(raw)
      else this.#queue.push(raw)
    })
  }

  async next(): Promise<Frame> {
    const raw =
      this.#queue.shift() ??
      (await new Promise<string>((resolve, reject) => {
        this.#waiters.push(resolve)
        setTimeout(() => reject(new Error("timed out waiting for frame")), 5000)
      }))
    return this.decode(raw)
  }
}

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
}

const connectApp = async (token: string): Promise<AppSetup> => {
  const keys = generateDeviceKeyPair()
  const socket = await connectSocket(authed(token))
  const reader = new SocketReader(socket, decodeHubToApp)
  socket.send(
    encodeCloudFrame({
      t: "hello",
      protocol: CLOUD_PROTOCOL_VERSION,
      device: {
        deviceId: crypto.randomUUID(),
        kind: "app",
        name: "Test App",
        os: "macOS",
        publicKey: keys.publicKey
      }
    })
  )
  const welcome = (await reader.next()) as AppSetup["welcome"]
  expect(welcome.t).toBe("welcome")
  return { keys, socket, reader, welcome }
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
    app.socket.send(
      encodeCloudFrame({
        t: "relay",
        machineId: machine.deviceId,
        frame: {
          t: "open",
          channelId: "ch-1",
          seq: 0,
          ephemeralKey: channel.ephemeralPublicKey,
          sealed: sealJson(channel.cipher, "ch-1", "opener-to-responder", 0, openPayload)
        }
      })
    )

    const opened = (await machine.reader.next()) as Extract<HubToMachine, { t: "relay" }>
    expect(opened.t).toBe("relay")
    expect(opened.peerPublicKey).toBe(app.keys.publicKey)
    const openFrame = opened.frame as Extract<typeof opened.frame, { t: "open" }>
    // Machine authenticates the opener and decrypts the channel intent.
    const responder = acceptChannel(
      machine.keys.secretKey,
      opened.peerPublicKey!,
      openFrame.ephemeralKey
    )
    expect(openJson(responder, "ch-1", "opener-to-responder", 0, openFrame.sealed)).toEqual(
      openPayload
    )

    // Machine answers with sealed terminal output.
    machine.socket.send(
      encodeCloudFrame({
        t: "relay",
        peerId: opened.peerId,
        frame: {
          t: "data",
          channelId: "ch-1",
          seq: 0,
          sealed: sealJson(responder, "ch-1", "responder-to-opener", 0, {
            type: "output",
            seq: 8,
            data: "hello from the machine"
          })
        }
      })
    )
    const answered = (await app.reader.next()) as Extract<HubToApp, { t: "relay" }>
    expect(answered.machineId).toBe(machine.deviceId)
    const dataFrame = answered.frame as Extract<typeof answered.frame, { t: "data" }>
    expect(openJson(channel.cipher, "ch-1", "responder-to-opener", 0, dataFrame.sealed)).toEqual({
      type: "output",
      seq: 8,
      data: "hello from the machine"
    })

    // Credit + close flow through untouched.
    app.socket.send(
      encodeCloudFrame({
        t: "relay",
        machineId: machine.deviceId,
        frame: { t: "credit", channelId: "ch-1", seq: 1, bytes: 65536 }
      })
    )
    expect((await machine.reader.next()).t).toBe("relay")
    app.socket.send(
      encodeCloudFrame({
        t: "relay",
        machineId: machine.deviceId,
        frame: { t: "close", channelId: "ch-1", seq: 2, reason: "done" }
      })
    )
    const closeRelay = (await machine.reader.next()) as Extract<HubToMachine, { t: "relay" }>
    expect(closeRelay.frame.t).toBe("close")
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
    app.socket.send(
      encodeCloudFrame({
        t: "relay",
        machineId: machine.deviceId,
        frame: {
          t: "open",
          channelId: "http-1",
          seq: 0,
          ephemeralKey: channel.ephemeralPublicKey,
          sealed: sealJson(channel.cipher, "http-1", "opener-to-responder", 0, openPayload)
        }
      })
    )
    app.socket.send(
      encodeCloudFrame({
        t: "relay",
        machineId: machine.deviceId,
        frame: {
          t: "data",
          channelId: "http-1",
          seq: 1,
          sealed: sealJson(channel.cipher, "http-1", "opener-to-responder", 1, { kind: "end" })
        }
      })
    )

    // Machine side: accept the channel, decrypt the request, answer per the
    // http contract — head, one chunk, end, close("done").
    const opened = (await machine.reader.next()) as Extract<HubToMachine, { t: "relay" }>
    const openFrame = opened.frame as Extract<typeof opened.frame, { t: "open" }>
    const responder = acceptChannel(
      machine.keys.secretKey,
      opened.peerPublicKey!,
      openFrame.ephemeralKey
    )
    const request = openJson(responder, "http-1", "opener-to-responder", 0, openFrame.sealed) as {
      params: { method: string; path: string }
    }
    expect(request).toEqual(openPayload)
    const ended = (await machine.reader.next()) as Extract<HubToMachine, { t: "relay" }>
    const endFrame = ended.frame as Extract<typeof ended.frame, { t: "data" }>
    expect(openJson(responder, "http-1", "opener-to-responder", 1, endFrame.sealed)).toEqual({
      kind: "end"
    })

    const response = localServer(request.params.method, request.params.path)
    const answer = (seq: number, value: unknown): void =>
      machine.socket.send(
        encodeCloudFrame({
          t: "relay",
          peerId: opened.peerId,
          frame: {
            t: "data",
            channelId: "http-1",
            seq,
            sealed: sealJson(responder, "http-1", "responder-to-opener", seq, value)
          }
        })
      )
    answer(0, { kind: "head", status: response.status, headers: response.headers })
    answer(1, { kind: "chunk", data: toBase64Url(new TextEncoder().encode(response.body)) })
    answer(2, { kind: "end" })
    machine.socket.send(
      encodeCloudFrame({
        t: "relay",
        peerId: opened.peerId,
        frame: { t: "close", channelId: "http-1", seq: 3, reason: "done" }
      })
    )

    // App decrypts the full choreography back out of the relay.
    const read = async (seq: number): Promise<unknown> => {
      const relayed = (await app.reader.next()) as Extract<HubToApp, { t: "relay" }>
      const data = relayed.frame as Extract<typeof relayed.frame, { t: "data" }>
      return openJson(channel.cipher, "http-1", "responder-to-opener", seq, data.sealed)
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
    const closed = (await app.reader.next()) as Extract<HubToApp, { t: "relay" }>
    expect(closed.frame).toMatchObject({ t: "close", channelId: "http-1", reason: "done" })
  })

  it("reports offline and unknown machines to the app", async () => {
    const token = await devLogin()
    const machine = await connectMachine(token, "flaky-vps")
    const app = await connectApp(token)
    machine.socket.close(1000, "gone")
    expect((await app.reader.next()).t).toBe("presence")

    const frame = {
      t: "data",
      channelId: "ch-x",
      seq: 0,
      sealed: { box: "Ym94" }
    } as const
    app.socket.send(encodeCloudFrame({ t: "relay", machineId: machine.deviceId, frame }))
    const offline = (await app.reader.next()) as Extract<HubToApp, { t: "error" }>
    expect(offline).toMatchObject({ t: "error", code: "machine-offline", channelId: "ch-x" })

    app.socket.send(encodeCloudFrame({ t: "relay", machineId: "never-existed", frame }))
    const unknown = (await app.reader.next()) as Extract<HubToApp, { t: "error" }>
    expect(unknown.code).toBe("unknown-machine")
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
    expect((await app.reader.next()).t).toBe("presence")
    machine.socket.send(encodeCloudFrame({ t: "ping" }))
    expect((await machine.reader.next()).t).toBe("pong")

    app.socket.send("this is not json")
    const error = (await app.reader.next()) as Extract<HubToApp, { t: "error" }>
    expect(error.code).toBe("invalid-frame")
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
    const { default: app } = await import("../src/index.js")
    const githubEnv = {
      ...env,
      GITHUB_CLIENT_ID: "Iv23test",
      GITHUB_CLIENT_SECRET: "secret"
    }
    const response = await app.request(
      "/login/github?redirect=%2Fauth%2Fhandoff%3Fapp%3Dcodevisor-dev",
      { redirect: "manual" },
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
    const { default: app } = await import("../src/index.js")
    const { DEV_AUTH: _devAuth, ...prodEnv } = { ...env, BETTER_AUTH_SECRET: "x".repeat(40) }
    const response = await app.request("/dev/login", { method: "POST" }, prodEnv)
    expect(response.status).toBe(404)
    const discovery = await app.request("/.well-known/codevisor", {}, prodEnv)
    const body = (await discovery.json()) as { authProviders: string[] }
    expect(body.authProviders).not.toContain("dev")
  })
})
