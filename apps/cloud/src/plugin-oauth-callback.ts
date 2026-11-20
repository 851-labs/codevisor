import { Hono } from "hono"

import type { CloudEnv } from "./env.js"
import { PLUGIN_OAUTH_CALLBACK_PATH, relayOAuthCallback } from "./oauth-relay.js"

export const pluginOAuthCallback = new Hono<{ Bindings: CloudEnv }>()

pluginOAuthCallback.get(PLUGIN_OAUTH_CALLBACK_PATH, async (c) => {
  const relayed = await relayOAuthCallback(c)
  if (relayed !== undefined) return relayed

  const query = new URL(c.req.url).searchParams
  const scheme = appSchemeOf(query.get("state"))
  if (scheme === undefined) return c.html(unknownSignInPage, 400)

  c.header("Cache-Control", "no-store")
  c.header("Referrer-Policy", "no-referrer")
  return c.redirect(`${scheme}://${appCallbackHost}?${forwardedQuery(query).toString()}`, 302)
})

const appSchemeOf = (state: string | null): string | undefined =>
  statePattern.exec(state ?? "")?.groups?.["scheme"]

const forwardedQuery = (query: URLSearchParams): URLSearchParams =>
  new URLSearchParams(
    forwardedParams.flatMap((name) => {
      const value = query.get(name)
      return value === null ? [] : [[name, value]]
    })
  )

const statePattern = /^[\w-]{16,64}\.(?<scheme>codevisor(?:-dev(?:-[0-9a-f]{10})?)?)\.[\w-]{8,64}$/

const appCallbackHost = "plugin-oauth"

const forwardedParams = ["state", "code", "error", "error_description"]

const unknownSignInPage =
  "<!doctype html><title>Codevisor</title><p>This sign-in link didn't come from Codevisor. Start the sign-in again from the Codevisor app.</p>"
