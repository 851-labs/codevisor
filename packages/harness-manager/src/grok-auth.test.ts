import { mkdtemp, rm } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import { makeDatabase } from "@codevisor/db"
import type { TerminalManagerService } from "@codevisor/terminal"
import type { OAuthAuth, OAuthCredential } from "@earendil-works/pi-ai"
import { Effect } from "effect"
import { afterEach, expect, it, onTestFinished, vi } from "vitest"

import { makeGrokDeviceLogin } from "./grok-device-auth.js"
import { makeHarnessAuthManager } from "./harness-auth.js"
import type { SharedProviderIntegration } from "./shared-provider-integration.js"

type ProviderAuthInteraction = Parameters<OAuthAuth["login"]>[0]

const credential: OAuthCredential = {
  type: "oauth",
  access: "access",
  refresh: "refresh",
  expires: 3_600_000
}
const device = {
  type: "device_code" as const,
  userCode: "ABCD-EFGH",
  verificationUri: "https://auth.x.ai/device"
}
const oauth = (login: OAuthAuth["login"]): OAuthAuth => ({
  name: "xAI",
  login,
  refresh: async (value) => value,
  toAuth: async (value) => ({ apiKey: value.access })
})
afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})
const fixture = async (grokOAuth?: OAuthAuth, available = true) => {
  const directory = await mkdtemp(join(tmpdir(), "grok-login-"))
  const db = await Effect.runPromise(
    makeDatabase({ filename: join(directory, "test.sqlite"), serverId: "test" })
  )
  onTestFinished(async () => {
    await Effect.runPromise(db.close)
    await rm(directory, { recursive: true, force: true })
  })
  let signedIn = false
  const shared: SharedProviderIntegration = {
    capture: vi.fn(async () => {
      signedIn = true
      return true
    }),
    configured: async () => [],
    remove: vi.fn(async () => {
      signedIn = false
      return true
    }),
    context: async (_account, base) => base,
    account: vi.fn(async (account) => ({
      ...account,
      authState: signedIn ? "authenticated" : "unauthenticated",
      canLogout: signedIn
    }))
  }
  const authenticateHarness = vi.fn()
  const manager = makeHarnessAuthManager({
    db,
    dataDir: directory,
    resolveEnv: async () => ({ HOME: directory }),
    terminal: {} as TerminalManagerService,
    agents: { authenticateHarness } as unknown as AgentRuntimeService,
    sharedProviders: () => (available ? shared : undefined),
    ...(grokOAuth ? { grokOAuth } : {})
  })
  const finish = Promise.withResolvers<void>()
  manager.subscribe((event) => {
    if (
      event.kind === "harness.account.updated" &&
      Object.keys(event.payload as object).length === 1
    )
      finish.resolve()
  })
  return { manager, shared, db, authenticateHarness, finish: finish.promise }
}

it("returns Grok's device code before approval, shares the grant, and never launches the remote CLI", async () => {
  vi.useFakeTimers()
  vi.setSystemTime(1000)
  const fetch = vi
    .fn()
    .mockResolvedValueOnce(
      Response.json({
        device_code: "private-code",
        user_code: device.userCode,
        verification_uri: device.verificationUri,
        interval: 5,
        expires_in: 600
      })
    )
    .mockResolvedValueOnce(
      Response.json({ access_token: "access", refresh_token: "refresh", expires_in: 3600 })
    )
  vi.stubGlobal("fetch", fetch)
  const poll = Promise.withResolvers<void>()
  const f = await fixture(
    oauth(
      makeGrokDeviceLogin(fetch, async () => {
        await poll.promise
      })
    )
  )
  const row = (await f.manager.accounts("grok-build", true))[0]!
  const flow = await f.manager.beginLogin(row.id, undefined, undefined, true)
  expect(flow).toMatchObject({
    kind: "deviceCode",
    userCode: device.userCode,
    verificationUrl: device.verificationUri
  })
  expect(JSON.stringify(flow)).not.toContain("private-code")
  expect((await f.manager.probeAccount(row.id, true, true)).authState).toBe("checking")
  expect((await f.manager.probeAccount(row.id)).authState).toBe("unauthenticated")
  expect(f.shared.capture).not.toHaveBeenCalled()
  poll.resolve()
  await f.finish
  expect(f.shared.capture).toHaveBeenCalledWith(
    "grok-build",
    "default",
    "xai",
    expect.objectContaining({
      auth_mode: "oidc",
      key: "access",
      refresh_token: "refresh",
      oidc_issuer: "https://auth.x.ai"
    }),
    true
  )
  expect((await f.manager.accounts("grok-build", true))[0]?.authState).toBe("authenticated")
  expect(f.authenticateHarness).not.toHaveBeenCalled()
  await f.manager.logout(row.id, true)
  expect(f.shared.remove).toHaveBeenCalledWith("grok-build", "default", "xai", true)
  expect((await f.manager.accounts("grok-build", true))[0]?.authState).toBe("unauthenticated")
})

it("cancels the old attempt before another starts and prevents a late grant from being saved", async () => {
  const interactions: ProviderAuthInteraction[] = []
  const f = await fixture(
    oauth(async (interaction) => {
      interactions.push(interaction)
      interaction.notify({ type: "info", message: "Starting" })
      interaction.notify(device)
      return new Promise((resolve) =>
        interaction.signal!.addEventListener(
          "abort",
          () => {
            interaction.notify(device)
            resolve(credential)
          },
          { once: true }
        )
      )
    })
  )
  const row = (await f.manager.accounts("grok-build"))[0]!
  const first = await f.manager.beginLogin(row.id)
  expect((await f.manager.probeAccount(row.id)).authState).toBe("checking")
  const shared = await f.manager.beginLogin(row.id, "grok.com", undefined, true)
  const second = await f.manager.beginLogin(row.id)
  expect(interactions[0]!.signal!.aborted).toBe(true)
  expect(interactions[1]!.signal!.aborted).toBe(false)
  expect(first.id).not.toBe(second.id)
  await f.manager.cancelLogin(first.id)
  await f.manager.logout(row.id)
  expect(interactions[1]!.signal!.aborted).toBe(false)
  expect(interactions[2]!.signal!.aborted).toBe(true)
  await f.manager.cancelLogin(shared.id)
  expect(f.shared.capture).not.toHaveBeenCalled()
  expect((await f.manager.probeAccount(row.id)).authState).toBe("unauthenticated")
})

it("reports denial after the code is shown and permits a fresh attempt", async () => {
  const rejectLogin = Promise.withResolvers<OAuthCredential>()
  const login = vi.fn(async (interaction: ProviderAuthInteraction) => {
    interaction.notify(device)
    return rejectLogin.promise
  })
  const f = await fixture(oauth(login))
  const row = (await f.manager.accounts("grok-build"))[0]!
  await f.manager.beginLogin(row.id)
  rejectLogin.reject(new Error("access_denied with provider internals"))
  await f.finish
  expect(await f.manager.probeAccount(row.id)).toMatchObject({
    authState: "error",
    detail: "Couldn't sign in to Grok. Try again."
  })
  login.mockResolvedValueOnce(credential)
  expect((await f.manager.beginLogin(row.id)).kind).toBe("complete")
  expect((await f.manager.probeAccount(row.id)).authState).toBe("authenticated")
})

it("propagates setup and storage errors instead of leaving the sheet waiting", async () => {
  const f = await fixture(
    oauth(async (interaction) => {
      await interaction.prompt({ type: "text", message: "Unexpected" })
      return credential
    })
  )
  const row = (await f.manager.accounts("grok-build"))[0]!
  await expect(f.manager.beginLogin(row.id)).rejects.toThrow("Couldn't sign in")
  const g = await fixture(oauth(async () => credential))
  const other = (await g.manager.accounts("grok-build"))[0]!
  vi.mocked(g.shared.capture).mockResolvedValueOnce(false)
  await expect(g.manager.beginLogin(other.id)).rejects.toThrow("Couldn't sign in")
})

it("supports API keys in the requested scope and rejects missing keys and unknown methods", async () => {
  const f = await fixture()
  const row = (await f.manager.accounts("grok-build"))[0]!
  for (const key of [undefined, " "])
    await expect(f.manager.beginLogin(row.id, "apiKey", key)).rejects.toThrow("Enter an API key")
  await expect(f.manager.beginLogin(row.id, "unknown")).rejects.toThrow("Choose a Grok")
  expect((await f.manager.beginLogin(row.id, "apiKey", " xai-fixture-key ", true)).kind).toBe(
    "complete"
  )
  expect(f.shared.capture).toHaveBeenCalledWith(
    "grok-build",
    "default",
    "xai",
    { auth_mode: "api_key", key: "xai-fixture-key" },
    true
  )
  expect((await f.manager.beginLogin(row.id, "apiKey", "local-key")).kind).toBe("complete")
  expect(f.shared.capture).toHaveBeenLastCalledWith(
    "grok-build",
    "default",
    "xai",
    { auth_mode: "api_key", key: "local-key" },
    false
  )
  vi.mocked(f.shared.capture).mockResolvedValueOnce(false)
  await expect(f.manager.beginLogin(row.id, "apiKey", "key")).rejects.toThrow("could not be saved")
})

it("surfaces a device-service failure through the production login implementation", async () => {
  const request = vi
    .fn()
    .mockResolvedValue(Response.json({ error: "unavailable" }, { status: 503 }))
  vi.stubGlobal("fetch", request)
  const f = await fixture()
  const row = (await f.manager.accounts("grok-build"))[0]!
  await expect(f.manager.beginLogin(row.id)).rejects.toThrow("Couldn't sign in")
  expect(request).toHaveBeenCalledOnce()
})

it("fails clearly when credential sync is unavailable", async () => {
  const f = await fixture(undefined, false)
  await expect(f.manager.accounts("grok-build")).rejects.toThrow("Account sync is unavailable")
})
