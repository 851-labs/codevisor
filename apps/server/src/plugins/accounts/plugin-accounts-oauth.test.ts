import type { PluginAccountSpec } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import {
  appRedirectSpec,
  callbackUrl,
  clientFields,
  cloudRedirect,
  exampleSpec,
  failure,
  oauthFixture
} from "./plugin-account-oauth-test-support.js"
import { oauthFlowLifetimeMs } from "./plugin-account-oauth.js"
import type { AccountChecker } from "./plugin-accounts.js"
import type { FakeOAuthProvider } from "./plugin-oauth-test-support.js"

const graphqlSpec = (provider: FakeOAuthProvider): PluginAccountSpec => ({
  label: "Workspace",
  oauth: provider.spec({
    scopeDelimiter: ",",
    userinfoQuery: "query Identity { viewer { email organization { id } } }",
    identityField: "data.viewer.email",
    routeKeyField: "data.viewer.organization.id"
  }),
  fields: clientFields
})

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

  it("sends the provider to a fixed redirect that returns to the app's URL scheme", async () => {
    const { accounts, provider, server, signIn } = await oauthFixture(appRedirectSpec)

    const { started, grant } = await signIn({ callbackScheme: "codevisor-dev-ff7f4cf1a4" })
    await accounts.completeOAuth(grant.state, grant.code)

    expect(started.callbackScheme).toBe("codevisor-dev-ff7f4cf1a4")
    expect(new URL(started.authorizationUrl).searchParams.get("redirect_uri")).toBe(cloudRedirect)
    expect(grant.state.split(".")[1]).toBe("codevisor-dev-ff7f4cf1a4")
    expect(provider.tokenForms[0]).toMatchObject({ redirect_uri: cloudRedirect })
    expect(await accounts.list(server.id)).toMatchObject([{ identity: "dana@example.com" }])
  })

  it("refuses a fixed-redirect sign-in that doesn't name a Codevisor app scheme", async () => {
    const { signIn } = await oauthFixture(appRedirectSpec)

    for (const callbackScheme of [undefined, "https", "codevisor-dev-../evil"])
      await expect(signIn(callbackScheme === undefined ? {} : { callbackScheme })).rejects.toEqual(
        failure(
          400,
          "Start this sign-in from the Codevisor app, or sign this machine in to Codevisor Cloud so it can finish from any device"
        )
      )
  })

  it("signs in to a GraphQL provider with comma-separated scopes and keeps its route key private", async () => {
    const viewer = { data: { viewer: { email: "dana@acme.com", organization: { id: "org-1" } } } }
    const { accounts, provider, server, changes, signIn } = await oauthFixture(graphqlSpec, {
      identity: viewer
    })

    const { started, grant } = await signIn()
    await accounts.completeOAuth(grant.state, grant.code)

    expect(new URL(started.authorizationUrl).searchParams.get("scope")).toBe("mail.read,openid")
    expect(provider.userinfoRequests).toEqual([
      {
        method: "POST",
        body: JSON.stringify({ query: "query Identity { viewer { email organization { id } } }" })
      }
    ])
    expect(await accounts.list(server.id)).toEqual([
      expect.not.objectContaining({ routeKey: expect.anything() })
    ])
    expect(await accounts.context(server.id)).toMatchObject({
      identity: "dana@acme.com",
      routeKey: "org-1"
    })
    expect(JSON.stringify(changes)).toContain('"routeKey":"org-1"')
  })

  it("lets the plugin name a new sign-in and route it by several keys", async () => {
    const checked: Array<unknown> = []
    const check: AccountChecker = async (_server, account) => {
      checked.push(account)
      if (account.accessToken !== "access-1") throw failure(400, "Sentry rejected the sign-in")
      return { identity: "dana@acme.com", routeKeys: ["101", "202"] }
    }
    const { accounts, server, changes, signIn } = await oauthFixture(
      exampleSpec,
      {},
      { catalogId: "example.mail", check }
    )

    const { grant } = await signIn()
    await accounts.completeOAuth(grant.state, grant.code)

    expect(checked).toEqual([
      {
        id: expect.any(String),
        accessToken: "access-1",
        fields: { clientId: "client-1", clientSecret: "client-secret" }
      }
    ])
    expect(await accounts.list(server.id)).toEqual([
      expect.objectContaining({ label: "dana@acme.com", identity: "dana@acme.com" })
    ])
    expect(await accounts.list(server.id)).toEqual([
      expect.not.objectContaining({ routeKeys: expect.anything() })
    ])
    expect(await accounts.context(server.id)).toMatchObject({ routeKeys: ["101", "202"] })
    expect(JSON.stringify(changes)).toContain('"routeKeys":["101","202"]')
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

  it("signs in with the build's installed client and keeps it in the vault for refreshes", async () => {
    const providers: Array<string> = []
    const { accounts, provider, server, vault, signIn, storedCredential } = await oauthFixture(
      (fake) => ({
        label: "Google account",
        oauth: fake.spec({ client: "installed" }),
        fields: []
      }),
      {},
      {
        catalogId: "example.mail",
        installedClients: async (name) => {
          providers.push(name)
          return { clientId: "desktop-client", clientSecret: "desktop-secret" }
        }
      }
    )

    const { started, grant } = await signIn({ values: {} })
    await accounts.completeOAuth(grant.state, grant.code)

    const [account] = await accounts.list(server.id)
    const bundle = await vault.token(await storedCredential(account!.id))
    expect(providers).toEqual(["example"])
    expect(new URL(started.authorizationUrl).searchParams.get("client_id")).toBe("desktop-client")
    expect(provider.tokenForms[0]).toMatchObject({
      client_id: "desktop-client",
      client_secret: "desktop-secret"
    })
    expect(account).toMatchObject({ identity: "dana@example.com", secretsSet: [] })
    expect(bundle.credential).toMatchObject({
      client: { client_id: "desktop-client", client_secret: "desktop-secret" }
    })
    expect((await accounts.context(server.id))?.fields).toEqual({})
  })

  it("explains that sign-in isn't set up when the build has no installed client", async () => {
    const { accounts, server } = await oauthFixture(
      (fake) => ({
        label: "Google account",
        oauth: fake.spec({ client: "installed" }),
        fields: []
      }),
      {},
      { catalogId: "example.mail", installedClients: async () => undefined }
    )
    const { accounts: defaults, server: defaultServer } = await oauthFixture((fake) => ({
      label: "Google account",
      oauth: fake.spec({ client: "installed" }),
      fields: []
    }))

    const missing = accounts.startOAuth(server.id, { values: {} })
    const unconfigured = defaults.startOAuth(defaultServer.id, { values: {} })

    await expect(missing).rejects.toEqual(
      failure(409, "Mail sign-in isn't set up in this build of Codevisor")
    )
    await expect(unconfigured).rejects.toEqual(
      failure(409, "Mail sign-in isn't set up in this build of Codevisor")
    )
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
