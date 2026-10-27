import { Hono } from "hono"
import { bodyLimit } from "hono/body-limit"
import { z } from "zod"

import type { CloudEnv } from "./env.js"
import type { OAuthCallbackItem } from "./inbox-frames.js"
import { userHub } from "./location-hint.js"
import { requireMachine, type AuthenticatedMachine } from "./machine-auth.js"
import { oauthCallbackPage } from "./pages/oauth-callback.js"

export const OAUTH_FLOW_TTL_MS = 15 * 60 * 1000
export const OAUTH_CALLBACK_PATH = "/oauth/callback"

export const oauthRelayRoutes = new Hono<{ Bindings: CloudEnv }>()

oauthRelayRoutes.post(
  "/api/machine/oauth-flows",
  bodyLimit({ maxSize: 1_024 }),
  requireMachine,
  async (c) => {
    const body = FlowBody.safeParse(await c.req.json<unknown>().catch(() => undefined))
    if (!body.success) return c.json({ error: "invalid flow id" }, 400)

    const expiresAt = Date.now() + OAUTH_FLOW_TTL_MS
    const registered = await registerFlow(c.env.DB, body.data.flowId, c.var.machine, expiresAt)
    if (!registered) return c.json({ error: "flow id already in use" }, 409)

    return c.json({
      flowId: body.data.flowId,
      redirectUri: `${c.env.PUBLIC_BASE_URL}${OAUTH_CALLBACK_PATH}`,
      expiresAt: new Date(expiresAt).toISOString()
    })
  }
)

oauthRelayRoutes.get(OAUTH_CALLBACK_PATH, async (c) => {
  const callback = callbackFromQuery(c.req.query())
  if (callback === undefined) return oauthCallbackPage(c, "expired")

  const userId = await claimFlow(c.env.DB, callback, Date.now())
  if (userId === undefined) return oauthCallbackPage(c, "expired")

  const hub = userHub(c.env, userId, c.req.raw.cf)
  const delivery = await hub.deliverOAuthCallback(callback.deviceId, callback.item)
  return oauthCallbackPage(c, delivery, callback.item.error)
})

interface ParsedCallback {
  readonly deviceId: string
  readonly item: OAuthCallbackItem
}

const statePart = /^[A-Za-z0-9_-]{1,128}$/

const FlowBody = z.object({ flowId: z.string().regex(/^[A-Za-z0-9_-]{16,128}$/) })

const callbackFromQuery = (query: Record<string, string>): ParsedCallback | undefined => {
  const state = query["state"] ?? ""
  const parts = state.split(".")
  if (!isWellFormedState(parts)) return undefined

  const [flowId, deviceId] = parts
  return { deviceId, item: { flowId, state, ...optionalFields(query) } }
}

const isWellFormedState = (parts: string[]): parts is [string, string, string] =>
  parts.length === 3 && parts.every((part) => statePart.test(part))

const optionalFields = (
  query: Record<string, string>
): Pick<OAuthCallbackItem, "code" | "error"> => ({
  ...(query["code"] === undefined ? {} : { code: query["code"] }),
  ...(query["error"] === undefined ? {} : { error: query["error"] })
})

const registerFlow = async (
  db: D1Database,
  flowId: string,
  machine: AuthenticatedMachine,
  expiresAt: number
): Promise<boolean> => {
  const [, inserted] = await db.batch([
    db.prepare(flowSql.deleteExpired).bind(machine.userId, Date.now()),
    db.prepare(flowSql.insert).bind(flowId, machine.userId, machine.deviceId, expiresAt)
  ])
  return (inserted?.meta.changes ?? 0) > 0
}

const claimFlow = async (
  db: D1Database,
  callback: ParsedCallback,
  now: number
): Promise<string | undefined> => {
  const claim = db.prepare(flowSql.claim).bind(callback.item.flowId, callback.deviceId, now)
  const row = await claim.first<FlowOwnerRow>()
  return row?.user_id
}

interface FlowOwnerRow {
  user_id: string
}

const flowSql = {
  deleteExpired: "DELETE FROM oauth_flow WHERE user_id = ? AND expires_at <= ?",
  insert: `INSERT INTO oauth_flow (flow_id, user_id, device_id, expires_at) VALUES (?, ?, ?, ?)
     ON CONFLICT(flow_id) DO NOTHING`,
  claim: `DELETE FROM oauth_flow WHERE flow_id = ? AND device_id = ? AND expires_at > ?
     RETURNING user_id`
}
