import { Hono } from "hono"
import { bodyLimit } from "hono/body-limit"
import { z } from "zod"

import type { CloudEnv } from "./env.js"
import { hmacSha256Hex, relayPing, routeKeyOf, signedWithHmac } from "./webhook-relay.js"

export interface LinearPing {
  readonly organizationId: string
  readonly type: "Issue" | "Comment"
  readonly action: "create" | "update"
  readonly id: string
  readonly createdAt: string
  readonly updatedAt?: string
  readonly actorId?: string
  readonly changed: ReadonlyArray<string>
  readonly previous: PreviousValues
}

export interface PreviousValues {
  readonly stateId?: string | null
  readonly assigneeId?: string | null
  readonly priority?: number | null
}

export const LINEAR_PUSH_BODY_LIMIT = 1024 * 1024
export const LINEAR_WEBHOOK_MAX_SKEW_MS = 60_000

export const linearPush = new Hono<{ Bindings: CloudEnv }>()

linearPush.on(
  "POST",
  ["/push/linear", "/hooks/push/linear"],
  bodyLimit({ maxSize: LINEAR_PUSH_BODY_LIMIT }),
  async (c) => {
    const secret = c.env.LINEAR_WEBHOOK_SECRET
    if (!secret) return c.json({ error: "not found" }, 404)

    const raw = await c.req.text()
    if (!(await signedWithHmac(secret, raw, c.req.header("linear-signature"))))
      return c.json({ error: "unauthorized" }, 401)

    const delivery = linearDeliveryOf(raw)
    if (delivery === undefined) return new Response(null, { status: 200 })
    if (!fresh(delivery.webhookTimestamp, Date.now())) return c.json({ error: "stale" }, 401)

    const ping = pingOf(delivery)
    if (ping !== undefined)
      await relayPing(c.env, "linear", ping.organizationId, ping, c.req.raw.cf)
    return new Response(null, { status: 200 })
  }
)

export const linearRouteKey = routeKeyOf

export const linearSignature = hmacSha256Hex

const fresh = (sentAt: number, now: number): boolean =>
  Math.abs(now - sentAt) <= LINEAR_WEBHOOK_MAX_SKEW_MS

type LinearDelivery = z.infer<typeof LinearDelivery>

const linearDeliveryOf = (raw: string): LinearDelivery | undefined => {
  try {
    return LinearDelivery.safeParse(JSON.parse(raw)).data
  } catch {
    return undefined
  }
}

const pingOf = (delivery: LinearDelivery): LinearPing | undefined => {
  const kind = relayedKinds.get(`${delivery.type}.${delivery.action}`)
  if (kind === undefined) return undefined

  return {
    organizationId: delivery.organizationId,
    ...kind,
    id: delivery.data.id,
    createdAt: delivery.createdAt,
    ...(delivery.data.updatedAt === undefined ? {} : { updatedAt: delivery.data.updatedAt }),
    ...(delivery.actor?.id === undefined ? {} : { actorId: delivery.actor.id }),
    changed: Object.keys(delivery.updatedFrom ?? {}),
    previous: previousValues(delivery.updatedFrom ?? {})
  }
}

const relayedKinds: ReadonlyMap<string, Pick<LinearPing, "type" | "action">> = new Map([
  ["Issue.create", { type: "Issue", action: "create" }],
  ["Issue.update", { type: "Issue", action: "update" }],
  ["Comment.create", { type: "Comment", action: "create" }]
])

const previousValues = (updatedFrom: Record<string, unknown>): PreviousValues =>
  Object.fromEntries(
    previousFields.flatMap(([name, schema]) => {
      if (!(name in updatedFrom)) return []
      const value = schema.safeParse(updatedFrom[name])
      return value.success ? [[name, value.data]] : []
    })
  )

const previousFields = [
  ["stateId", z.string().max(100).nullable()],
  ["assigneeId", z.string().max(100).nullable()],
  ["priority", z.number().int().nullable()]
] as const

const entityId = z.string().min(1).max(100)

const LinearDelivery = z.object({
  type: z.string(),
  action: z.string(),
  organizationId: entityId,
  createdAt: z.string().max(64),
  webhookTimestamp: z.number(),
  data: z.object({ id: entityId, updatedAt: z.string().max(64).optional() }),
  actor: z.object({ id: entityId.optional() }).nullish(),
  updatedFrom: z.record(z.string(), z.unknown()).optional()
})
