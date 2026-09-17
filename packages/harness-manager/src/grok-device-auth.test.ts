import { afterEach, expect, it, vi } from "vitest"

import { loginGrok, makeGrokDeviceLogin, GROK_CLIENT_ID } from "./grok-device-auth.js"

const device = {
  device_code: "private-device",
  user_code: "ABCD-EFGH",
  verification_uri: "https://auth.x.ai/device",
  expires_in: 60
}
const token = { access_token: "access", refresh_token: "refresh", expires_in: 3600 }
const fixture = (responses: Response[]) => {
  let time = 1000
  const wait = vi.fn(async (ms: number) => {
    time += ms
  })
  const request = vi.fn<typeof fetch>()
  for (const response of responses) request.mockResolvedValueOnce(response)
  const notify = vi.fn()
  const login = makeGrokDeviceLogin(
    request,
    wait,
    () => time,
    () => time
  )
  const run = () => login({ notify, prompt: vi.fn(), signal: new AbortController().signal })
  return { run, request, notify, wait, login }
}
afterEach(() => vi.unstubAllGlobals())

it("uses Grok's scopes, preserves identity, respects pending and slowdown, and keeps the device secret off the UI", async () => {
  const f = fixture([
    Response.json({
      ...device,
      verification_uri_complete: "https://auth.x.ai/device?user_code=ABCD-EFGH",
      interval: 2
    }),
    Response.json({ error: "authorization_pending" }, { status: 400 }),
    Response.json({ error: "slow_down" }, { status: 400 }),
    Response.json({ ...token, id_token: "identity" })
  ])
  expect(await f.run()).toMatchObject({
    access: "access",
    refresh: "refresh",
    idToken: "identity",
    expires: 3_612_000
  })
  expect(f.wait.mock.calls.map(([ms]) => ms)).toEqual([2000, 2000, 7000])
  expect(f.notify).toHaveBeenCalledWith({
    type: "device_code",
    userCode: "ABCD-EFGH",
    verificationUri: "https://auth.x.ai/device?user_code=ABCD-EFGH"
  })
  const start = f.request.mock.calls[0]![1]!
  const fields = start.body as URLSearchParams
  expect(fields.get("client_id")).toBe(GROK_CLIENT_ID)
  expect(fields.get("referrer")).toBe("grok-build")
  expect(fields.get("scope")).toContain("workspaces:write")
  expect(fields.get("scope")).toContain("conversations:read")
  expect(start.redirect).toBe("error")
  const poll = f.request.mock.calls[1]![1]!.body as URLSearchParams
  expect(poll.get("device_code")).toBe("private-device")
  expect(JSON.stringify(f.notify.mock.calls)).not.toContain("private-device")
})
it("defaults to a five-second interval and handles a grant without an ID token", async () => {
  const f = fixture([Response.json(device), Response.json(token)])
  expect(await f.login({ notify: f.notify, prompt: vi.fn() })).toEqual({
    type: "oauth",
    access: "access",
    refresh: "refresh",
    expires: 3_606_000
  })
  expect(f.wait.mock.calls[0]?.[0]).toBe(5000)
})
it("stops at expiry without another token request", async () => {
  const f = fixture([Response.json({ ...device, expires_in: 2 })])
  await expect(f.run()).rejects.toThrow("code expired")
  expect(f.request).toHaveBeenCalledTimes(1)
  expect(f.wait.mock.calls[0]?.[0]).toBe(2000)
})
it("honors cancellation while waiting for approval", async () => {
  const abort = new AbortController()
  const request = vi.fn<typeof fetch>().mockResolvedValueOnce(Response.json(device))
  const pending = makeGrokDeviceLogin(request)({
    signal: abort.signal,
    notify: () => abort.abort(),
    prompt: vi.fn()
  })
  await expect(pending).rejects.toThrow()
  expect(request).toHaveBeenCalledTimes(1)
})
it("uses the production request boundary and reports refusal to start", async () => {
  const request = vi
    .fn()
    .mockResolvedValueOnce(Response.json({ error: "disabled" }, { status: 404 }))
  vi.stubGlobal("fetch", request)
  await expect(loginGrok({ notify: vi.fn(), prompt: vi.fn() })).rejects.toThrow("Couldn't start")
})
it.each([
  null,
  [],
  "invalid",
  { ...device, device_code: "" },
  { ...device, expires_in: -1 },
  { ...device, expires_in: "60" },
  { ...device, verification_uri: "http://example.test" },
  { ...device, verification_uri: "https://user@example.test" },
  { ...device, verification_uri: "https://:pass@example.test" }
])("rejects invalid device responses before notifying the UI (%j)", async (value) => {
  const f = fixture([Response.json(value)])
  await expect(f.run()).rejects.toThrow()
  expect(f.notify).not.toHaveBeenCalled()
})
it.each(["access_denied", "expired_token", "unexpected"])("finishes %s failures", async (error) => {
  const f = fixture([Response.json(device), Response.json({ error }, { status: 400 })])
  await expect(f.run()).rejects.toThrow("declined or expired")
})
it("rejects incomplete token grants", async () => {
  const f = fixture([Response.json(device), Response.json({ ...token, refresh_token: null })])
  await expect(f.run()).rejects.toThrow("Invalid Grok")
})
