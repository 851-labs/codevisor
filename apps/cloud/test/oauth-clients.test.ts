import { createExecutionContext, env, waitOnExecutionContext } from "cloudflare:test"
import { describe, expect, it, vi } from "vitest"

import worker from "../src/index.js"
import { BASE, devLogin } from "./cloud-test-support.js"
import { machineIdentity } from "./inbox-test-support.js"
import { jsonRecord, readJson } from "./json-test-support.js"

const githubTokenUrl = "https://github.com/login/oauth/access_token"

const configured = (fetcher: (url: string, init?: RequestInit) => Promise<Response>) => ({
  ...env,
  MCP_GITHUB_CLIENT_ID: "github-client",
  MCP_GITHUB_CLIENT_SECRET: "github-secret",
  OAUTH_CLIENT_FETCH: fetcher
})

const call = async (
  bindings: typeof env,
  path: string,
  apiKey: string | undefined,
  body?: unknown
): Promise<Response> => {
  const ctx = createExecutionContext()
  const response = await worker.fetch(
    new Request(`${BASE}${path}`, {
      method: body === undefined ? "GET" : "POST",
      headers: { "content-type": "application/json", ...(apiKey ? { "x-api-key": apiKey } : {}) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) })
    }),
    bindings,
    ctx
  )
  await waitOnExecutionContext(ctx)
  return response
}

const codeForm = (clientId = "github-client", grant = "authorization_code") =>
  new URLSearchParams({
    grant_type: grant,
    code: "code-1",
    code_verifier: "verifier-1",
    redirect_uri: `${BASE}/oauth/callback`,
    client_id: clientId
  }).toString()

const machineKey = async (): Promise<string> => (await machineIdentity(await devLogin())).apiKey

describe("managed OAuth clients", () => {
  it("hands machines the client id, never the secret", async () => {
    const apiKey = await machineKey()
    const bindings = configured(vi.fn())

    const known = await call(bindings, "/api/machine/oauth-clients/github", apiKey)
    const unknown = await call(bindings, "/api/machine/oauth-clients/gitlab", apiKey)
    const anonymous = await call(bindings, "/api/machine/oauth-clients/github", undefined)
    const unset = await call(env, "/api/machine/oauth-clients/github", apiKey)

    expect(await readJson(known, jsonRecord)).toEqual({ clientId: "github-client" })
    expect([unknown.status, anonymous.status, unset.status]).toEqual([404, 401, 503])
  })

  it("adds the client secret to a machine's code exchange", async () => {
    const apiKey = await machineKey()
    const fetcher = vi.fn(async (_url: string, _init?: RequestInit) =>
      Response.json({ access_token: "gho_1", token_type: "bearer" })
    )

    const response = await call(
      configured(fetcher),
      "/api/machine/oauth-clients/github/token",
      apiKey,
      {
        tokenUrl: githubTokenUrl,
        form: codeForm()
      }
    )

    expect(await readJson(response, jsonRecord)).toEqual({
      access_token: "gho_1",
      token_type: "bearer"
    })
    const [url, init] = fetcher.mock.calls[0] ?? []
    const sent = typeof init?.body === "string" ? init.body : ""
    expect(url).toBe(githubTokenUrl)
    expect(Object.fromEntries(new URLSearchParams(sent))).toMatchObject({
      client_id: "github-client",
      client_secret: "github-secret",
      code: "code-1",
      code_verifier: "verifier-1"
    })
  })

  it("refuses exchanges for another client, grant or token endpoint", async () => {
    const apiKey = await machineKey()
    const fetcher = vi.fn(async () => Response.json({}))
    const bindings = configured(fetcher)
    const token = (body: unknown, name = "github") =>
      call(bindings, `/api/machine/oauth-clients/${name}/token`, apiKey, body)

    const statuses = [
      await token({ tokenUrl: "https://evil.example/token", form: codeForm() }),
      await token({ tokenUrl: githubTokenUrl, form: codeForm("someone-else") }),
      await token({ tokenUrl: githubTokenUrl, form: codeForm("github-client", "password") }),
      await token({ form: codeForm() }),
      await token({ tokenUrl: githubTokenUrl, form: codeForm() }, "gitlab"),
      await call(env, "/api/machine/oauth-clients/github/token", apiKey, {
        tokenUrl: githubTokenUrl,
        form: codeForm()
      })
    ].map((response) => response.status)

    expect(statuses).toEqual([400, 400, 400, 400, 404, 503])
    expect(fetcher).not.toHaveBeenCalled()
  })

  it("reports a token endpoint answer that isn't JSON as an invalid response", async () => {
    const apiKey = await machineKey()
    const fetcher = vi.fn(async () => new Response("<html>"))

    const response = await call(
      configured(fetcher),
      "/api/machine/oauth-clients/github/token",
      apiKey,
      {
        tokenUrl: githubTokenUrl,
        form: codeForm()
      }
    )

    expect(await readJson(response, jsonRecord)).toEqual({ error: "invalid_response" })
  })
})
