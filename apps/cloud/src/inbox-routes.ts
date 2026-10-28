import { Hono } from "hono"
import { bodyLimit } from "hono/body-limit"
import { z } from "zod"

import {
  deleteInbox,
  hooksBaseUrl,
  INBOXES_OFF,
  inboxUrl,
  ownsInbox,
  provisionInbox
} from "./inbox-store.js"
import { userHub } from "./location-hint.js"
import { requireMachine, type MachineEnv } from "./machine-auth.js"

export const inboxRoutes = new Hono<MachineEnv>()

inboxRoutes.use("/api/machine/inboxes", requireMachine)
inboxRoutes.use("/api/machine/inboxes/*", requireMachine)

inboxRoutes.post("/api/machine/inboxes", bodyLimit({ maxSize: 8_192 }), async (c) => {
  const hooksBase = hooksBaseUrl(c.env)
  if (hooksBase === undefined) return c.json({ error: INBOXES_OFF }, 503)

  const target = InboxTargetBody.safeParse(await c.req.json<unknown>().catch(() => undefined))
  if (!target.success) return c.json({ error: "invalid inbox" }, 400)

  const id = await provisionInbox(c.env.DB, c.var.machine.userId, target.data)
  if (id === undefined) return c.json({ error: "too many inboxes" }, 409)

  c.header("Cache-Control", "no-store")
  return c.json({ id, url: inboxUrl(hooksBase, id) })
})

inboxRoutes.put("/api/machine/inboxes/:id/devices/self", async (c) => {
  const inboxId = c.req.param("id")
  const { userId, deviceId } = c.var.machine
  if (!(await ownsInbox(c.env.DB, userId, inboxId))) return c.json(unknownInbox, 404)

  const outcome = await userHub(c.env, userId, c.req.raw.cf).subscribeInbox(inboxId, deviceId)
  if (outcome === "unknown-device") return c.json({ error: "machine is not connected" }, 409)

  return c.json({ ok: true })
})

inboxRoutes.delete("/api/machine/inboxes/:id/devices/self", async (c) => {
  const inboxId = c.req.param("id")
  const { userId, deviceId } = c.var.machine
  if (!(await ownsInbox(c.env.DB, userId, inboxId))) return c.json(unknownInbox, 404)

  await userHub(c.env, userId, c.req.raw.cf).unsubscribeInbox(inboxId, deviceId)
  return c.json({ ok: true })
})

inboxRoutes.delete("/api/machine/inboxes/:id", async (c) => {
  const inboxId = c.req.param("id")
  const { userId } = c.var.machine
  if (!(await deleteInbox(c.env.DB, userId, inboxId))) return c.json(unknownInbox, 404)

  await userHub(c.env, userId, c.req.raw.cf).revokeInbox(inboxId)
  return c.json({ ok: true })
})

const unknownInbox = { error: "unknown inbox" }

const targetPart = z.string().min(1).max(200)

const InboxTargetBody = z.object({
  plugin: targetPart,
  accountId: z.string().max(200),
  ingress: targetPart
})
