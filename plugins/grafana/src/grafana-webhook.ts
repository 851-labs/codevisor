import { createHash, timingSafeEqual } from "node:crypto"

import type { EventOccurrence, WebhookParams } from "@codevisor/plugin-kit"
import { z } from "zod"

import type { GrafanaAccount } from "./grafana-account.js"
import { alertFiringEvent, alertResolvedEvent, alertsIngress } from "./grafana-catalog.js"

export interface WebhookOutcome {
  accepted: number
  status: number
  occurrences: ReadonlyArray<EventOccurrence>
}

export const receiveAlertWebhook = (
  params: WebhookParams,
  account: GrafanaAccount | undefined
): WebhookOutcome => {
  if (params.ingress !== alertsIngress) return rejected(404)
  if (!authorized(params.request.headers, account?.webhookSecret)) return rejected(401)

  const notification = grafanaNotification.safeParse(decodedJson(params.request.body))
  if (!notification.success) return rejected(400)

  const occurrences = notification.data.alerts.flatMap(alertOccurrence)
  return { accepted: occurrences.length, status: 200, occurrences }
}

const rejected = (status: number): WebhookOutcome => ({ accepted: 0, status, occurrences: [] })

const authorized = (headers: Record<string, string>, secret: string | undefined): boolean => {
  if (secret === undefined) return false

  return constantTimeEqual(headerValue(headers, "authorization"), `Bearer ${secret}`)
}

const headerValue = (headers: Record<string, string>, name: string): string =>
  Object.entries(headers).find(([key]) => key.toLowerCase() === name)?.[1] ?? ""

const constantTimeEqual = (actual: string, expected: string): boolean =>
  timingSafeEqual(sha256(actual), sha256(expected))

const sha256 = (value: string): Buffer => createHash("sha256").update(value, "utf8").digest()

const decodedJson = (base64: string): unknown => {
  try {
    return JSON.parse(Buffer.from(base64, "base64").toString("utf8"))
  } catch {
    return undefined
  }
}

type GrafanaAlert = z.infer<typeof grafanaAlert>

const alertOccurrence = (alert: GrafanaAlert): ReadonlyArray<EventOccurrence> => {
  const name = eventNames[alert.status]
  if (name === undefined) return []

  return [
    {
      eventId: `${alert.fingerprint}:${alert.startsAt}`,
      name,
      timestamp: alert.status === "resolved" ? alert.endsAt : alert.startsAt,
      data: alertPayload(alert),
      cursor: null
    }
  ]
}

const eventNames: Record<string, string> = {
  firing: alertFiringEvent,
  resolved: alertResolvedEvent
}

const alertPayload = (alert: GrafanaAlert): Record<string, unknown> => ({
  fingerprint: alert.fingerprint,
  status: alert.status,
  alertname: alert.labels["alertname"] ?? "",
  labels: alert.labels,
  annotations: alert.annotations,
  startsAt: alert.startsAt,
  endsAt: alert.endsAt,
  generatorURL: alert.generatorURL,
  values: alert.values ?? {}
})

const stringMap = z.record(z.string(), z.string())

const grafanaAlert = z.object({
  status: z.string(),
  labels: stringMap.default({}),
  annotations: stringMap.default({}),
  fingerprint: z.string().min(1),
  startsAt: z.string(),
  endsAt: z.string().default(""),
  generatorURL: z.string().default(""),
  values: z.record(z.string(), z.number()).nullish()
})

const grafanaNotification = z.object({ alerts: z.array(grafanaAlert) })
