import { createExecutionContext, env, SELF, waitOnExecutionContext } from "cloudflare:test"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import worker from "../src/index.js"
import { notifyPluginReports } from "../src/plugin-reports.js"

const BASE = "https://cloud.example.com"
const report = {
  id: "a0000000-0000-4000-8000-000000000001",
  pluginId: "acme.notes",
  pluginName: "Notes",
  reason: "Privacy or security",
  details: "Unexpected data upload"
}
const login = async () => {
  const response = await SELF.fetch(`${BASE}/dev/login`, { method: "POST" })
  return ((await response.json()) as { token: string }).token
}
const request = (path: string, token?: string, body?: unknown, method = "POST") =>
  new Request(`${BASE}${path}`, {
    method,
    headers: {
      "content-type": "application/json",
      ...(token ? { authorization: `Bearer ${token}` } : {})
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  })

beforeEach(() => {
  vi.useFakeTimers({ toFake: ["Date"] })
  vi.setSystemTime(new Date("2100-01-01T00:00:00Z"))
})
afterEach(() => {
  vi.useRealTimers()
})

describe("plugin moderation", () => {
  it("authenticates reports and validates input", async () => {
    expect((await SELF.fetch(request("/api/plugins/reports", undefined, report))).status).toBe(401)
    const token = await login()
    for (const body of [
      null,
      [],
      {},
      { ...report, pluginId: "../bad" },
      { ...report, details: "x".repeat(2001) }
    ]) {
      expect((await SELF.fetch(request("/api/plugins/reports", token, body))).status).toBe(400)
    }
  })

  it("persists before notifying, retries failures, and keeps report retries idempotent", async () => {
    const token = await login()
    const sent: unknown[] = []
    const fetcher = vi.fn((_url: string, init?: RequestInit) => {
      sent.push(JSON.parse(String(init?.body)))
      return Promise.resolve(new Response("unavailable", { status: 503 }))
    })
    const bindings = {
      ...env,
      PLUGIN_REPORT_SLACK_WEBHOOK: "https://hooks.slack.com/services/test/test/test",
      PLUGIN_REPORT_FETCH: fetcher
    }
    const ctx = createExecutionContext()
    expect(
      (await worker.fetch(request("/api/plugins/reports", token, report), bindings, ctx)).status
    ).toBe(201)
    await waitOnExecutionContext(ctx)
    expect(
      await env.DB.prepare("SELECT plugin_id, notified_at FROM plugin_reports WHERE id = ?")
        .bind(report.id)
        .first()
    ).toEqual({ plugin_id: report.pluginId, notified_at: null })
    expect(sent).toHaveLength(1)
    expect(sent[0]).toMatchObject({
      blocks: [{ text: { type: "plain_text", text: expect.stringContaining(report.id) } }]
    })
    await notifyPluginReports({ ...bindings, PLUGIN_REPORT_FETCH: async () => new Response("ok") })
    expect(
      (
        await env.DB.prepare("SELECT notified_at FROM plugin_reports WHERE id = ?")
          .bind(report.id)
          .first()
      )?.notified_at
    ).toBe(Date.now())
    expect((await SELF.fetch(request("/api/plugins/reports", token, report))).status).toBe(200)
    expect(
      (await env.DB.prepare("SELECT count(*) AS total FROM plugin_reports").first())?.total
    ).toBe(1)
  })

  it("shares account consent and publisher blocks across sessions and supports unblocking", async () => {
    const token = await login()
    const consent = { pluginId: "acme.notes", consentKey: "a".repeat(64), noticeVersion: 1 }
    const metadata = {
      name: "Notes",
      version: "1.0.0",
      ageRating: 4,
      panes: [{ type: "notes", title: "Notes" }],
      tools: []
    }
    expect(
      (await SELF.fetch(request("/api/plugins/consent", token, { ...consent, metadata }))).status
    ).toBe(200)
    const catalog = await SELF.fetch(request("/api/plugins/index", token, undefined, "GET"))
    expect(await catalog.json()).toEqual({
      entries: [
        {
          ...metadata,
          id: consent.pluginId,
          consentKey: consent.consentKey,
          url: "https://www.codevisor.dev/plugins/acme.notes"
        }
      ]
    })
    expect(
      (await SELF.fetch(request("/api/plugins/publishers/acme", token, undefined, "PUT"))).status
    ).toBe(200)
    const secondSession = await login()
    const preferences = await SELF.fetch(
      request("/api/plugins/preferences", secondSession, undefined, "GET")
    )
    expect(await preferences.json()).toEqual({ blockedPublishers: ["acme"], consents: [consent] })
    expect(
      (
        await SELF.fetch(
          request("/api/plugins/publishers/acme", secondSession, undefined, "DELETE")
        )
      ).status
    ).toBe(200)
    expect(
      (await env.DB.prepare("SELECT count(*) AS total FROM plugin_publisher_blocks").first())?.total
    ).toBe(0)
  })

  it("publishes DB changes immediately without removing the Mac catalog", async () => {
    const index = { generatedAt: "2100-01-01", entries: [{ id: "acme.notes" }], rejected: [] }
    await env.PLUGIN_INDEX.put("index", JSON.stringify(index))
    await env.DB.prepare(
      "INSERT INTO plugin_blocks (target_kind, target) VALUES ('plugin', 'acme.notes'), ('publisher', 'abusive')"
    ).run()
    await env.DB.prepare(
      "INSERT INTO plugin_age_ratings (plugin_id, minimum_age) VALUES ('acme.notes', 18)"
    ).run()
    const response = await SELF.fetch(`${BASE}/plugins/policy`)
    expect(response.headers.get("cache-control")).toBe("no-store")
    expect(await response.json()).toMatchObject({
      supportedAgeRating: 16,
      blocks: expect.arrayContaining([
        { targetKind: "plugin", target: "acme.notes", reason: "This plugin is unavailable on iOS." }
      ]),
      ageRatings: [{ pluginId: "acme.notes", minimumAge: 18 }]
    })
    expect(await (await SELF.fetch(`${BASE}/plugins/index.json`)).json()).toEqual(index)
    await env.DB.prepare("DELETE FROM plugin_blocks").run()
    expect(await (await SELF.fetch(`${BASE}/plugins/policy`)).json()).toMatchObject({ blocks: [] })
  })
})
