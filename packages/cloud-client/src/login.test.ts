import { describe, expect, it } from "vitest"

import {
  CloudApiError,
  createMachineInvite,
  decodeMachineInviteCode,
  discoverInstance,
  MACHINE_CLIENT_ID,
  pollDeviceToken,
  provisionMachine,
  encodeMachineInviteCode,
  redeemMachineInvite,
  removeMachineFromAccount,
  removeMachinePeer,
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

  it("accepts hostnames longer than the Cloud credential label limit", async () => {
    const { calls, fetch } = fetchStub((_input, init) => {
      const body = JSON.parse(init?.body as string) as { name: string }
      return body.name.length <= 32 ? jsonResponse({ key: "api-key" }) : jsonResponse({}, 400)
    })
    const credentials = await provisionMachine(
      fetch,
      "https://cloud.example",
      "session",
      "codevisor-dev-dev-direct-cream--5ea97d382f"
    )
    expect(credentials.apiKey).toBe("api-key")
    expect(JSON.parse(calls[0]?.init?.body as string).name).toBe("codevisor-dev-dev-direct-cream--")
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

describe("removeMachineFromAccount", () => {
  it("deletes the machine with its own api key", async () => {
    const { calls, fetch } = fetchStub(() => jsonResponse({ ok: true }))
    const signal = new AbortController().signal
    await removeMachineFromAccount(
      fetch,
      { serverUrl: "https://cloud.example", apiKey: "machine-key" },
      signal
    )
    expect(calls[0]?.input).toBe("https://cloud.example/api/machine/self")
    expect(calls[0]?.init).toMatchObject({
      method: "DELETE",
      headers: { "x-api-key": "machine-key" },
      signal
    })
  })

  it("throws CloudApiError when the cloud refuses", async () => {
    const { fetch } = fetchStub(() => jsonResponse({ error: "invalid machine credential" }, 401))
    await expect(
      removeMachineFromAccount(fetch, { serverUrl: "https://cloud.example", apiKey: "revoked" })
    ).rejects.toMatchObject({ name: "CloudApiError", status: 401 })
  })
})

describe("machine invites", () => {
  const token = "t".repeat(43)

  it("mints a code that carries its cloud and redeems it there", async () => {
    const minted = fetchStub(() => jsonResponse({ token, expiresAt: "2100-01-01T00:10:00.000Z" }))
    const invite = await createMachineInvite(minted.fetch, {
      serverUrl: "http://localhost:8787/",
      apiKey: "machine-key"
    })
    expect(minted.calls[0]?.input).toBe("http://localhost:8787/api/machine/invites")
    expect(new Headers(minted.calls[0]?.init?.headers).get("x-api-key")).toBe("machine-key")
    expect(decodeMachineInviteCode(invite.code)).toEqual({
      serverUrl: "http://localhost:8787",
      token
    })

    const redeemed = fetchStub(() => jsonResponse({ key: "new-key" }))
    const credentials = await redeemMachineInvite(redeemed.fetch, invite.code, "hetzner-1")
    expect(redeemed.calls[0]?.input).toBe("http://localhost:8787/api/machine/invites/redeem")
    const sent = JSON.parse(redeemed.calls[0]?.init?.body as string) as Record<string, string>
    // The secret key stays here; the cloud only learns the public half.
    expect(sent).toEqual({
      token,
      name: "hetzner-1",
      deviceId: credentials.deviceId,
      publicKey: credentials.publicKey
    })
    expect(credentials).toMatchObject({ serverUrl: "http://localhost:8787", apiKey: "new-key" })
    expect(credentials.secretKey).toBeTruthy()
  })

  it("rejects malformed codes without a request", async () => {
    const valid = encodeMachineInviteCode("https://cloud.example", token)
    for (const code of [
      "",
      "cvi1.x",
      `cvi2.aGk.${token}`,
      `cvi1.bm90IGEgdXJs.${token}`,
      `${valid}.extra`,
      encodeMachineInviteCode("https://cloud.example", "short"),
      encodeMachineInviteCode("ftp://cloud.example", token),
      `cvi1.@@@@.${token}`
    ]) {
      expect(decodeMachineInviteCode(code)).toBeUndefined()
    }
    const never = fetchStub(() => jsonResponse({}))
    await expect(redeemMachineInvite(never.fetch, "nope", "box")).rejects.toThrow(CloudApiError)
    expect(never.calls).toHaveLength(0)
  })

  it("surfaces a refused redemption, with or without a reason", async () => {
    const code = encodeMachineInviteCode("https://cloud.example", token)
    const refused = fetchStub(() => jsonResponse({ error: "This invite is invalid" }, 401))
    await expect(redeemMachineInvite(refused.fetch, code, "box")).rejects.toMatchObject({
      message: "This invite is invalid",
      status: 401
    })
    const garbled = fetchStub(() => new Response("<html>bad gateway</html>", { status: 502 }))
    await expect(redeemMachineInvite(garbled.fetch, code, "box")).rejects.toMatchObject({
      message: "machine invite redemption failed",
      status: 502
    })
    await expect(
      createMachineInvite(garbled.fetch, { serverUrl: "https://c.example", apiKey: "k" })
    ).rejects.toMatchObject({ message: "machine invite failed", status: 502 })
  })

  it("removes another machine as this one, reporting why it couldn't", async () => {
    const credentials = { serverUrl: "https://cloud.example", apiKey: "machine-key" }
    const removed = fetchStub(() => jsonResponse({ ok: true }))
    await removeMachinePeer(removed.fetch, credentials, "device/1")
    expect(removed.calls[0]?.input).toBe("https://cloud.example/api/machine/peers/device%2F1")
    expect(removed.calls[0]?.init?.method).toBe("DELETE")
    expect(new Headers(removed.calls[0]?.init?.headers).get("x-api-key")).toBe("machine-key")

    const unknown = fetchStub(() => jsonResponse({ error: "unknown machine" }, 404))
    await expect(removeMachinePeer(unknown.fetch, credentials, "gone")).rejects.toMatchObject({
      message: "unknown machine",
      status: 404
    })
    const garbled = fetchStub(() => new Response("oops", { status: 500 }))
    await expect(removeMachinePeer(garbled.fetch, credentials, "x")).rejects.toMatchObject({
      message: "machine removal failed",
      status: 500
    })
  })

  it("surfaces the cloud's refusal", async () => {
    const refused = fetchStub(() => jsonResponse({ error: "invalid machine credential" }, 401))
    await expect(
      createMachineInvite(refused.fetch, { serverUrl: "https://c.example", apiKey: "k" })
    ).rejects.toMatchObject({ message: "invalid machine credential", status: 401 })
  })
})
