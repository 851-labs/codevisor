import type { CloudEnv } from "./env.js"
import type { InboxRequest } from "./inbox-frames.js"
import { routedInboxes } from "./inbox-store.js"
import { userHub } from "./location-hint.js"

export const routeKeyOf = async (value: string): Promise<string> => {
  const bytes = new TextEncoder().encode(value.trim().toLowerCase())
  return hex(new Uint8Array(await crypto.subtle.digest("SHA-256", bytes)))
}

export const hmacSha256Hex = async (secret: string, body: string): Promise<string> => {
  const key = await hmacKey(secret, ["sign"])
  return hex(new Uint8Array(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body))))
}

export const signedWithHmac = async (
  secret: string,
  body: string,
  signature: string | undefined
): Promise<boolean> => {
  const bytes = hexBytes(signature ?? "")
  if (bytes === undefined) return false

  const key = await hmacKey(secret, ["verify"])
  return crypto.subtle.verify("HMAC", key, bytes, new TextEncoder().encode(body))
}

export const relayPing = async (
  env: CloudEnv,
  route: string,
  routedBy: string,
  ping: unknown,
  cf: Request["cf"]
): Promise<void> => {
  const targets = await routedInboxes(env.DB, route, await routeKeyOf(routedBy))
  const request = pingRequest(ping)
  await Promise.all(
    targets.map((target) => userHub(env, target.userId, cf).ingestInbox(target.id, request))
  )
}

const pingRequest = (ping: unknown): InboxRequest => ({
  method: "POST",
  headers: { "content-type": "application/json" },
  body: Buffer.from(JSON.stringify(ping), "utf8").toString("base64"),
  receivedAt: new Date().toISOString()
})

const hmacKey = (secret: string, usages: Array<"sign" | "verify">): Promise<CryptoKey> =>
  crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    usages
  )

const hex = (bytes: Uint8Array): string =>
  [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("")

const hexBytes = (text: string): Uint8Array | undefined => {
  if (!/^[0-9a-f]{64}$/i.test(text)) return undefined

  return Uint8Array.from(text.match(/../g) ?? [], (pair) => Number.parseInt(pair, 16))
}
