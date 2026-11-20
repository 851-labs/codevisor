import { toBase64Url } from "@codevisor/cloud-crypto"
import { type Context, Hono } from "hono"
import { bodyLimit } from "hono/body-limit"
import { z } from "zod"

import type { CloudEnv } from "./env.js"
import type { OAuthCallbackItem } from "./inbox-frames.js"
import { userHub } from "./location-hint.js"
import { requireMachine, type AuthenticatedMachine } from "./machine-auth.js"
import { nativeScheme } from "./pages/account.js"
import {
  alreadySignedInPage,
  oauthCallbackPage,
  type OAuthPageOptions
} from "./pages/oauth-callback.js"

export const OAUTH_FLOW_TTL_MS = 15 * 60 * 1000
export const OAUTH_CALLBACK_PATH = "/oauth/callback"
export const PLUGIN_OAUTH_CALLBACK_PATH = "/oauth/plugins/callback"
export const OAUTH_SIGNED_IN_PATH = "/oauth/signed-in"

export const oauthRelayRoutes = new Hono<{ Bindings: CloudEnv }>()

oauthRelayRoutes.post(
  "/api/machine/oauth-flows",
  bodyLimit({ maxSize: 8_192 }),
  requireMachine,
  async (c) => {
    const body = FlowBody.safeParse(await c.req.json<unknown>().catch(() => undefined))
    if (!body.success) return c.json({ error: "invalid oauth flow" }, 400)

    const redirectUri = servedRedirect(c.env.PUBLIC_BASE_URL, body.data.redirectUris)
    if (redirectUri === undefined) {
      return c.json({ error: "none of these redirect URIs reach this Cloud" }, 422)
    }
    const expiresAt = Date.now() + OAUTH_FLOW_TTL_MS
    const flow = registeredFlow(body.data, expiresAt)
    if (!(await registerFlow(c.env.DB, c.var.machine, flow))) {
      return c.json({ error: "flow id already in use" }, 409)
    }
    return c.json({ redirectUri, expiresAt: new Date(expiresAt).toISOString() })
  }
)

oauthRelayRoutes.get(OAUTH_CALLBACK_PATH, async (c) => {
  const relayed = await relayOAuthCallback(c)
  return relayed ?? oauthCallbackPage(c, { outcome: "expired" })
})

oauthRelayRoutes.get(OAUTH_SIGNED_IN_PATH, (c) =>
  alreadySignedInPage(c, nativeScheme(c.req.query("app")))
)

export const relayOAuthCallback = async (
  c: Context<{ Bindings: CloudEnv }>
): Promise<Response | undefined> => {
  const callback = callbackOf(new URL(c.req.url).searchParams)
  if (callback === undefined) return undefined

  const flow = await claimFlow(c.env.DB, await flowIdOf(callback.state), Date.now())
  if (flow === null) return undefined

  const hub = userHub(c.env, flow.user_id, c.req.raw.cf)
  const delivery = await hub.deliverOAuthCallback(flow.device_id, callback)
  return oauthCallbackPage(c, delivery, pageOptions(flow, callback))
}

export const flowIdOf = async (state: string): Promise<string> =>
  toBase64Url(
    new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(state)))
  )

interface RegisteredFlow {
  readonly flowId: string
  readonly app: string | null
  readonly opensApp: boolean
  readonly expiresAt: number
}

interface FlowOwnerRow {
  user_id: string
  device_id: string
  app: string | null
  opens_app: number
}

const FlowBody = z.object({
  flowId: z.string().regex(/^[A-Za-z0-9_-]{43}$/),
  app: z.string().max(40).optional(),
  opensApp: z.boolean().optional(),
  redirectUris: z.array(z.string().max(2_048)).max(10).optional()
})

const servedRedirect = (
  publicBaseUrl: string,
  candidates: ReadonlyArray<string> | undefined
): string | undefined => {
  const served = [OAUTH_CALLBACK_PATH, PLUGIN_OAUTH_CALLBACK_PATH].map(
    (path) => `${publicBaseUrl}${path}`
  )
  if (candidates === undefined) return served[0]

  return candidates.find((candidate) => served.includes(candidate))
}

const registeredFlow = (body: z.infer<typeof FlowBody>, expiresAt: number): RegisteredFlow => {
  const app = nativeScheme(body.app) ?? null
  return { flowId: body.flowId, app, opensApp: app !== null && body.opensApp === true, expiresAt }
}

const pageOptions = (flow: FlowOwnerRow, callback: OAuthCallbackItem): OAuthPageOptions => ({
  ...(flow.app === null ? {} : { app: flow.app, opensApp: flow.opens_app === 1 }),
  ...(callback.error === undefined ? {} : { error: callback.error })
})

const callbackParams = ["code", "iss", "error"] as const

const maxStateLength = 1_024

const callbackOf = (query: URLSearchParams): OAuthCallbackItem | undefined => {
  const state = query.get("state")
  if (state === null || state === "" || state.length > maxStateLength) return undefined

  return {
    state,
    ...Object.fromEntries(callbackParams.flatMap((name) => presentParam(query, name)))
  }
}

const presentParam = (query: URLSearchParams, name: string): Array<[string, string]> => {
  const value = query.get(name)
  return value === null ? [] : [[name, value]]
}

const registerFlow = async (
  db: D1Database,
  machine: AuthenticatedMachine,
  flow: RegisteredFlow
): Promise<boolean> => {
  const [, inserted] = await db.batch([
    db.prepare(flowSql.deleteExpired).bind(machine.userId, Date.now()),
    db
      .prepare(flowSql.insert)
      .bind(
        flow.flowId,
        machine.userId,
        machine.deviceId,
        flow.app,
        flow.opensApp ? 1 : 0,
        flow.expiresAt
      )
  ])
  return (inserted?.meta.changes ?? 0) > 0
}

const claimFlow = (db: D1Database, flowId: string, now: number): Promise<FlowOwnerRow | null> =>
  db.prepare(flowSql.claim).bind(flowId, now).first<FlowOwnerRow>()

const flowSql = {
  deleteExpired: "DELETE FROM oauth_flow WHERE user_id = ? AND expires_at <= ?",
  insert: `INSERT INTO oauth_flow (flow_id, user_id, device_id, app, opens_app, expires_at)
     VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(flow_id) DO NOTHING`,
  claim: `DELETE FROM oauth_flow WHERE flow_id = ? AND expires_at > ?
     RETURNING user_id, device_id, app, opens_app`
}
