import { readFileSync } from "node:fs"

import { describe, expect, it } from "vitest"

import { makeServices } from "../test-support.js"
import { settles } from "./mcp-connection-state-test-support.js"
import {
  type ClientMetadataDocument,
  fakeOAuthMcpServer,
  type FakeOAuthMcpOptions,
  listenOn,
  machineVault,
  manualOAuthClock,
  sharedCoordinator,
  tempDirectory
} from "./mcp-oauth-test-support.js"

const publishedDocument: ClientMetadataDocument = JSON.parse(
  readFileSync(new URL("../../../www/public/oauth/client-metadata.json", import.meta.url), "utf8")
)

const signIn = async (options: FakeOAuthMcpOptions) => {
  const clock = manualOAuthClock()
  const fake = await fakeOAuthMcpServer(clock, options)
  const vault = machineVault(sharedCoordinator(clock), "server-a", clock, await tempDirectory())
  const manager = (await makeServices("server-a", { oauthClock: clock, oauthVault: vault }))
    .services.mcp
  manager.setBaseUrl(await listenOn(manager.handleGatewayRequest))
  const created = await manager.create({
    authType: "oauth",
    enabled: true,
    name: "Store",
    transport: "http",
    url: fake.url
  })

  const authorizationUrl = await manager.beginOAuth(created.id)
  const { code, state } = fake.approve(authorizationUrl)
  await manager.finishOAuth(state, code)

  return {
    clientId: new URL(authorizationUrl).searchParams.get("client_id"),
    server: await settles(manager, created.id, "connected")
  }
}

describe("MCP OAuth with a client metadata document", () => {
  it("signs in with Codevisor's published client when the server has no registration", async () => {
    const signedIn = await signIn({
      clientMetadataDocuments: [publishedDocument],
      dynamicRegistration: false
    })

    expect(signedIn.clientId).toBe(publishedDocument.client_id)
    expect(signedIn.server).toMatchObject({ toolCount: 1 })
  })

  it("keeps registering its own client where the server offers both", async () => {
    const signedIn = await signIn({ clientMetadataDocuments: [publishedDocument] })

    expect(signedIn.clientId).not.toBe(publishedDocument.client_id)
    expect(signedIn.server).toMatchObject({ toolCount: 1 })
  })
})
