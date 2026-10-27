import { Hono, type Context } from "hono"
import { bodyLimit } from "hono/body-limit"
import { z } from "zod"

import { createAuth } from "./auth.js"
import type { CloudEnv } from "./env.js"
import { isPluginId, isPublisher, pluginPageUrl } from "./plugin-ids.js"
import { notifyPluginReports } from "./plugin-reports.js"

export interface PluginAgeRating {
  pluginId: string
  minimumAge: number
}

export const supportedAgeRating = 16
export const reportsPerHour = 20

const maxBodyBytes = 8192

export const pluginModeration = new Hono<ModerationEnv>()

pluginModeration.use("/api/plugins/*", bodyLimit({ maxSize: maxBodyBytes }))
pluginModeration.use("/api/plugins/*", async (c, next) => {
  c.header("Cache-Control", "no-store")
  const userId = await sessionUserId(c)
  if (userId === undefined) return c.json({ error: "unauthorized" }, 401)

  c.set("userId", userId)
  return next()
})

pluginModeration.get("/plugins/policy", async (c) => {
  c.header("Cache-Control", "no-store")
  const [blocks, ageRatings] = await Promise.all([
    pluginBlocks(c.env.DB),
    pluginAgeRatings(c.env.DB)
  ])
  return c.json({ supportedAgeRating, blocks, ageRatings })
})

pluginModeration.get("/api/plugins/preferences", async (c) => {
  const userId = c.get("userId")
  const [blockedPublishers, consents] = await Promise.all([
    blockedPublishersOf(c.env.DB, userId),
    consentsOf(c.env.DB, userId)
  ])
  return c.json({ blockedPublishers, consents })
})

pluginModeration.post("/api/plugins/consent", async (c) => {
  const consent = ConsentRequest.safeParse(await readBody(c.req.raw))
  if (!consent.success) return c.json({ error: "invalid consent" }, 400)

  await saveConsent(c.env.DB, c.get("userId"), consent.data)
  return c.json({ ok: true })
})

pluginModeration.get("/api/plugins/index", async (c) => {
  const consents = await consentedPlugins(c.env.DB, c.get("userId"))
  return c.json({ entries: consents.map(indexEntry) })
})

pluginModeration.put("/api/plugins/publishers/:publisher", async (c) => {
  const publisher = c.req.param("publisher").toLowerCase()
  if (!isPublisher(publisher)) return c.json({ error: "invalid publisher" }, 400)

  await c.env.DB.prepare(publisherBlockSql.insert)
    .bind(c.get("userId"), publisher, Date.now())
    .run()
  return c.json({ ok: true })
})

pluginModeration.delete("/api/plugins/publishers/:publisher", async (c) => {
  const publisher = c.req.param("publisher").toLowerCase()
  if (!isPublisher(publisher)) return c.json({ error: "invalid publisher" }, 400)

  await c.env.DB.prepare(publisherBlockSql.delete).bind(c.get("userId"), publisher).run()
  return c.json({ ok: true })
})

pluginModeration.post("/api/plugins/reports", async (c) => {
  const report = ReportRequest.safeParse(await readBody(c.req.raw))
  if (!report.success) return c.json({ error: "invalid report" }, 400)

  const userId = c.get("userId")
  const existing = await existingReport(c.env.DB, report.data.id)
  if (existing !== null) return repeatedReport(c, existing, userId)

  const stored = await insertReportWithinLimit(c.env.DB, userId, report.data)
  if (!stored) return c.json({ error: "Please try again later." }, 429)

  c.executionCtx.waitUntil(notifyPluginReports(c.env))
  return c.json({ ok: true }, 201)
})

export const pluginAgeRatings = async (db: D1Database): Promise<PluginAgeRating[]> =>
  (await db.prepare(policySql.ageRatings).all<PluginAgeRating>()).results

type ModerationEnv = { Bindings: CloudEnv; Variables: { userId: string } }
type ConsentRequest = z.infer<typeof ConsentRequest>
type ReportRequest = z.infer<typeof ReportRequest>

interface ConsentRow {
  plugin_id: string
  consent_key: string
  metadata: string
}

interface ReportOwnerRow {
  user_id: string | null
}

const hourMs = 3_600_000
const consentNoticeVersion = 1
const maxCapabilityCount = 10_000
const reportReasons = ["Harmful content", "Privacy or security", "Spam or abuse", "Other"] as const
const jsonRecord = z.record(z.string(), z.unknown())
const pluginId = z.string().refine(isPluginId)
const capabilityCount = z.number().int().min(0).max(maxCapabilityCount)

const ConsentMetadata = z.object({
  name: z.string().min(1).max(120),
  version: z.string().min(1).max(64),
  description: z.string().max(2000).optional(),
  ageRating: z.literal([4, 9, 13, 16, 18]).optional(),
  publisher: z.string().min(1).max(120),
  capabilities: z
    .object({
      tools: capabilityCount,
      events: capabilityCount,
      skills: capabilityCount,
      panes: capabilityCount,
      ingress: capabilityCount
    })
    .optional()
})

const ConsentRequest = z.object({
  pluginId,
  consentKey: z.string().regex(/^[a-f0-9]{64}$/),
  noticeVersion: z.literal(consentNoticeVersion),
  metadata: ConsentMetadata
})

const ReportRequest = z.object({
  id: z.string().regex(/^[a-f0-9-]{36}$/i),
  pluginId,
  pluginName: z.string().min(1).max(120),
  reason: z.enum(reportReasons),
  details: z.string().max(2000)
})

const sessionUserId = async (c: Context<ModerationEnv>): Promise<string | undefined> => {
  const session = await createAuth(c.env).api.getSession({ headers: c.req.raw.headers })
  return session?.user.id
}

const readBody = async (request: Request): Promise<unknown> =>
  await request.json().catch(() => null)

const indexEntry = (row: ConsentRow) => ({
  ...storedMetadata(row.metadata),
  id: row.plugin_id,
  consentKey: row.consent_key,
  url: pluginPageUrl(row.plugin_id)
})

const storedMetadata = (raw: string): Record<string, unknown> => {
  const parsed = jsonRecord.safeParse(JSON.parse(raw))
  return parsed.success ? parsed.data : {}
}

const repeatedReport = (c: Context<ModerationEnv>, existing: ReportOwnerRow, userId: string) => {
  if (existing.user_id === userId) return c.json({ ok: true })
  return c.json({ error: "invalid report id" }, 409)
}

const pluginBlocks = async (db: D1Database): Promise<Record<string, unknown>[]> =>
  (await db.prepare(policySql.blocks).all()).results

const blockedPublishersOf = async (db: D1Database, userId: string): Promise<string[]> => {
  const rows = await db.prepare(publisherBlockSql.byUser).bind(userId).all<{ publisher: string }>()
  return rows.results.map((row) => row.publisher)
}

const consentsOf = async (db: D1Database, userId: string): Promise<Record<string, unknown>[]> =>
  (await db.prepare(consentSql.byUser).bind(userId).all()).results

const consentedPlugins = async (db: D1Database, userId: string): Promise<ConsentRow[]> =>
  (await db.prepare(consentSql.index).bind(userId).all<ConsentRow>()).results

const saveConsent = async (db: D1Database, userId: string, consent: ConsentRequest) => {
  await db
    .prepare(consentSql.upsert)
    .bind(
      userId,
      consent.pluginId,
      consent.consentKey,
      Date.now(),
      JSON.stringify(consent.metadata)
    )
    .run()
}

const existingReport = (db: D1Database, id: string): Promise<ReportOwnerRow | null> =>
  db.prepare(reportSql.ownerById).bind(id).first<ReportOwnerRow>()

const insertReportWithinLimit = async (
  db: D1Database,
  userId: string,
  report: ReportRequest
): Promise<boolean> => {
  const now = Date.now()
  const inserted = await db
    .prepare(reportSql.insertWithinLimit)
    .bind(
      report.id,
      userId,
      report.pluginId,
      report.pluginName,
      report.reason,
      report.details,
      now,
      userId,
      now - hourMs,
      reportsPerHour
    )
    .run()
  return inserted.meta.changes > 0
}

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
    "INSERT INTO plugin_reports (id, user_id, plugin_id, plugin_name, reason, details, created_at) SELECT ?, ?, ?, ?, ?, ?, ? WHERE (SELECT count(*) FROM plugin_reports WHERE user_id = ? AND created_at > ?) < ?"
}
