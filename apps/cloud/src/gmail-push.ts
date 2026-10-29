import { Hono } from "hono"
import { bodyLimit } from "hono/body-limit"
import { createRemoteJWKSet, jwtVerify } from "jose"
import { z } from "zod"

import type { CloudEnv } from "./env.js"
import type { InboxRequest } from "./inbox-frames.js"
import { routedInboxes } from "./inbox-store.js"
import { userHub } from "./location-hint.js"

export interface GmailPushSettings {
  readonly audience: string
  readonly serviceAccount: string
}

export interface GmailNotification {
  readonly emailAddress: string
  readonly historyId: string
}

export const GMAIL_PUSH_BODY_LIMIT = 16 * 1024
export const googleIssuers = ["https://accounts.google.com", "accounts.google.com"]
export const googleCertsUrl = "https://www.googleapis.com/oauth2/v3/certs"

export const gmailPush = new Hono<{ Bindings: CloudEnv }>()

gmailPush.on(
  "POST",
  ["/push/gmail", "/hooks/push/gmail"],
  bodyLimit({ maxSize: GMAIL_PUSH_BODY_LIMIT }),
  async (c) => {
    const settings = gmailPushSettings(c.env)
    if (settings === undefined) return c.json({ error: "not found" }, 404)
    if (!(await fromGooglePush(c.req.header("authorization"), settings)))
      return c.json({ error: "unauthorized" }, 401)

    const notification = gmailNotificationOf(await c.req.json<unknown>().catch(() => undefined))
    if (notification === undefined) return new Response(null, { status: 204 })

    await relay(c.env, notification, c.req.raw.cf)
    return new Response(null, { status: 204 })
  }
)

export const gmailPushSettings = (env: CloudEnv): GmailPushSettings | undefined => {
  if (!env.GMAIL_PUSH_AUDIENCE || !env.GMAIL_PUSH_SERVICE_ACCOUNT) return undefined

  return { audience: env.GMAIL_PUSH_AUDIENCE, serviceAccount: env.GMAIL_PUSH_SERVICE_ACCOUNT }
}

export const gmailRouteKey = async (emailAddress: string): Promise<string> => {
  const bytes = new TextEncoder().encode(emailAddress.trim().toLowerCase())
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes))
  return [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("")
}

const googleKeys = createRemoteJWKSet(new URL(googleCertsUrl))

const fromGooglePush = async (
  authorization: string | undefined,
  settings: GmailPushSettings
): Promise<boolean> => {
  const token = bearerToken(authorization)
  if (token === undefined) return false

  const verified = await jwtVerify(token, googleKeys, {
    issuer: googleIssuers,
    audience: settings.audience,
    algorithms: ["RS256"],
    requiredClaims: ["email", "exp", "iat"]
  }).catch(() => undefined)
  return verified !== undefined && sentBy(verified.payload, settings.serviceAccount)
}

const bearerToken = (authorization: string | undefined): string | undefined => {
  const match = /^Bearer (\S+)$/.exec(authorization ?? "")
  return match?.[1]
}

const sentBy = (payload: Record<string, unknown>, serviceAccount: string): boolean =>
  payload.email === serviceAccount && payload.email_verified === true

const gmailNotificationOf = (body: unknown): GmailNotification | undefined => {
  const envelope = PushEnvelope.safeParse(body)
  if (!envelope.success) return undefined

  const data = GmailData.safeParse(decodedJson(envelope.data.message.data))
  if (!data.success) return undefined

  return { emailAddress: data.data.emailAddress, historyId: String(data.data.historyId) }
}

const relay = async (
  env: CloudEnv,
  notification: GmailNotification,
  cf: Request["cf"]
): Promise<void> => {
  const targets = await routedInboxes(
    env.DB,
    "gmail",
    await gmailRouteKey(notification.emailAddress)
  )
  const request = pingRequest(notification)
  await Promise.all(
    targets.map((target) => userHub(env, target.userId, cf).ingestInbox(target.id, request))
  )
}

const pingRequest = (notification: GmailNotification): InboxRequest => ({
  method: "POST",
  headers: { "content-type": "application/json" },
  body: Buffer.from(JSON.stringify(notification), "utf8").toString("base64"),
  receivedAt: new Date().toISOString()
})

const decodedJson = (base64: string): unknown => {
  try {
    return JSON.parse(Buffer.from(base64, "base64").toString("utf8"))
  } catch {
    return undefined
  }
}

const PushEnvelope = z.object({ message: z.object({ data: z.string() }) })

const GmailData = z.object({
  emailAddress: z.string().min(1).max(320),
  historyId: z.union([z.string().regex(/^\d{1,20}$/), z.number().int().nonnegative()])
})
