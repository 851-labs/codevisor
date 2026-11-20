import type { McpOAuthRelay, McpOAuthRelayRequest } from "@codevisor/mcp"
import { describe, expect, it } from "vitest"

import { makeServices } from "../test-support.js"
import {
  fakeOAuthMcpServer,
  listenOn,
  machineVault,
  manualOAuthClock,
  sharedCoordinator,
  tempDirectory
} from "./mcp-oauth-test-support.js"

const cloudCallback = "https://cloud.example/oauth/callback"

const recordingRelay = () => {
  const registered: Array<{ readonly state: string; readonly request?: McpOAuthRelayRequest }> = []
  const relay: McpOAuthRelay = {
    signedInPage: (app) => `https://cloud.example/oauth/signed-in?app=${app ?? ""}`,
    register: async (state, request) => {
      registered.push({ state, ...(request === undefined ? {} : { request }) })
      return cloudCallback
    }
  }
  return { relay, registered }
}

const relayedMachine = async (options: { readonly loopbackOnly?: boolean } = {}) => {
  const clock = manualOAuthClock()
  const fake = await fakeOAuthMcpServer(clock, 3600, options)
  const { relay, registered } = recordingRelay()
  const { services } = await makeServices("server-a", {
    oauthClock: clock,
    oauthRelay: relay,
    oauthVault: machineVault(sharedCoordinator(clock), "server-a", clock, await tempDirectory())
  })
  const manager = services.mcp
  const loopback = await listenOn(manager.handleGatewayRequest)
  manager.setBaseUrl(loopback)
  const create = (extra: { readonly oauthClientId?: string } = {}) =>
    manager.create({
      authType: "oauth",
      enabled: true,
      name: "Tracker",
      transport: "http",
      url: fake.url,
      ...extra
    })
  return { fake, manager, registered, loopback, create }
}

const redirectOf = (authorizationUrl: string) =>
  new URL(authorizationUrl).searchParams.get("redirect_uri")

describe("MCP sign-in through Codevisor Cloud", () => {
  it("registers its own client for Cloud's callback and finishes when the callback is relayed", async () => {
    const { fake, manager, registered, create } = await relayedMachine()
    const created = await create()

    const authorizationUrl = await manager.beginOAuth(created.id, undefined, "codevisor")
    const { code, state, issuer } = fake.approve(authorizationUrl)
    const finished = await manager.finishOAuth(state, code, issuer)

    expect(redirectOf(authorizationUrl)).toBe(cloudCallback)
    expect(fake.registeredRedirects()).toEqual([cloudCallback])
    expect(registered).toEqual([{ state, request: { app: "codevisor" } }])
    expect(finished.authType).toBe("oauth")
    await expect(manager.finishOAuth(state, code, issuer)).rejects.toThrow("Invalid OAuth state")
  })

  it("sends an already signed-in plugin to a page any device can open, not to loopback", async () => {
    const { fake, manager, create } = await relayedMachine()
    const created = await create()
    const { code, state, issuer } = fake.approve(await manager.beginOAuth(created.id))
    await manager.finishOAuth(state, code, issuer)

    const again = await manager.beginOAuth(created.id, undefined, "codevisor")

    expect(again).toBe("https://cloud.example/oauth/signed-in?app=codevisor")
  })

  it("falls back to the loopback callback when the auth server only registers loopback clients", async () => {
    const { fake, manager, loopback, create } = await relayedMachine({ loopbackOnly: true })
    const created = await create()

    const authorizationUrl = await manager.beginOAuth(created.id)
    const { code, state, issuer } = fake.approve(authorizationUrl)
    await manager.finishOAuth(state, code, issuer)

    expect(redirectOf(authorizationUrl)).toBe(`${loopback}/v1/mcps/oauth/callback`)
    expect(fake.registeredRedirects()).toEqual([`${loopback}/v1/mcps/oauth/callback`])
  })

  it("keeps a user's own OAuth client on the loopback callback they registered", async () => {
    const { manager, registered, loopback, create } = await relayedMachine()
    const created = await create({ oauthClientId: "users-client" })

    const authorizationUrl = await manager.beginOAuth(created.id)

    expect(redirectOf(authorizationUrl)).toBe(`${loopback}/v1/mcps/oauth/callback`)
    expect(registered).toEqual([])
  })
})
