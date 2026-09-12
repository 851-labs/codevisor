import { Hono } from "hono"
import { bodyLimit } from "hono/body-limit"
import { z } from "zod"
import { createAuth } from "./auth.js"
import type { CloudEnv } from "./env.js"
import { notifyPluginReports } from "./plugin-reports.js"

const pluginIdPattern = /^[a-z0-9-]+\.[a-z0-9-]+$/
const publisherPattern = /^[a-z0-9-]{1,100}$/
const reportReasons = new Set(["Harmful content", "Privacy or security", "Spam or abuse", "Other"])
const readBody = async (request: Request): Promise<Record<string, unknown>> => {
  const value: unknown = await request.json().catch(() => null)
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {}
}
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
  const [blocks, ageRatings] = await c.env.DB.batch([
    c.env.DB.prepare("SELECT target_kind AS targetKind, target, reason FROM plugin_blocks"),
    c.env.DB.prepare(
      "SELECT plugin_id AS pluginId, minimum_age AS minimumAge FROM plugin_age_ratings"
    )
  ])
  return c.json({
    supportedAgeRating: 16,
    blocks: blocks?.results ?? [],
    ageRatings: ageRatings?.results ?? []
  })
})

pluginModeration.get("/api/plugins/preferences", async (c) => {
  const userId = c.get("userId")
  const [publishers, consents] = await c.env.DB.batch<Record<string, unknown>>([
    c.env.DB.prepare("SELECT publisher FROM plugin_publisher_blocks WHERE user_id = ?").bind(
      userId
    ),
    c.env.DB.prepare(
      "SELECT plugin_id AS pluginId, consent_key AS consentKey, notice_version AS noticeVersion FROM plugin_consents WHERE user_id = ?"
    ).bind(userId)
  ])
  return c.json({
    blockedPublishers: publishers?.results.map((row) => row.publisher) ?? [],
    consents: consents?.results ?? []
  })
})

pluginModeration.post("/api/plugins/consent", async (c) => {
  const body = await readBody(c.req.raw)
  const metadata = catalogMetadata.safeParse(body.metadata)
  if (
    typeof body.pluginId !== "string" ||
    !pluginIdPattern.test(body.pluginId) ||
    typeof body.consentKey !== "string" ||
    !/^[a-f0-9]{64}$/.test(body.consentKey) ||
    body.noticeVersion !== 1 ||
    !metadata.success
  )
    return c.json({ error: "invalid consent" }, 400)
  await c.env.DB.prepare(
    "INSERT INTO plugin_consents (user_id, plugin_id, consent_key, notice_version, created_at, metadata) VALUES (?, ?, ?, 1, ?, ?) ON CONFLICT(user_id, plugin_id, consent_key) DO UPDATE SET notice_version = 1, created_at = excluded.created_at, metadata = excluded.metadata"
  )
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

// Account-only index also covers unlisted and privately developed plugins.
pluginModeration.get("/api/plugins/index", async (c) => {
  const rows = await c.env.DB.prepare(
    "SELECT plugin_id, consent_key, metadata FROM plugin_consents WHERE user_id = ?"
  )
    .bind(c.get("userId"))
    .all<{ plugin_id: string; consent_key: string; metadata: string }>()
  return c.json({
    entries: rows.results.map((row) => ({
      ...(JSON.parse(row.metadata) as Record<string, unknown>),
      id: row.plugin_id,
      consentKey: row.consent_key,
      url: `https://www.codevisor.dev/plugins/${row.plugin_id}`
    }))
  })
})

pluginModeration.put("/api/plugins/publishers/:publisher", async (c) => {
  const publisher = c.req.param("publisher").toLowerCase()
  if (!publisherPattern.test(publisher)) return c.json({ error: "invalid publisher" }, 400)
  await c.env.DB.prepare(
    "INSERT OR IGNORE INTO plugin_publisher_blocks (user_id, publisher, created_at) VALUES (?, ?, ?)"
  )
    .bind(c.get("userId"), publisher, Date.now())
    .run()
  return c.json({ ok: true })
})

pluginModeration.delete("/api/plugins/publishers/:publisher", async (c) => {
  const publisher = c.req.param("publisher").toLowerCase()
  if (!publisherPattern.test(publisher)) return c.json({ error: "invalid publisher" }, 400)
  await c.env.DB.prepare("DELETE FROM plugin_publisher_blocks WHERE user_id = ? AND publisher = ?")
    .bind(c.get("userId"), publisher)
    .run()
  return c.json({ ok: true })
})

pluginModeration.post("/api/plugins/reports", async (c) => {
  const body = await readBody(c.req.raw)
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
    return c.json({ error: "invalid report" }, 400)
  }
  const userId = c.get("userId")
  const existing = await c.env.DB.prepare("SELECT user_id FROM plugin_reports WHERE id = ?")
    .bind(body.id)
    .first<{ user_id: string }>()
  if (existing)
    return existing.user_id === userId
      ? c.json({ ok: true })
      : c.json({ error: "invalid report id" }, 409)
  // Atomic insertion also enforces the per-account limit under concurrent requests.
  const inserted = await c.env.DB.prepare(
    "INSERT INTO plugin_reports (id, user_id, plugin_id, plugin_name, reason, details, created_at) SELECT ?, ?, ?, ?, ?, ?, ? WHERE (SELECT count(*) FROM plugin_reports WHERE user_id = ? AND created_at > ?) < 20"
  )
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
