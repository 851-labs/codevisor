import { describe, expect, it } from "vitest"
import {
  CloudApiError,
  discoverInstance,
  MACHINE_CLIENT_ID,
  pollDeviceToken,
  provisionMachine,
  requestDeviceCode,
  type FetchLike
} from "./index.js"

const jsonResponse = (body: unknown, status = 200): Response =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" }
  })

const fetchStub = (
  handler: (input: string, init?: RequestInit) => Response
): { calls: { input: string; init?: RequestInit }[]; fetch: FetchLike } => {
  const calls: { input: string; init?: RequestInit }[] = []
  return {
    calls,
    fetch: async (input, init) => {
      calls.push(init !== undefined ? { input, init } : { input })
      return handler(input, init)
    }
  }
}

describe("requestDeviceCode", () => {
  it("returns the parsed grant", async () => {
    const { calls, fetch } = fetchStub(() =>
      jsonResponse({
        device_code: "dc",
        user_code: "UC-1",
        verification_uri: "https://cloud.example/device",
        verification_uri_complete: "https://cloud.example/device?user_code=UC-1",
        interval: 5,
        expires_in: 600
      })
    )
    const grant = await requestDeviceCode(fetch, "https://cloud.example")
    expect(grant).toEqual({
      deviceCode: "dc",
      userCode: "UC-1",
      verificationUri: "https://cloud.example/device",
      verificationUriComplete: "https://cloud.example/device?user_code=UC-1",
      interval: 5,
      expiresIn: 600
    })
    expect(calls[0]?.input).toBe("https://cloud.example/api/auth/device/code")
    expect(JSON.parse(calls[0]?.init?.body as string)).toEqual({ client_id: MACHINE_CLIENT_ID })
  })

  it("applies defaults and surfaces failures", async () => {
    const minimal = fetchStub(() =>
      jsonResponse({ device_code: "dc", user_code: "UC", verification_uri: "/device" })
    )
    const grant = await requestDeviceCode(minimal.fetch, "https://cloud.example")
    expect(grant.interval).toBe(5)
    expect(grant.expiresIn).toBe(1800)
    expect(grant.verificationUriComplete).toBeUndefined()

    const failing = fetchStub(() => jsonResponse({ error: "nope" }, 500))
    await expect(requestDeviceCode(failing.fetch, "https://cloud.example")).rejects.toThrow(
      CloudApiError
    )
  })
})

describe("pollDeviceToken", () => {
  const poll = (body: unknown, status: number) =>
    pollDeviceToken(fetchStub(() => jsonResponse(body, status)).fetch, "https://c", "dc")

  it("maps every RFC outcome", async () => {
    expect(await poll({ access_token: "session" }, 200)).toEqual({
      status: "granted",
      sessionToken: "session"
    })
    expect(await poll({ error: "authorization_pending" }, 400)).toEqual({ status: "pending" })
    expect(await poll({ error: "slow_down" }, 400)).toEqual({ status: "slow-down" })
    expect(await poll({ error: "access_denied" }, 400)).toEqual({ status: "denied" })
    expect(await poll({ error: "expired_token" }, 400)).toEqual({ status: "expired" })
  })

  it("throws on unexpected errors, including non-JSON bodies", async () => {
    await expect(poll({ error: "invalid_grant" }, 400)).rejects.toThrow("invalid_grant")
    const broken = fetchStub(() => new Response("gateway timeout", { status: 504 }))
    await expect(pollDeviceToken(broken.fetch, "https://c", "dc")).rejects.toThrow(
      "device token poll failed"
    )
  })
})

describe("provisionMachine", () => {
  it("creates a keypair and api key bound to the device metadata", async () => {
    const { calls, fetch } = fetchStub(() => jsonResponse({ key: "api-key-1" }))
    const credentials = await provisionMachine(fetch, "https://cloud.example", "session", "vps-1")
    expect(credentials.serverUrl).toBe("https://cloud.example")
    expect(credentials.apiKey).toBe("api-key-1")
    expect(credentials.deviceId).toMatch(/[0-9a-f-]{36}/)
    expect(credentials.publicKey).not.toBe("")
    expect(credentials.secretKey).not.toBe("")
    const body = JSON.parse(calls[0]?.init?.body as string) as {
      name: string
      metadata: { deviceId: string; publicKey: string }
    }
    expect(body.name).toBe("vps-1")
    expect(body.metadata).toEqual({
      deviceId: credentials.deviceId,
      publicKey: credentials.publicKey
    })
    const requestHeaders = (calls[0]?.init?.headers ?? {}) as Record<string, string>
    expect(requestHeaders.authorization).toBe("Bearer session")
  })

  it("surfaces failures with status", async () => {
    const failing = fetchStub(() => jsonResponse({}, 401))
    const error = await provisionMachine(failing.fetch, "https://c", "bad", "vps").catch(
      (thrown: CloudApiError) => thrown
    )
    expect(error).toBeInstanceOf(CloudApiError)
    expect((error as CloudApiError).status).toBe(401)
  })
})

describe("discoverInstance", () => {
  it("accepts codevisor cloud instances and rejects everything else", async () => {
    const good = fetchStub(() =>
      jsonResponse({
        service: "codevisor-cloud",
        instance: "Test",
        version: "0.1.0",
        protocols: [1],
        authProviders: ["github"]
      })
    )
    const info = await discoverInstance(good.fetch, "https://cloud.example")
    expect(info.instance).toBe("Test")
    expect(good.calls[0]?.input).toBe("https://cloud.example/.well-known/codevisor")

    const wrongService = fetchStub(() => jsonResponse({ service: "something-else" }))
    await expect(discoverInstance(wrongService.fetch, "https://x")).rejects.toThrow(
      "not a codevisor cloud instance"
    )
    const missing = fetchStub(() => jsonResponse({}, 404))
    await expect(discoverInstance(missing.fetch, "https://x")).rejects.toThrow(
      "instance discovery failed"
    )
  })
})
