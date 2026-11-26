import { Hono } from "hono"
import { bodyLimit } from "hono/body-limit"
import { z } from "zod"

import type { CloudEnv } from "./env.js"
import {
  forgetSentryInstallation,
  recordSentryInstallation,
  sentryInstallationOrganization
} from "./sentry-installations.js"
import { relayPing, signedWithHmac } from "./webhook-relay.js"

export interface SentryPing {
  readonly organizationId: string
  readonly resource: "issue" | "comment" | "event_alert" | "metric_alert"
  readonly action: string
  readonly issueId?: string
  readonly substatus?: string
  readonly commentId?: string
  readonly eventId?: string
  readonly alert?: SentryAlertPing
  readonly timestamp: string
}

export interface SentryAlertPing {
  readonly rule: string
  readonly status: string
  readonly incidentId?: string
}

export const SENTRY_PUSH_BODY_LIMIT = 1024 * 1024
export const SENTRY_WEBHOOK_MAX_SKEW_MS = 5 * 60_000

export const sentryPush = new Hono<{ Bindings: CloudEnv }>()

sentryPush.on(
  "POST",
  ["/push/sentry", "/hooks/push/sentry"],
  bodyLimit({ maxSize: SENTRY_PUSH_BODY_LIMIT }),
  async (c) => {
    const secret = c.env.SENTRY_WEBHOOK_SECRET
    if (!secret) return c.json({ error: "not found" }, 404)

    const raw = await c.req.text()
    if (!(await signedWithHmac(secret, raw, c.req.header("sentry-hook-signature"))))
      return c.json({ error: "unauthorized" }, 401)
    if (!fresh(c.req.header("sentry-hook-timestamp"), Date.now()))
      return c.json({ error: "stale" }, 401)

    const delivery = deliveryOf(raw)
    const resource = c.req.header("sentry-hook-resource") ?? ""
    if (delivery === undefined) return new Response(null, { status: 200 })

    await handleDelivery(c.env, resource, delivery, c.req.raw.cf)
    return new Response(null, { status: 200 })
  }
)

const handleDelivery = async (
  env: CloudEnv,
  resource: string,
  delivery: SentryDelivery,
  cf: Request["cf"]
): Promise<void> => {
  if (resource === "installation") return trackInstallation(env.DB, delivery)

  const organizationId = await sentryInstallationOrganization(env.DB, delivery.installation.uuid)
  if (organizationId === undefined) return

  const ping = pingOf(resource, delivery, organizationId)
  if (ping !== undefined) await relayPing(env, "sentry", organizationId, ping, cf)
}

const trackInstallation = async (db: D1Database, delivery: SentryDelivery): Promise<void> => {
  const installation = InstallationData.safeParse(delivery.data.installation).data
  if (installation === undefined) return
  if (delivery.action === "deleted") return forgetSentryInstallation(db, installation.uuid)
  if (delivery.action !== "created") return

  await recordSentryInstallation(db, installation.uuid, installation.organization.id)
}

const pingOf = (
  resource: string,
  delivery: SentryDelivery,
  organizationId: string
): SentryPing | undefined => {
  const relayed = relayedResources[resource]?.(delivery)
  if (relayed === undefined) return undefined

  return { organizationId, action: delivery.action, ...relayed }
}

type RelayedPart = Omit<SentryPing, "organizationId" | "action">

const issuePing = (delivery: SentryDelivery): RelayedPart | undefined => {
  if (!relayedIssueActions.has(delivery.action)) return undefined

  const issue = IssueData.safeParse(delivery.data.issue).data
  if (issue === undefined) return undefined

  return {
    resource: "issue",
    issueId: issue.id,
    ...(issue.substatus === undefined || issue.substatus === null
      ? {}
      : { substatus: issue.substatus }),
    timestamp: new Date().toISOString()
  }
}

const commentPing = (delivery: SentryDelivery): RelayedPart | undefined => {
  if (delivery.action !== "created") return undefined

  const comment = CommentData.safeParse(delivery.data).data
  if (comment === undefined) return undefined

  return {
    resource: "comment",
    issueId: comment.issue_id,
    commentId: comment.comment_id,
    timestamp: comment.timestamp
  }
}

const eventAlertPing = (delivery: SentryDelivery): RelayedPart | undefined => {
  const alert = EventAlertData.safeParse(delivery.data).data
  if (alert === undefined) return undefined

  return {
    resource: "event_alert",
    issueId: alert.event.issue_id,
    eventId: alert.event.event_id,
    alert: { rule: alert.triggered_rule, status: "triggered" },
    timestamp: new Date().toISOString()
  }
}

const metricAlertPing = (delivery: SentryDelivery): RelayedPart | undefined => {
  const alert = MetricAlertData.safeParse(delivery.data).data
  if (alert === undefined) return undefined

  return {
    resource: "metric_alert",
    alert: {
      rule: alert.metric_alert.alert_rule.name,
      status: delivery.action,
      incidentId: alert.metric_alert.identifier
    },
    timestamp: new Date().toISOString()
  }
}

const relayedResources: Readonly<
  Record<string, (delivery: SentryDelivery) => RelayedPart | undefined>
> = {
  issue: issuePing,
  comment: commentPing,
  event_alert: eventAlertPing,
  metric_alert: metricAlertPing
}

const relayedIssueActions = new Set(["created", "assigned", "unresolved"])

const fresh = (timestamp: string | undefined, now: number): boolean => {
  const sentAt = Number(timestamp) * 1000
  return Number.isFinite(sentAt) && Math.abs(now - sentAt) <= SENTRY_WEBHOOK_MAX_SKEW_MS
}

const deliveryOf = (raw: string): SentryDelivery | undefined => {
  try {
    return SentryDelivery.safeParse(JSON.parse(raw)).data
  } catch {
    return undefined
  }
}

const sentryId = z.union([z.string().min(1).max(100), z.number().int()]).transform(String)
const shortText = z.string().max(256)

const SentryDelivery = z.object({
  action: shortText,
  installation: z.object({ uuid: z.string().min(1).max(100) }),
  data: z.record(z.string(), z.unknown())
})

type SentryDelivery = z.infer<typeof SentryDelivery>

const InstallationData = z.object({
  uuid: z.string().min(1).max(100),
  organization: z.object({ id: sentryId })
})

const IssueData = z.object({ id: sentryId, substatus: shortText.nullish() })

const CommentData = z.object({
  issue_id: sentryId,
  comment_id: sentryId,
  timestamp: z.string().max(64)
})

const EventAlertData = z.object({
  event: z.object({ issue_id: sentryId, event_id: z.string().min(1).max(100) }),
  triggered_rule: shortText
})

const MetricAlertData = z.object({
  metric_alert: z.object({
    identifier: sentryId,
    alert_rule: z.object({ name: shortText })
  })
})
