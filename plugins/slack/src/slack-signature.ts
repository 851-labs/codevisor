import { createHmac, timingSafeEqual } from "node:crypto"

import type { WebhookParams } from "@codevisor/plugin-kit"

export const maxRequestAgeSeconds = 5 * 60

export const verifiedSlackBody = (
  signingSecret: string,
  request: WebhookParams["request"]
): string | undefined => {
  const timestamp = Number(header(request.headers, "x-slack-request-timestamp"))
  const signature = header(request.headers, "x-slack-signature")
  if (signature === undefined || !freshAt(timestamp, request.receivedAt)) return undefined

  const body = Buffer.from(request.body, "base64").toString("utf8")
  return sameSignature(signature, slackSignature(signingSecret, timestamp, body)) ? body : undefined
}

export const slackSignature = (signingSecret: string, timestamp: number, body: string): string =>
  `v0=${createHmac("sha256", signingSecret).update(`v0:${timestamp}:${body}`).digest("hex")}`

const header = (headers: Record<string, string>, name: string): string | undefined =>
  Object.entries(headers).find(([key]) => key.toLowerCase() === name)?.[1]

const freshAt = (timestamp: number, receivedAt: string): boolean => {
  const received = Date.parse(receivedAt) / millisecondsPerSecond
  return Number.isFinite(timestamp) && Math.abs(received - timestamp) <= maxRequestAgeSeconds
}

const millisecondsPerSecond = 1000

const sameSignature = (given: string, expected: string): boolean => {
  const left = Buffer.from(given)
  const right = Buffer.from(expected)
  return left.length === right.length && timingSafeEqual(left, right)
}
