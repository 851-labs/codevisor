import { makeHarnessAuthManager, SharedCredentialError } from "@codevisor/harness-manager"
import { afterEach, expect, it, vi } from "vitest"

import { fleet } from "../infra/shared-accounts-test-support.js"
import { providerSlot } from "../infra/shared-provider-store.js"
import { jsonRequest, startWithApp, runningServers } from "../test-support.js"

afterEach(() => {
  vi.useRealTimers()
  vi.restoreAllMocks()
})

it("manages Grok's shared account through HTTP while preserving local overrides and encrypted credentials", async () => {
  vi.useFakeTimers({ toFake: ["Date"] })
  vi.setSystemTime(1000)
  const f = fleet(),
    a = await f.machine("grok-a"),
    b = await f.machine("grok-b")
  const auth = makeHarnessAuthManager({
    db: a.db,
    agents: a.services.agents,
    terminal: a.services.terminal,
    dataDir: a.dataDir,
    resolveEnv: async () => ({ HOME: a.dataDir }),
    sharedProviders: () => a.shared.providers
  })
  const server = await startWithApp({ ...a.services, auth })
  runningServers.push(server)
  const send = (body: unknown) =>
    jsonRequest(server, "/v1/harnesses/grok-build/shared-accounts", {
      method: "POST",
      body: JSON.stringify(body)
    })
  const initial = await auth.accounts("grok-build", true)
  const account = initial[0]!,
    accountId = account.id
  expect((await send({ action: "list" })).body).toMatchObject({
    accounts: [{ authState: "unauthenticated", canLogin: true }]
  })
  const key = "xai-private-fleet-key-1234"
  expect((await send({ action: "login", accountId, methodId: "apiKey", apiKey: key })).status).toBe(
    201
  )
  const listed = await send({ action: "list" })
  expect(listed.body).toMatchObject({
    accounts: [{ authState: "authenticated", label: "API key ••••1234", authMethod: "apiKey" }]
  })
  expect(JSON.stringify(listed.body)).not.toContain(key)
  expect(JSON.stringify(await a.shared.store.entries())).not.toContain(key)
  await f.sync(a, b)
  expect(await b.shared.providers.account(account, true)).toMatchObject({
    authState: "authenticated",
    authMethod: "apiKey"
  })
  const context = await b.shared.providers.context(account, {
    id: accountId,
    profileKind: "default"
  })
  expect(context.env).toMatchObject({ XAI_API_KEY: key })
  // Inherited OAuth state is removed, never blanked: Grok reads an empty
  // `GROK_AUTH` as a supplied credential and then refuses to start sessions.
  expect(context.env).not.toHaveProperty("GROK_AUTH")
  expect(context.env).not.toHaveProperty("GROK_AUTH_PROVIDER_COMMAND")
  expect(context.unsetEnv).toEqual(
    expect.arrayContaining(["GROK_AUTH", "GROK_AUTH_PROVIDER_COMMAND"])
  )
  expect((await send({ action: "probe", accountId })).body).toMatchObject({
    account: { authState: "authenticated" }
  })
  expect((await send({ action: "activate", accountId })).status).toBe(200)
  await auth.beginLogin(accountId, "apiKey", "local-private-key-5678")
  expect((await auth.accounts("grok-build"))[0]).toMatchObject({
    label: "API key ••••5678",
    selectionScope: "machine"
  })
  expect((await send({ action: "list" })).body).toMatchObject({
    accounts: [{ label: "API key ••••1234", selectionScope: "shared" }]
  })
  await send({ action: "login", accountId, methodId: "apiKey", apiKey: "new-fleet-key-9999" })
  expect((await auth.accounts("grok-build"))[0]?.label).toBe("API key ••••5678")
  await auth.beginLogin(accountId, "apiKey", "new-fleet-key-9999")
  expect((await auth.accounts("grok-build"))[0]?.selectionScope).toBe("shared")
  await auth.logout(accountId)
  expect((await auth.accounts("grok-build"))[0]?.authState).toBe("unauthenticated")
  expect((await send({ action: "probe", accountId })).body).toMatchObject({
    account: { authState: "authenticated" }
  })
  expect((await send({ action: "cancel", accountId, flowId: "already-complete" })).status).toBe(200)
  expect((await send({ action: "cancel", accountId })).status).toBe(400)
  expect((await send({ action: "rename", accountId, label: "unused" })).status).toBe(400)
  expect((await send({ action: "probe", accountId: "unknown" })).status).toBe(404)
  expect((await send({ action: "probe" })).status).toBe(404)
  expect((await send({ action: "logout", accountId })).status).toBe(200)
  await f.sync(a, b)
  expect((await b.shared.providers.account(account)).authState).toBe("unauthenticated")
  expect((await send({ action: "remove", accountId })).status).toBe(200)
})

it("reports Grok OAuth identity and refresh failures without hiding the account or exposing secrets", async () => {
  vi.useFakeTimers({ toFake: ["Date"] })
  vi.setSystemTime(1000)
  const host = await fleet().machine("grok-identity")
  const account = {
    id: "default",
    harnessId: "grok-build",
    profileKind: "default" as const,
    label: "Old",
    authState: "unauthenticated" as const,
    isActive: true,
    canLogin: true,
    canLogout: false
  }
  const capture = async (claims: object) =>
    host.shared.providers.capture(
      "grok-build",
      "default",
      "xai",
      {
        auth_mode: "oidc",
        key: `h.${Buffer.from(JSON.stringify(claims)).toString("base64url")}.s`,
        refresh_token: "private-refresh",
        expires_at: new Date(3_600_000).toISOString(),
        oidc_issuer: "https://auth.x.ai",
        oidc_client_id: "b1a00492-073a-47ea-816f-4c329264a828"
      },
      true
    )
  await capture({ sub: "person", email: "person@example.test" })
  expect(await host.shared.providers.account(account)).toMatchObject({
    authMethod: "oauth",
    label: "person@example.test",
    email: "person@example.test"
  })
  await capture({ sub: "person" })
  expect((await host.shared.providers.account(account)).label).toBe("Grok")
  const token = vi.spyOn(host.vault, "token")
  token.mockRejectedValueOnce(new SharedCredentialError("offline"))
  expect(await host.shared.providers.account(account)).toMatchObject({
    authState: "expired",
    canLogout: true,
    detail: "Account sync is unavailable. Try again when connected."
  })
  token.mockRejectedValueOnce(new Error("secret backend data"))
  expect(await host.shared.providers.account(account)).toMatchObject({
    authState: "expired",
    detail: "Account sync is unavailable. Try again."
  })
  expect(
    JSON.stringify(
      await host.shared.providers.store.get(providerSlot("grok-build", "default", "xai"))
    )
  ).not.toContain("private-refresh")
})
