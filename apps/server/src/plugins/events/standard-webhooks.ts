import { createHmac, randomBytes, timingSafeEqual } from "node:crypto"

export interface SignedDelivery {
  readonly headers: Readonly<Record<string, string>>
  readonly body: string
}

export const maxWebhookAgeSeconds = 5 * 60

export const newWebhookSecret = (): string => `whsec_${randomBytes(32).toString("base64")}`

export const signWebhook = (secret: string, id: string, timestamp: number, body: string): string =>
  `v1,${hmac(secret, `${id}.${timestamp}.${body}`)}`

export const verifyWebhook = (
  secret: string,
  delivery: SignedDelivery,
  nowSeconds: number
): boolean => {
  const id = header(delivery.headers, "webhook-id")
  const timestamp = Number(header(delivery.headers, "webhook-timestamp"))
  const signatures = header(delivery.headers, "webhook-signature")
  if (id === undefined || signatures === undefined || !Number.isFinite(timestamp)) return false
  if (Math.abs(nowSeconds - timestamp) > maxWebhookAgeSeconds) return false

  const expected = Buffer.from(signWebhook(secret, id, timestamp, delivery.body))
  return signatures.split(" ").some((candidate) => sameBytes(Buffer.from(candidate), expected))
}

export const webhookHeader = (
  headers: Readonly<Record<string, string>>,
  name: string
): string | undefined => header(headers, name)

const hmac = (secret: string, payload: string): string =>
  createHmac("sha256", Buffer.from(secret.slice("whsec_".length), "base64"))
    .update(payload, "utf8")
    .digest("base64")

const header = (headers: Readonly<Record<string, string>>, name: string): string | undefined =>
  Object.entries(headers).find(([key]) => key.toLowerCase() === name)?.[1]

const sameBytes = (left: Buffer, right: Buffer): boolean =>
  left.length === right.length && timingSafeEqual(left, right)
