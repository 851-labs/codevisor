import type { IncomingMessage, ServerResponse } from "node:http"

import { describe, expect, it } from "vitest"

import { start } from "../test-support.js"
import { listenOn } from "./mcp-oauth-test-support.js"

const json = (response: ServerResponse, body: unknown): void => {
  response.writeHead(200, { "content-type": "application/json" })
  response.end(JSON.stringify(body))
}

const provider = async (offersOAuth: boolean) => {
  const requests: Array<string> = []
  const url: string = await listenOn((request: IncomingMessage, response: ServerResponse) => {
    const path = request.url ?? ""
    requests.push(`${request.method} ${path}`)
    if (offersOAuth && path.startsWith("/.well-known/oauth-protected-resource")) {
      return json(response, { resource: `${url}/mcp`, authorization_servers: [url] })
    }
    if (offersOAuth && path === "/.well-known/oauth-authorization-server") {
      return json(response, {
        issuer: url,
        authorization_endpoint: `${url}/authorize`,
        token_endpoint: `${url}/token`,
        registration_endpoint: `${url}/register`,
        response_types_supported: ["code"],
        code_challenge_methods_supported: ["S256"]
      })
    }
    if (path === "/register") {
      return json(response, { client_id: "client-1", redirect_uris: [] })
    }
    response.writeHead(404)
    response.end()
  })
  return { url, requests }
}

describe("preparing an MCP sign-in before the plugin is installed", () => {
  it("reuses what it learned about the provider when sign-in starts", async () => {
    const { server, services } = await start()
    const acme = await provider(true)

    const offered = await services.mcp.prepareOAuth(`${acme.url}/mcp`)
    const learned = acme.requests.length
    const created = await services.mcp.create({
      authType: "oauth",
      enabled: false,
      name: "Acme",
      transport: "http",
      url: `${acme.url}/mcp`
    })
    const authorizationUrl = await services.mcp.beginOAuth(created.id, {
      redirectBaseUrl: server.url
    })

    expect(offered).toBe(true)
    expect(acme.requests.slice(learned)).toEqual(["POST /register"])
    expect(authorizationUrl).toContain(`${acme.url}/authorize?`)
  })

  it("reports no sign-in for a server that doesn't describe one", async () => {
    const { services } = await start()
    const open = await provider(false)

    expect(await services.mcp.prepareOAuth(`${open.url}/mcp`)).toBe(false)
  })
})
