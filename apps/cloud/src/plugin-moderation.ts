import { Hono, type Context } from "hono"
import { bodyLimit } from "hono/body-limit"
import { z } from "zod"

import { createAuth } from "./auth.js"
import type { CloudEnv } from "./env.js"
import { notifyPluginReports } from "./plugin-reports.js"

const pluginIdPattern = /^[a-z0-9-]+\.[a-z0-9-]+$/
const publisherPattern = /^[a-z0-9-]{1,100}$/
const reportReasons = new Set(["Harmful content", "Privacy or security", "Spam or abuse", "Other"])
const jsonRecord = z.record(z.string(), z.unknown())
const recordOrEmpty = (value: unknown): Record<string, unknown> => {
  const parsed = jsonRecord.safeParse(value)
  return parsed.success ? parsed.data : {}
}
const readBody = async (request: Request): Promise<Record<string, unknown>> =>
  recordOrEmpty(await request.json().catch(() => null))
type ModerationEnv = { Bindings: CloudEnv; Variables: { userId: string } }
const catalogMetadata = z.object({
  name: z.string().min(1).max(120),
  version: z.string().min(1).max(64),
  description: z.string().max(2000).optional(),
  ageRating: z
    .union([z.literal(4), z.literal(9), z.literal(13), z.literal(16), z.literal(18)])
    .optional(),
  panes: z.array(z.object({ type: z.string().max(120), title: z.string().max(120) })).max(32),
  tools: z.array(z.object({ name: z.string().max(120), description: z.string().max(1000) })).max(64)
})
interface ConsentRequest extends Record<string, unknown> {
  pluginId: string
  consentKey: string
  noticeVersion: 1
}

const isConsentRequest = (body: Record<string, unknown>): body is ConsentRequest => {
  if (
    typeof body.pluginId !== "string" ||
    !pluginIdPattern.test(body.pluginId) ||
    typeof body.consentKey !== "string" ||
    !/^[a-f0-9]{64}$/.test(body.consentKey) ||
    body.noticeVersion !== 1
  ) {
    return false
  }
  return true
}

interface ReportRequest extends Record<string, unknown> {
  id: string
  pluginId: string
  pluginName: string
  reason: string
  details: string
}

const isReportRequest = (body: Record<string, unknown>): body is ReportRequest => {
  if (
    typeof body.id !== "string" ||
    !/^[a-f0-9-]{36}$/i.test(body.id) ||
    typeof body.pluginId !== "string" ||
    !pluginIdPattern.test(body.pluginId) ||
    typeof body.pluginName !== "string" ||
    body.pluginName.length < 1 ||
    body.pluginName.length > 120 ||
    typeof body.reason !== "string" ||
    !reportReasons.has(body.reason) ||
    typeof body.details !== "string" ||
    body.details.length > 2000
  ) {
    return false
  }
  return true
}

export const pluginModeration = new Hono<ModerationEnv>()

pluginModeration.use("/api/plugins/*", bodyLimit({ maxSize: 8192 }))
pluginModeration.use("/api/plugins/*", async (c, next) => {
  c.header("Cache-Control", "no-store")
  if (c.req.path.startsWith("/api/")) {
    const session = await createAuth(c.env).api.getSession({ headers: c.req.raw.headers })
    if (!session) return c.json({ error: "unauthorized" }, 401)
    c.set("userId", session.user.id)
  }
  return next()
})

pluginModeration.get("/plugins/policy", async (c) => {
  c.header("Cache-Control", "no-store")
  const [blocks, ageRatings] = await pluginPolicy(c)
  return c.json({
    supportedAgeRating: 16,
    blocks: blocks?.results ?? [],
    ageRatings: ageRatings?.results ?? []
  })
})

pluginModeration.get("/api/plugins/preferences", async (c) => {
  const userId = c.get("userId")
  const [publishers, consents] = await userPreferences(c, userId)
  return c.json({
    blockedPublishers: publishers?.results.map((row) => row.publisher) ?? [],
    consents: consents?.results ?? []
  })
})

pluginModeration.post("/api/plugins/consent", async (c) => {
  const body = await readBody(c.req.raw)
  const metadata = catalogMetadata.safeParse(body.metadata)
  if (!isConsentRequest(body) || !metadata.success) {
    return c.json({ error: "invalid consent" }, 400)
  }
  await c.env.DB.prepare(consentSql.upsert)
    .bind(
      c.get("userId"),
      body.pluginId,
      body.consentKey,
      Date.now(),
      JSON.stringify(metadata.data)
    )
    .run()
  return c.json({ ok: true })
})

pluginModeration.get("/api/plugins/index", async (c) => {
  const rows = await consentedPlugins(c)
  return c.json({
    entries: rows.results.map((row) => ({
      ...recordOrEmpty(JSON.parse(row.metadata)),
      id: row.plugin_id,
      consentKey: row.consent_key,
      url: `https://www.codevisor.dev/plugins/${row.plugin_id}`
    }))
  })
})

pluginModeration.put("/api/plugins/publishers/:publisher", async (c) => {
  const publisher = c.req.param("publisher").toLowerCase()
  if (!publisherPattern.test(publisher)) return c.json({ error: "invalid publisher" }, 400)
  await c.env.DB.prepare(publisherBlockSql.insert)
    .bind(c.get("userId"), publisher, Date.now())
    .run()
  return c.json({ ok: true })
})

pluginModeration.delete("/api/plugins/publishers/:publisher", async (c) => {
  const publisher = c.req.param("publisher").toLowerCase()
  if (!publisherPattern.test(publisher)) return c.json({ error: "invalid publisher" }, 400)
  await c.env.DB.prepare(publisherBlockSql.delete).bind(c.get("userId"), publisher).run()
  return c.json({ ok: true })
})

pluginModeration.post("/api/plugins/reports", async (c) => {
  const body = await readBody(c.req.raw)
  if (!isReportRequest(body)) return c.json({ error: "invalid report" }, 400)
  const userId = c.get("userId")
  const existing = await reportOwner(c, body)
  if (existing) {
    if (existing.user_id === userId) return c.json({ ok: true })
    return c.json({ error: "invalid report id" }, 409)
  }
  const inserted = await c.env.DB.prepare(reportSql.insertWithinLimit)
    .bind(
      body.id,
      userId,
      body.pluginId,
      body.pluginName,
      body.reason,
      body.details,
      Date.now(),
      userId,
      Date.now() - 3600000
    )
    .run()
  if (inserted.meta.changes === 0) return c.json({ error: "Please try again later." }, 429)
  c.executionCtx.waitUntil(notifyPluginReports(c.env))
  return c.json({ ok: true }, 201)
})

const pluginPolicy = (c: Context<ModerationEnv>) =>
  c.env.DB.batch([c.env.DB.prepare(policySql.blocks), c.env.DB.prepare(policySql.ageRatings)])

const userPreferences = (c: Context<ModerationEnv>, userId: string) =>
  c.env.DB.batch<Record<string, unknown>>([
    c.env.DB.prepare(publisherBlockSql.byUser).bind(userId),
    c.env.DB.prepare(consentSql.byUser).bind(userId)
  ])

const consentedPlugins = (c: Context<ModerationEnv>) =>
  c.env.DB.prepare(consentSql.index)
    .bind(c.get("userId"))
    .all<{ plugin_id: string; consent_key: string; metadata: string }>()

const reportOwner = (c: Context<ModerationEnv>, report: ReportRequest) =>
  c.env.DB.prepare(reportSql.ownerById).bind(report.id).first<{ user_id: string }>()

const policySql = {
  blocks: "SELECT target_kind AS targetKind, target, reason FROM plugin_blocks",
  ageRatings: "SELECT plugin_id AS pluginId, minimum_age AS minimumAge FROM plugin_age_ratings"
}

const publisherBlockSql = {
  byUser: "SELECT publisher FROM plugin_publisher_blocks WHERE user_id = ?",
  insert:
    "INSERT OR IGNORE INTO plugin_publisher_blocks (user_id, publisher, created_at) VALUES (?, ?, ?)",
  delete: "DELETE FROM plugin_publisher_blocks WHERE user_id = ? AND publisher = ?"
}

const consentSql = {
  byUser:
    "SELECT plugin_id AS pluginId, consent_key AS consentKey, notice_version AS noticeVersion FROM plugin_consents WHERE user_id = ?",
  index: "SELECT plugin_id, consent_key, metadata FROM plugin_consents WHERE user_id = ?",
  upsert:
    "INSERT INTO plugin_consents (user_id, plugin_id, consent_key, notice_version, created_at, metadata) VALUES (?, ?, ?, 1, ?, ?) ON CONFLICT(user_id, plugin_id, consent_key) DO UPDATE SET notice_version = 1, created_at = excluded.created_at, metadata = excluded.metadata"
}

const reportSql = {
  ownerById: "SELECT user_id FROM plugin_reports WHERE id = ?",
  insertWithinLimit:
    "INSERT INTO plugin_reports (id, user_id, plugin_id, plugin_name, reason, details, created_at) SELECT ?, ?, ?, ?, ?, ?, ? WHERE (SELECT count(*) FROM plugin_reports WHERE user_id = ? AND created_at > ?) < 20"
}
