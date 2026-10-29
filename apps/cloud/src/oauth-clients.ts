import { Hono } from "hono"
import { bodyLimit } from "hono/body-limit"
import { z } from "zod"

import type { CloudEnv } from "./env.js"
import { requireMachine } from "./machine-auth.js"

export const oauthClientRoutes = new Hono<{ Bindings: CloudEnv }>()

oauthClientRoutes.get("/api/machine/oauth-clients/:name", requireMachine, (c) => {
  const client = managedClient(c.env, c.req.param("name"))
  if (client === undefined) return c.json({ error: "unknown OAuth client" }, 404)
  if (!isConfigured(client)) return c.json({ error: "OAuth client isn't configured" }, 503)

  return c.json({ clientId: client.clientId })
})

oauthClientRoutes.post(
  "/api/machine/oauth-clients/:name/token",
  bodyLimit({ maxSize: 8_192 }),
  requireMachine,
  async (c) => {
    const client = managedClient(c.env, c.req.param("name"))
    if (client === undefined) return c.json({ error: "unknown OAuth client" }, 404)
    if (!isConfigured(client)) return c.json({ error: "OAuth client isn't configured" }, 503)

    const body = TokenBody.safeParse(await c.req.json<unknown>().catch(() => undefined))
    if (!body.success || body.data.tokenUrl !== client.tokenUrl) {
      return c.json({ error: "invalid token request" }, 400)
    }
    const form = new URLSearchParams(body.data.form)
    if (!isTokenGrant(form, client.clientId)) return c.json({ error: "invalid token request" }, 400)

    return c.json(await exchange(c.env, client, form))
  }
)

interface ManagedClient {
  readonly clientId: string | undefined
  readonly clientSecret: string | undefined
  readonly tokenUrl: string
}

interface ConfiguredClient extends ManagedClient {
  readonly clientId: string
  readonly clientSecret: string
}

const TokenBody = z.object({ tokenUrl: z.string(), form: z.string() })

const tokenGrants = new Set(["authorization_code", "refresh_token"])

const managedClient = (env: CloudEnv, name: string): ManagedClient | undefined => {
  if (name !== "github") return undefined
  return {
    clientId: env.MCP_GITHUB_CLIENT_ID,
    clientSecret: env.MCP_GITHUB_CLIENT_SECRET,
    tokenUrl: "https://github.com/login/oauth/access_token"
  }
}

const isConfigured = (client: ManagedClient): client is ConfiguredClient =>
  Boolean(client.clientId) && Boolean(client.clientSecret)

const isTokenGrant = (form: URLSearchParams, clientId: string): boolean =>
  tokenGrants.has(form.get("grant_type") ?? "") && form.get("client_id") === clientId

const exchange = async (
  env: CloudEnv,
  client: ConfiguredClient,
  form: URLSearchParams
): Promise<unknown> => {
  form.set("client_secret", client.clientSecret)
  const response = await (env.OAUTH_CLIENT_FETCH ?? fetch)(client.tokenUrl, {
    method: "POST",
    headers: { accept: "application/json", "content-type": "application/x-www-form-urlencoded" },
    body: form.toString()
  })
  return response.json().catch(() => ({ error: "invalid_response" }))
}
