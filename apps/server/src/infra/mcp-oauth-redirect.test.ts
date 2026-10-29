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

const relayCallback = "https://cloud.example/oauth/callback"
const relayed = async () => ({ redirectUrl: relayCallback, state: "relayed-state" })

const oauthServer = {
  authType: "oauth",
  enabled: true,
  name: "Tracker",
  transport: "http"
} as const

describe("MCP OAuth redirects", () => {
  it("signs in through the machine's own callback when the provider refuses the relay callback", async () => {
    const clock = manualOAuthClock()
    const fake = await fakeOAuthMcpServer(clock, 3600, (uri) => uri !== relayCallback)
    const { services } = await makeServices("machine-a", {
      oauthClock: clock,
      oauthVault: machineVault(sharedCoordinator(clock), "machine-a", clock, await tempDirectory()),
      oauthRedirect: relayed
    })
    const base = await listenOn(services.mcp.handleGatewayRequest)
    const loopbackCallback = new URL("/v1/mcps/oauth/callback", base).toString()
    const created = await services.mcp.create({ ...oauthServer, url: fake.url })

    const authorizationUrl = await services.mcp.beginOAuth(created.id, base)

    expect(new URL(authorizationUrl).searchParams.get("redirect_uri")).toBe(loopbackCallback)
    expect(fake.registeredRedirects()).toEqual([loopbackCallback])
    const { code, state } = fake.approve(authorizationUrl)
    expect((await services.mcp.finishOAuth(state, code)).id).toBe(created.id)
  })

  it("keeps the relay callback when the provider accepts it", async () => {
    const clock = manualOAuthClock()
    const fake = await fakeOAuthMcpServer(clock)
    const { services } = await makeServices("machine-a", {
      oauthClock: clock,
      oauthRedirect: relayed
    })
    const created = await services.mcp.create({ ...oauthServer, url: fake.url })

    const authorizationUrl = new URL(await services.mcp.beginOAuth(created.id))

    expect(authorizationUrl.searchParams.get("redirect_uri")).toBe(relayCallback)
    expect(authorizationUrl.searchParams.get("state")).toBe("relayed-state")
  })
})
