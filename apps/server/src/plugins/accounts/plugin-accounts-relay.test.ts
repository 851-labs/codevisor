import type { PluginAccountSpec } from "@codevisor/api"
import type { McpOAuthRelay, McpOAuthRelayRequest } from "@codevisor/mcp"
import { Effect } from "effect"
import { describe, expect, it } from "vitest"

import {
  appRedirectSpec,
  callbackUrl,
  cloudRedirect,
  exampleSpec,
  oauthFixture
} from "./plugin-account-oauth-test-support.js"
import { pendingOAuthSetting } from "./plugin-oauth-storage.js"
import type { FakeOAuthProvider } from "./plugin-oauth-test-support.js"

const cloudCallback = "https://cloud.example/oauth/callback"

const recordingRelay = () => {
  const registered: Array<{ readonly state: string; readonly request?: McpOAuthRelayRequest }> = []
  const relay: McpOAuthRelay = {
    signedInPage: (app) => `https://cloud.example/oauth/signed-in?app=${app ?? ""}`,
    register: async (state, request) => {
      registered.push({ state, ...(request === undefined ? {} : { request }) })
      return request?.accepted?.find((url) => url.startsWith("https://cloud.example/"))
    }
  }
  return { relay, registered }
}

const installedSpec = (provider: FakeOAuthProvider): PluginAccountSpec => ({
  label: "Google account",
  oauth: provider.spec({ client: "installed" }),
  fields: []
})

const installed = (redirectUris?: ReadonlyArray<string>) => async () => ({
  clientId: "desktop-client",
  ...(redirectUris === undefined ? {} : { redirectUris })
})

const redirectOf = (url: string) => new URL(url).searchParams.get("redirect_uri")

describe("plugin account sign-in through Codevisor Cloud", () => {
  it("finishes a fixed-redirect sign-in through Codevisor Cloud, so agents can start it too", async () => {
    const { relay, registered } = recordingRelay()
    const { accounts, provider, server, signIn } = await oauthFixture(
      appRedirectSpec,
      {},
      {
        catalogId: "example.mail",
        relay
      }
    )

    const agent = await signIn()
    const app = await signIn({ callbackScheme: "codevisor" })
    await accounts.completeOAuth(agent.grant.state, agent.grant.code)

    expect(agent.started.callbackScheme).toBeUndefined()
    expect(new URL(agent.started.authorizationUrl).searchParams.get("redirect_uri")).toBe(
      cloudRedirect
    )
    expect(agent.grant.state.split(".")[1]).toBe("cloud")
    expect(registered).toEqual([
      { state: agent.grant.state, request: { accepted: [cloudRedirect] } },
      { state: app.grant.state, request: { accepted: [cloudRedirect], app: "codevisor" } }
    ])
    expect(provider.tokenForms[0]).toMatchObject({ redirect_uri: cloudRedirect })
    expect(await accounts.list(server.id)).toMatchObject([{ identity: "dana@example.com" }])
  })

  it("uses the Cloud callback for an installed client only once its registered redirects list it", async () => {
    const { relay, registered } = recordingRelay()
    const before = await oauthFixture(
      installedSpec,
      {},
      {
        catalogId: "example.mail",
        relay,
        installedClients: installed(["http://localhost"])
      }
    )
    const after = await oauthFixture(
      installedSpec,
      {},
      {
        catalogId: "example.mail",
        relay,
        installedClients: installed(["http://localhost", cloudCallback])
      }
    )

    const local = await before.signIn({ values: {} })
    const relayed = await after.signIn({ values: {} })

    expect(redirectOf(local.started.authorizationUrl)).toBe(callbackUrl)
    expect(redirectOf(relayed.started.authorizationUrl)).toBe(cloudCallback)
    expect(registered.map((entry) => entry.request?.accepted)).toEqual([
      ["http://localhost"],
      ["http://localhost", cloudCallback]
    ])
  })

  it("keeps a pending sign-in, sealed, across a server restart", async () => {
    const { db, provider, server, signIn, restarted } = await oauthFixture(exampleSpec)
    const { grant } = await signIn()

    const sealed = await Effect.runPromise(db.getMachineSetting(pendingOAuthSetting))
    const afterRestart = restarted()
    await afterRestart.completeOAuth(grant.state, grant.code)

    expect(sealed).not.toMatch(/client-secret|client-1/)
    expect(provider.tokenForms[0]).toMatchObject({ client_secret: "client-secret" })
    expect(await afterRestart.list(server.id)).toMatchObject([{ identity: "dana@example.com" }])
    expect(await Effect.runPromise(db.getMachineSetting(pendingOAuthSetting))).toBeUndefined()
  })
})
