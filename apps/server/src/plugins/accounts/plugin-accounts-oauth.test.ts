import { dirname } from "node:path"

import type { PluginAccountSpec } from "@codevisor/api"
import type { SyncEntryRecord } from "@codevisor/sync"
import { describe, expect, it } from "vitest"

import { manualOAuthClock, sharedCoordinator } from "../../infra/mcp-oauth-test-support.js"
import { mcpCredentialVault } from "../../infra/shared-account-storage.js"
import { HttpFailure } from "../../server-context.js"
import { makeServices } from "../../test-support.js"
import { savePluginRow } from "../events/plugin-events-test-support.js"
import { oauthFlowLifetimeMs } from "./plugin-account-oauth.js"
import { makePluginAccountStore } from "./plugin-account-store.js"
import { makePluginAccounts } from "./plugin-accounts.js"
import {
  fakeOAuthProvider,
  type FakeOAuthProvider,
  type ProviderOptions
} from "./plugin-oauth-test-support.js"

const callbackUrl = "http://127.0.0.1:43210/v1/plugins/oauth/callback"

const clientFields: PluginAccountSpec["fields"] = [
  { key: "clientId", label: "OAuth client ID", type: "string", required: true },
  { key: "clientSecret", label: "OAuth client secret", type: "secret", required: true }
]

interface FixtureOptions {
  readonly catalogId?: string
  readonly revokeFails?: boolean
}

const oauthFixture = async (
  specFor: (provider: FakeOAuthProvider) => PluginAccountSpec | undefined,
  options: ProviderOptions = {},
  fixtureOptions: FixtureOptions = { catalogId: "example.mail" }
) => {
  const { services } = await makeServices("server-a")
  const clock = manualOAuthClock(Date.UTC(2026, 9, 27, 9))
  const vault = mcpCredentialVault(
    dirname(services.attachments.root),
    sharedCoordinator(clock).machine("server-a"),
    clock.now
  )
  const provider = await fakeOAuthProvider(options)
  const server = await savePluginRow(
    services.db,
    "Mail",
    fixtureOptions.catalogId === undefined ? {} : { catalogId: fixtureOptions.catalogId }
  )
  const changes: Array<ReadonlyArray<SyncEntryRecord>> = []
  const accounts = makePluginAccounts({
    store: makePluginAccountStore(services.db, "server-a", clock.now),
    vault:
      fixtureOptions.revokeFails === true
        ? { ...vault, revoke: () => Promise.reject(new Error("vault offline")) }
        : vault,
    server: async (serverId) => {
      if (serverId === server.id) return server
      throw new HttpFailure(404, `Plugin not found: ${serverId}`)
    },
    spec: () => specFor(provider),
    redirects: { prepare: async () => ({ redirectUri: callbackUrl, deviceId: "local" }) },
    onChanged: (entries) => changes.push(entries),
    now: clock.now
  })
  const signIn = async (
    request: {
      readonly label?: string
      readonly accountId?: string
      readonly values?: Record<string, unknown>
    } = {}
  ) => {
    const started = await accounts.startOAuth(server.id, {
      values: request.values ?? { clientId: "client-1", clientSecret: "client-secret" },
      ...(request.label === undefined ? {} : { label: request.label }),
      ...(request.accountId === undefined ? {} : { accountId: request.accountId })
    })
    return { started, grant: provider.authorize(started.authorizationUrl) }
  }
  const storedCredential = async (accountId: string) => {
    const record = await makePluginAccountStore(services.db, "server-a").get(accountId)
    return record!.credential!
  }
  return { accounts, provider, server, clock, vault, changes, signIn, storedCredential }
}

const exampleSpec = (provider: FakeOAuthProvider): PluginAccountSpec => ({
  label: "Example account",
  oauth: provider.spec({ authorizeParams: { access_type: "offline" } }),
  fields: clientFields
})

const failure = (status: number, message: string) => expect.objectContaining({ status, message })

describe("plugin account OAuth", () => {
  it("signs in with PKCE and names the account after the provider's identity", async () => {
    const { accounts, provider, server, changes, signIn } = await oauthFixture(exampleSpec, {
      scope: "mail.read openid",
      expiresIn: 3600
    })

    const { started, grant } = await signIn()
    await accounts.completeOAuth(grant.state, grant.code)

    const authorization = new URL(started.authorizationUrl).searchParams
    expect(Object.fromEntries(authorization)).toMatchObject({
      response_type: "code",
      client_id: "client-1",
      redirect_uri: callbackUrl,
      scope: "mail.read openid",
      code_challenge_method: "S256",
      access_type: "offline"
    })
    expect(grant.state).toMatch(new RegExp(`^${started.flowId}\\.local\\.[\\w-]+$`))
    expect(provider.tokenForms[0]).toMatchObject({
      grant_type: "authorization_code",
      client_secret: "client-secret"
    })
    expect(await accounts.list(server.id)).toEqual([
      {
        id: expect.any(String),
        plugin: "example.mail",
        label: "dana@example.com",
        identity: "dana@example.com",
        method: "oauth2",
        values: { clientId: "client-1" },
        secretsSet: ["clientSecret"],
        scopes: ["mail.read", "openid"],
        status: "ok",
        createdAt: expect.any(String)
      }
    ])
    expect(JSON.stringify(changes)).not.toMatch(/access-1|refresh-1|client-secret/)
  })

  it("hands plugins the access token and fields, never the refresh token", async () => {
    const { accounts, server, signIn } = await oauthFixture(exampleSpec)
    const { grant } = await signIn()
    await accounts.completeOAuth(grant.state, grant.code)

    const context = await accounts.context(server.id)

    expect(context).toEqual({
      id: expect.any(String),
      label: "dana@example.com",
      identity: "dana@example.com",
      accessToken: "access-1",
      fields: { clientId: "client-1", clientSecret: "client-secret" }
    })
    expect(JSON.stringify(context)).not.toContain("refresh-1")
  })

  it("re-authorizes an account in place, keeping its label and revoking the old grant", async () => {
    const { accounts, server, vault, signIn, storedCredential } = await oauthFixture(exampleSpec)
    const first = await signIn({ label: "Work" })
    await accounts.completeOAuth(first.grant.state, first.grant.code)
    const [account] = await accounts.list(server.id)
    const oldCredential = await storedCredential(account!.id)

    const again = await signIn({ accountId: account!.id, values: { clientId: "client-1" } })
    await accounts.completeOAuth(again.grant.state, again.grant.code)

    expect(await accounts.list(server.id)).toEqual([account])
    expect((await accounts.context(server.id, "Work"))?.accessToken).toBe("access-2")
    await expect(vault.token(oldCredential)).rejects.toThrow()
  })

  it.each([
    {
      name: "a requested label",
      spec: { userinfoUrl: undefined },
      provider: {},
      label: "Personal",
      identity: "Personal"
    },
    {
      name: "Account",
      spec: { userinfoUrl: undefined },
      provider: {},
      label: undefined,
      identity: "Account"
    },
    {
      name: "the label when userinfo fails",
      spec: {},
      provider: { userinfoStatus: 500 },
      label: "Inbox",
      identity: "Inbox"
    },
    {
      name: "the configured identity field",
      spec: { identityField: "login" },
      provider: { identity: { login: "dana" } },
      label: undefined,
      identity: "dana"
    },
    {
      name: "Account without that field",
      spec: { identityField: "login" },
      provider: {},
      label: undefined,
      identity: "Account"
    },
    {
      name: "Account for a userinfo that isn't an object",
      spec: {},
      provider: { identity: "dana@example.com" },
      label: undefined,
      identity: "Account"
    }
  ])(
    "falls back to $name for the identity",
    async ({ spec, provider: providerOptions, label, identity }) => {
      const { accounts, server, signIn } = await oauthFixture(
        (provider) => ({ ...exampleSpec(provider), oauth: provider.spec(spec) }),
        { ...providerOptions, refreshToken: false }
      )

      const { grant } = await signIn(label === undefined ? {} : { label })
      await accounts.completeOAuth(grant.state, grant.code)

      expect((await accounts.list(server.id))[0]?.identity).toBe(identity)
    }
  )

  it("signs in a public client of a custom plugin without a client secret", async () => {
    const { accounts, provider, server, signIn } = await oauthFixture(
      (fake) => ({ label: "Mail", oauth: fake.spec(), fields: clientFields.slice(0, 1) }),
      {},
      {}
    )

    const { grant } = await signIn({ values: { clientId: "public-client" } })
    await accounts.completeOAuth(grant.state, grant.code)

    expect(provider.tokenForms[0]).not.toHaveProperty("client_secret")
    expect(await accounts.list(server.id)).toEqual([
      expect.objectContaining({ plugin: "Mail", secretsSet: [] })
    ])
  })

  it("re-authorizes even when the vault can't revoke the old grant", async () => {
    const { accounts, server, signIn } = await oauthFixture(
      exampleSpec,
      {},
      { catalogId: "example.mail", revokeFails: true }
    )
    const first = await signIn()
    await accounts.completeOAuth(first.grant.state, first.grant.code)
    const [account] = await accounts.list(server.id)

    const again = await signIn({ accountId: account!.id })
    await accounts.completeOAuth(again.grant.state, again.grant.code)

    expect((await accounts.context(server.id, account!.id))?.accessToken).toBe("access-2")
  })

  it("refuses unknown, tampered and expired sign-in links", async () => {
    const { accounts, clock, signIn } = await oauthFixture(exampleSpec)
    const expired = "This sign-in link expired. Start again."
    const { started, grant } = await signIn()
    const stale = await signIn()

    for (const state of ["garbage", "a.b", ".local.nonce", `${started.flowId}.local.wrong-nonce`]) {
      await expect(accounts.completeOAuth(state, grant.code)).rejects.toEqual(failure(400, expired))
    }
    await accounts.completeOAuth(grant.state, grant.code)
    clock.advance(oauthFlowLifetimeMs + 1)

    await expect(accounts.completeOAuth(stale.grant.state, stale.grant.code)).rejects.toEqual(
      failure(400, expired)
    )
  })

  it("reports a cancelled sign-in and forgets the flow", async () => {
    const { accounts, signIn } = await oauthFixture(exampleSpec)
    const denied = await signIn()
    const abandoned = await signIn()

    await expect(
      accounts.completeOAuth(denied.grant.state, undefined, "access_denied")
    ).rejects.toEqual(failure(400, "Sign-in was cancelled (access_denied)"))
    await expect(accounts.completeOAuth(abandoned.grant.state, undefined)).rejects.toEqual(
      failure(400, "Sign-in was cancelled (no code)")
    )
    await expect(accounts.completeOAuth(denied.grant.state, denied.grant.code)).rejects.toEqual(
      failure(400, "This sign-in link expired. Start again.")
    )
  })

  it("saves nothing when the provider rejects the code", async () => {
    const { accounts, server, signIn } = await oauthFixture(exampleSpec)
    const { grant } = await signIn()

    await expect(accounts.completeOAuth(grant.state, "forged-code")).rejects.toThrow()

    expect(await accounts.list(server.id)).toEqual([])
  })

  it.each([
    {
      name: "no account spec",
      spec: () => undefined,
      message: "Mail doesn't use Codevisor accounts"
    },
    {
      name: "no OAuth",
      spec: () => ({ label: "Mail", fields: [] }),
      message: "Mail doesn't sign in with OAuth"
    },
    {
      name: "Codevisor's managed client",
      spec: (provider: FakeOAuthProvider) => ({
        label: "Mail",
        oauth: provider.spec({ client: "managed" }),
        fields: []
      }),
      message: "Codevisor's shared client isn't available yet"
    },
    {
      name: "no client ID",
      spec: (provider: FakeOAuthProvider) => ({
        label: "Mail",
        oauth: provider.spec(),
        fields: []
      }),
      message: "OAuth client ID is required"
    }
  ])("refuses to start OAuth with $name", async ({ spec, message }) => {
    const { accounts, server } = await oauthFixture(spec)

    const starting = accounts.startOAuth(server.id, { values: {} })

    await expect(starting).rejects.toEqual(failure(400, message))
  })

  it("refuses to re-authorize an account the plugin doesn't have", async () => {
    const { accounts, server } = await oauthFixture(exampleSpec)

    const starting = accounts.startOAuth(server.id, { values: {}, accountId: "missing" })

    await expect(starting).rejects.toEqual(failure(404, "Account not found: missing"))
  })
})
