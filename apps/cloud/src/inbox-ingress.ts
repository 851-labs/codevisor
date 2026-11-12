import { Hono } from "hono"
import { bodyLimit } from "hono/body-limit"

import type { CloudEnv } from "./env.js"
import type { IngestOutcome } from "./hub-inbox.js"
import type { InboxRequest } from "./inbox-frames.js"
import { hooksBaseUrl, INBOXES_OFF, inboxOwner } from "./inbox-store.js"
import { userHub } from "./location-hint.js"

export const INBOX_BODY_LIMIT = 256 * 1024
export const INBOX_RETRY_AFTER_SECONDS = 60

export const inboxIngress = new Hono<{ Bindings: CloudEnv }>()

inboxIngress.on(
  "POST",
  ["/i/:id", "/hooks/i/:id"],
  bodyLimit({ maxSize: INBOX_BODY_LIMIT }),
  async (c) => {
    if (hooksBaseUrl(c.env) === undefined) return c.json({ error: INBOXES_OFF }, 503)

    const inboxId = c.req.param("id")
    const userId = await inboxOwner(c.env.DB, inboxId)
    if (userId === undefined) return c.json({ error: "not found" }, 404)

    const bytes = await c.req.raw.arrayBuffer()
    const challenge = urlVerificationChallenge(bytes)
    if (challenge !== undefined) return c.json({ challenge })

    const request = inboxRequest(c.req.raw, bytes)
    const outcome = await userHub(c.env, userId, c.req.raw.cf).ingestInbox(inboxId, request)
    return ingestResponses[outcome]()
  }
)

export const webhookReceiverDocument = { receivers: ["/i/", "/hooks/i/"] }

inboxIngress.get("/.well-known/mcp-webhook-receiver.json", (c) =>
  c.json(webhookReceiverDocument, 200, { "cache-control": "public, max-age=3600" })
)

const droppedHeaders = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "proxy-connection",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
  "cookie"
])

const inboxRequest = (request: Request, bytes: ArrayBuffer): InboxRequest => ({
  method: request.method,
  headers: forwardedHeaders(request.headers),
  body: Buffer.from(bytes).toString("base64"),
  receivedAt: new Date().toISOString()
})

const urlVerificationChallenge = (bytes: ArrayBuffer): string | undefined => {
  if (bytes.byteLength > maxChallengeBytes) return undefined

  const body = parsedJson(new TextDecoder().decode(bytes))
  if (!isRecord(body) || body.type !== "url_verification") return undefined
  return typeof body.challenge === "string" ? body.challenge : undefined
}

const maxChallengeBytes = 1024

const parsedJson = (text: string): unknown => {
  try {
    return JSON.parse(text)
  } catch {
    return undefined
  }
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

const forwardedHeaders = (headers: Headers): Record<string, string> =>
  Object.fromEntries([...headers].filter(([name]) => !droppedHeaders.has(name)))

const retryLater = (error: string, status: number): Response =>
  Response.json(
    { error },
    { status, headers: { "retry-after": String(INBOX_RETRY_AFTER_SECONDS) } }
  )

const ingestResponses: Record<IngestOutcome, () => Response> = {
  accepted: () => new Response(null, { status: 202 }),
  "rate-limited": () => retryLater("rate limited", 429),
  full: () => retryLater("inbox queue full", 503)
}
