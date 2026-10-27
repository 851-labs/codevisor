import {
  createExecutionContext,
  createScheduledController,
  env,
  SELF,
  waitOnExecutionContext
} from "cloudflare:test"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { z } from "zod"

import worker from "../src/index.js"
import { reportsPerHour } from "../src/plugin-moderation.js"
import { BASE, devLogin } from "./cloud-test-support.js"
import { parseJson } from "./json-test-support.js"

const report = {
  id: "a0000000-0000-4000-8000-000000000001",
  pluginId: "app.linear/linear",
  pluginName: "Linear",
  reason: "Privacy or security",
  details: "Unexpected data upload"
}
const consent = { pluginId: "app.linear/linear", consentKey: "a".repeat(64), noticeVersion: 1 }
const metadata = {
  name: "Linear",
  version: "1.0.2",
  ageRating: 4,
  publisher: "Linear",
  capabilities: { tools: 12, events: 0, skills: 0, panes: 0, ingress: 0 }
}
const hourMs = 3_600_000

const request = (path: string, token?: string, body?: unknown, method = "POST") =>
  new Request(`${BASE}${path}`, {
    method,
    headers: {
      "content-type": "application/json",
      ...(token ? { authorization: `Bearer ${token}` } : {})
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  })

const send = (path: string, token?: string, body?: unknown, method = "POST") =>
  SELF.fetch(request(path, token, body, method))

const reportId = (index: number): string =>
  `a0000000-0000-4000-8000-${String(index).padStart(12, "0")}`

const reportRow = (id: string) =>
  env.DB.prepare("SELECT plugin_id, notified_at FROM plugin_reports WHERE id = ?").bind(id).first()

const tableCount = async (table: string): Promise<unknown> =>
  (await env.DB.prepare(`SELECT count(*) AS total FROM ${table}`).first())?.total

const slackBindings = (fetcher: (url: string, init?: RequestInit) => Promise<Response>) => ({
  ...env,
  PLUGIN_REPORT_SLACK_WEBHOOK: "https://hooks.slack.com/services/test/test/test",
  PLUGIN_REPORT_FETCH: fetcher
})

const userTables = ["plugin_reports", "plugin_consents", "plugin_publisher_blocks"]
const policyPlugin = "com.example/notes"

beforeEach(async () => {
  for (const table of userTables) await env.DB.prepare(`DELETE FROM ${table}`).run()
})

describe("plugin reports", () => {
  it("authenticates reports and validates input", async () => {
    expect((await send("/api/plugins/reports", undefined, report)).status).toBe(401)
    const token = await devLogin()

    for (const body of [
      null,
      [],
      {},
      { ...report, pluginId: "app.linear/linear/extra" },
      { ...report, pluginId: "acme.notes" },
      { ...report, pluginId: `app.linear/${"x".repeat(200)}` },
      { ...report, pluginId: "custom:bad host" },
      { ...report, reason: "Boring" },
      { ...report, details: "x".repeat(2001) }
    ]) {
      expect((await send("/api/plugins/reports", token, body)).status).toBe(400)
    }
  })

  it("persists before notifying, retries failures on the cron, and keeps retries idempotent", async () => {
    const token = await devLogin()
    const sent: unknown[] = []
    const failing = vi.fn((_url: string, init?: RequestInit) => {
      sent.push(parseJson(init?.body, z.unknown()))
      return Promise.resolve(new Response("unavailable", { status: 503 }))
    })
    const ctx = createExecutionContext()

    const created = await worker.fetch(
      request("/api/plugins/reports", token, report),
      slackBindings(failing),
      ctx
    )
    await waitOnExecutionContext(ctx)

    expect(created.status).toBe(201)
    expect(await reportRow(report.id)).toEqual({ plugin_id: report.pluginId, notified_at: null })
    expect(sent).toEqual([
      {
        blocks: [
          {
            type: "section",
            text: {
              type: "plain_text",
              text: [
                "Plugin report: Linear",
                "Plugin: app.linear/linear",
                "Publisher: app.linear",
                "Page: https://www.codevisor.dev/plugins/app.linear%2Flinear",
                "Reason: Privacy or security",
                "Unexpected data upload",
                `Report: ${report.id}`
              ].join("\n")
            }
          }
        ]
      }
    ])

    const cron = createExecutionContext()
    worker.scheduled(
      createScheduledController(),
      slackBindings(async () => new Response("ok")),
      cron
    )
    await waitOnExecutionContext(cron)

    expect(await reportRow(report.id)).toEqual({
      plugin_id: report.pluginId,
      notified_at: Date.now()
    })
    expect((await send("/api/plugins/reports", token, report)).status).toBe(200)
    expect(await tableCount("plugin_reports")).toBe(1)
  })

  it("rejects a report id that belongs to someone else", async () => {
    const token = await devLogin()
    await env.DB.prepare(
      "INSERT INTO plugin_reports (id, user_id, plugin_id, plugin_name, reason, created_at) VALUES (?, NULL, ?, ?, ?, ?)"
    )
      .bind(report.id, report.pluginId, report.pluginName, report.reason, Date.now())
      .run()

    expect((await send("/api/plugins/reports", token, report)).status).toBe(409)
  })

  it("limits each account to a fixed number of reports per hour", async () => {
    const token = await devLogin()
    const start = Date.now()
    for (let index = 0; index < reportsPerHour; index += 1) {
      const body = { ...report, id: reportId(index) }
      expect((await send("/api/plugins/reports", token, body)).status).toBe(201)
    }
    const overLimit = { ...report, id: reportId(reportsPerHour) }

    vi.setSystemTime(start + hourMs - 1)
    expect((await send("/api/plugins/reports", token, overLimit)).status).toBe(429)

    vi.setSystemTime(start + hourMs)
    expect((await send("/api/plugins/reports", token, overLimit)).status).toBe(201)
  })
})

describe("plugin consent and publisher blocks", () => {
  it("validates consent requests", async () => {
    const token = await devLogin()
    const valid = { ...consent, metadata }

    for (const body of [
      { ...valid, pluginId: "linear" },
      { ...valid, consentKey: "A".repeat(64) },
      { ...valid, noticeVersion: 2 },
      { ...valid, metadata: { ...metadata, publisher: "" } },
      { ...valid, metadata: { ...metadata, ageRating: 12 } },
      { ...valid, metadata: { ...metadata, capabilities: { tools: -1 } } }
    ]) {
      expect((await send("/api/plugins/consent", token, body)).status).toBe(400)
    }
  })

  it("lists consented plugins in the account index with universal links", async () => {
    const token = await devLogin()
    const custom = { ...consent, pluginId: "custom:mcp.example.com", consentKey: "b".repeat(64) }
    const customMetadata = { name: "Example", version: "1", publisher: "mcp.example.com" }

    expect((await send("/api/plugins/consent", token, { ...consent, metadata })).status).toBe(200)
    expect(
      (await send("/api/plugins/consent", token, { ...custom, metadata: customMetadata })).status
    ).toBe(200)
    const index = await send("/api/plugins/index", token, undefined, "GET")

    expect(index.headers.get("cache-control")).toBe("no-store")
    expect(await index.json()).toEqual({
      entries: expect.arrayContaining([
        {
          ...metadata,
          id: "app.linear/linear",
          consentKey: consent.consentKey,
          url: "https://www.codevisor.dev/plugins/app.linear%2Flinear"
        },
        {
          ...customMetadata,
          id: "custom:mcp.example.com",
          consentKey: custom.consentKey,
          url: "https://www.codevisor.dev/plugins/custom%3Amcp.example.com"
        }
      ])
    })
  })

  it("shares consent and publisher blocks across sessions and supports unblocking", async () => {
    const token = await devLogin()
    expect((await send("/api/plugins/consent", token, { ...consent, metadata })).status).toBe(200)
    expect((await send("/api/plugins/publishers/App.Linear", token, undefined, "PUT")).status).toBe(
      200
    )

    const secondSession = await devLogin()
    const preferences = await send("/api/plugins/preferences", secondSession, undefined, "GET")

    expect(await preferences.json()).toEqual({
      blockedPublishers: ["app.linear"],
      consents: [consent]
    })
    expect(
      (await send("/api/plugins/publishers/app.linear", secondSession, undefined, "DELETE")).status
    ).toBe(200)
    expect(await tableCount("plugin_publisher_blocks")).toBe(0)
  })

  it("rejects malformed publishers", async () => {
    const token = await devLogin()

    expect((await send("/api/plugins/publishers/-acme", token, undefined, "PUT")).status).toBe(400)
    expect(
      (await send(`/api/plugins/publishers/${"a".repeat(201)}`, token, undefined, "PUT")).status
    ).toBe(400)
    expect((await send("/api/plugins/publishers/acme", undefined, undefined, "PUT")).status).toBe(
      401
    )
  })
})

describe("plugin policy", () => {
  it("publishes blocks and age ratings from the database without caching", async () => {
    await env.DB.prepare(
      "INSERT INTO plugin_blocks (target_kind, target) VALUES ('plugin', ?), ('publisher', 'abusive.example')"
    )
      .bind(policyPlugin)
      .run()
    await env.DB.prepare("INSERT INTO plugin_age_ratings (plugin_id, minimum_age) VALUES (?, 18)")
      .bind(policyPlugin)
      .run()

    const response = await SELF.fetch(`${BASE}/plugins/policy`)

    expect(response.headers.get("cache-control")).toBe("no-store")
    expect(await response.json()).toEqual({
      supportedAgeRating: 16,
      blocks: expect.arrayContaining([
        {
          targetKind: "plugin",
          target: policyPlugin,
          reason: "This plugin is unavailable on iOS."
        },
        {
          targetKind: "publisher",
          target: "abusive.example",
          reason: "This plugin is unavailable on iOS."
        }
      ]),
      ageRatings: expect.arrayContaining([{ pluginId: policyPlugin, minimumAge: 18 }])
    })

    await env.DB.prepare("DELETE FROM plugin_blocks").run()
    await env.DB.prepare("DELETE FROM plugin_age_ratings WHERE plugin_id = ?")
      .bind(policyPlugin)
      .run()
    expect(await (await SELF.fetch(`${BASE}/plugins/policy`)).json()).toMatchObject({ blocks: [] })
  })
})
