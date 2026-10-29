import { describe, expect, it, vi } from "vitest"

import { managedOAuthOf, managedTokenFetch, type ManagedOAuthClients } from "./mcp-managed-oauth.js"

const catalog = {
  launch: () => undefined,
  oauthClient: (catalogId: string) => (catalogId === "com.github/mcp" ? "github" : undefined)
}

const clients = (): ManagedOAuthClients & {
  readonly exchanges: Array<unknown>
} => {
  const exchanges: Array<unknown> = []
  return {
    exchanges,
    clientId: async () => "github-client",
    exchange: async (client, tokenUrl, form) => {
      exchanges.push({ client, tokenUrl, form: Object.fromEntries(new URLSearchParams(form)) })
      return { access_token: "gho_1", token_type: "bearer" }
    }
  }
}

describe("managed OAuth clients", () => {
  it("applies only to catalog plugins whose entry names a managed client", () => {
    const managed = clients()
    const github = { name: "GitHub", catalogId: "com.github/mcp" }

    expect(managedOAuthOf(catalog, managed, github)).toEqual({ client: "github", clients: managed })
    expect(
      managedOAuthOf(catalog, managed, { name: "Linear", catalogId: "app.linear/linear" })
    ).toBeUndefined()
    expect(
      managedOAuthOf(catalog, managed, { name: "Custom", catalogId: undefined })
    ).toBeUndefined()
    expect(managedOAuthOf({ launch: () => undefined }, managed, github)).toBeUndefined()
    expect(() => managedOAuthOf(catalog, undefined, github)).toThrow(
      "GitHub needs Codevisor Cloud to sign in"
    )
  })

  it("sends token requests through the managed client and everything else straight out", async () => {
    const managed = clients()
    const base = vi.fn(async () => Response.json({ issuer: "https://github.com/login/oauth" }))
    const fetchFn = managedTokenFetch({ client: "github", clients: managed }, base)
    const form = new URLSearchParams({ grant_type: "authorization_code", code: "code-1" })

    const token = await fetchFn("https://github.com/login/oauth/access_token", {
      method: "POST",
      body: form
    })
    const empty = await fetchFn("https://github.com/login/oauth/access_token", {
      method: "POST",
      body: "raw"
    })
    const metadata = await fetchFn("https://github.com/.well-known/oauth-authorization-server")

    expect(await token.json()).toEqual({ access_token: "gho_1", token_type: "bearer" })
    expect(await empty.json()).toEqual({ access_token: "gho_1", token_type: "bearer" })
    expect(managed.exchanges).toEqual([
      {
        client: "github",
        tokenUrl: "https://github.com/login/oauth/access_token",
        form: { grant_type: "authorization_code", code: "code-1" }
      },
      {
        client: "github",
        tokenUrl: "https://github.com/login/oauth/access_token",
        form: {}
      }
    ])
    expect(await metadata.json()).toEqual({ issuer: "https://github.com/login/oauth" })
    expect(base).toHaveBeenCalledOnce()
  })
})
