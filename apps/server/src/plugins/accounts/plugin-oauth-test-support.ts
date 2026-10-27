import { createHash } from "node:crypto"
import type { IncomingMessage, ServerResponse } from "node:http"

import type { PluginOAuthSpec } from "@codevisor/api"
import { vi } from "vitest"

import { listenOn } from "../../infra/mcp-oauth-test-support.js"

export interface IssuedCode {
  readonly code: string
  readonly state: string
}

export interface ProviderOptions {
  readonly identity?: unknown
  readonly userinfoStatus?: number
  readonly scope?: string
  readonly refreshToken?: boolean
  readonly expiresIn?: number
}

export const fakeOAuthProvider = async (options: ProviderOptions = {}) => {
  const codes = new Map<
    string,
    { readonly challenge: string; readonly clientId: string; readonly redirectUri: string }
  >()
  const tokenForms: Array<Record<string, string>> = []
  let issued = 0

  const token = async (request: IncomingMessage, response: ServerResponse) => {
    const form = Object.fromEntries(new URLSearchParams(await bodyOf(request)))
    tokenForms.push(form)
    const grant = codes.get(form.code ?? "")
    codes.delete(form.code ?? "")
    if (grant === undefined || !grantMatches(grant, form))
      return json(response, 400, { error: "invalid_grant" })
    issued += 1
    json(response, 200, tokensFor(issued, options))
  }

  const userinfo = (request: IncomingMessage, response: ServerResponse) => {
    if (request.headers.authorization !== `Bearer access-${issued}`) return json(response, 401, {})
    json(response, options.userinfoStatus ?? 200, options.identity ?? { email: "dana@example.com" })
  }

  const url = await listenOn((request, response) => {
    if (request.url === "/token") void token(request, response)
    else userinfo(request, response)
  })

  return {
    url,
    tokenForms,
    spec: (overrides: Partial<PluginOAuthSpec> = {}): PluginOAuthSpec => ({
      provider: "example",
      authorizeUrl: `${url}/authorize`,
      tokenUrl: `${url}/token`,
      scopes: ["mail.read", "openid"],
      client: "byo",
      userinfoUrl: `${url}/userinfo`,
      ...overrides
    }),
    authorize: (authorizationUrl: string): IssuedCode => {
      const params = new URL(authorizationUrl).searchParams
      if (params.get("code_challenge_method") !== "S256") throw new Error("PKCE S256 is required")
      const code = `code-${codes.size + issued + 1}`
      codes.set(code, {
        challenge: params.get("code_challenge") ?? "",
        clientId: params.get("client_id") ?? "",
        redirectUri: params.get("redirect_uri") ?? ""
      })
      return { code, state: params.get("state") ?? "" }
    }
  }
}

export type FakeOAuthProvider = Awaited<ReturnType<typeof fakeOAuthProvider>>

const grantMatches = (
  grant: { readonly challenge: string; readonly clientId: string; readonly redirectUri: string },
  form: Record<string, string>
): boolean =>
  grant.clientId === form.client_id &&
  grant.redirectUri === form.redirect_uri &&
  grant.challenge ===
    createHash("sha256")
      .update(form.code_verifier ?? "")
      .digest("base64url")

const tokensFor = (issued: number, options: ProviderOptions) => ({
  access_token: `access-${issued}`,
  token_type: "Bearer",
  ...(options.refreshToken === false ? {} : { refresh_token: `refresh-${issued}` }),
  ...(options.expiresIn === undefined ? {} : { expires_in: options.expiresIn }),
  ...(options.scope === undefined ? {} : { scope: options.scope })
})

const bodyOf = async (request: IncomingMessage): Promise<string> => {
  const chunks: Array<Buffer> = []
  for await (const chunk of request) {
    if (Buffer.isBuffer(chunk)) chunks.push(chunk)
  }
  return Buffer.concat(chunks).toString("utf8")
}

const json = (response: ServerResponse, status: number, body: unknown): void => {
  response.writeHead(status, { "content-type": "application/json" })
  response.end(JSON.stringify(body))
}

export const routeGoogleTo = (providerUrl: string): void => {
  const passThrough = globalThis.fetch
  const google: Readonly<Record<string, string>> = {
    "https://oauth2.googleapis.com/token": `${providerUrl}/token`,
    "https://openidconnect.googleapis.com/v1/userinfo": `${providerUrl}/userinfo`
  }
  vi.stubGlobal("fetch", (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input instanceof Request ? input.url : input)
    return passThrough(google[url] ?? input, init)
  })
}
