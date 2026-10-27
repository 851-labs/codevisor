import { decode } from "@codevisor/api"
import { Schema } from "effect"
import { describe, expect, it } from "vitest"

import { jsonRequest } from "../../test-support.js"
import { savePluginRow } from "../events/plugin-events-test-support.js"
import { catalogFixture } from "../plugin-catalog-test-support.js"
import {
  installTestEvents,
  post,
  startPluginApp,
  startPluginServer,
  startWithoutPlugins,
  type PluginServer
} from "../plugin-test-support.js"

const SearchResponse = Schema.Struct({
  items: Schema.Array(
    Schema.StructWithRest(
      Schema.Struct({
        plugin: Schema.String,
        name: Schema.String,
        installed: Schema.Boolean,
        ready: Schema.Boolean,
        auth: Schema.String
      }),
      [Schema.Record(Schema.String, Schema.Unknown)]
    )
  )
})

const search = async (running: Pick<PluginServer, "server">, query?: string) => {
  const suffix = query === undefined ? "" : `?query=${encodeURIComponent(query)}`
  const response = await jsonRequest(running.server, `/v1/plugins/search${suffix}`)
  return decode(SearchResponse)(response.body).items
}

const describePlugin = (running: Pick<PluginServer, "server">, plugin: string) =>
  jsonRequest(running.server, `/v1/plugins/describe/${encodeURIComponent(plugin)}`)

const saveGrafanaAccount = (running: Pick<PluginServer, "server">, serverId: string) =>
  post(running, `/v1/plugins/${serverId}/accounts`, {
    values: { url: "https://grafana.example.com", token: "glsa_secret" }
  })

describe("plugin directory", () => {
  it("lists installed plugins with their readiness and the catalog plugins still to install", async () => {
    const running = await startPluginServer()
    const testEvents = await installTestEvents(running)

    const items = await search(running)

    const byName = new Map(items.map((item) => [item.name, item]))
    expect(byName.get("Test Events")).toEqual({
      plugin: testEvents.id,
      name: "Test Events",
      description: expect.any(String),
      installed: true,
      enabled: true,
      ready: true,
      auth: "none",
      accounts: [],
      tools: ["emit", "list_recent", "show_events"],
      events: ["test.ping", "test.counter"],
      skills: ["test-events"],
      panes: ["Test events"]
    })
    expect(byName.get("Grafana")).toMatchObject({
      plugin: "dev.codevisor/grafana",
      installed: false,
      enabled: false,
      ready: false,
      auth: "fields"
    })
    expect(byName.get("Gmail")).toMatchObject({ auth: "oauth2", ready: false })
    expect(items.filter((item) => item.plugin === "dev.codevisor/test-events")).toEqual([])
  })

  it("matches installed plugins on any query word and catalog plugins on every word", async () => {
    const running = await startPluginApp()
    await savePluginRow(running.services.db, "Pinger")

    const anyWord = await search(running, "ping zzz-unknown")
    const alerts = await search(running, "alerts")

    expect(anyWord.map((item) => item.name)).toEqual(["Pinger"])
    expect(alerts.map((item) => item.name)).toContain("Grafana")
    expect(alerts.map((item) => item.name)).not.toContain("Gmail")
  })

  it("is ready only once a plugin that needs an account has one", async () => {
    const running = await startPluginApp()
    const grafana = await savePluginRow(running.services.db, "Grafana", {
      catalogId: "dev.codevisor/grafana",
      enabled: false
    })
    const disabledReady = (await search(running)).find((item) => item.plugin === grafana.id)?.ready
    const enabled = await savePluginRow(running.services.db, "Grafana Prod", {
      catalogId: "dev.codevisor/grafana"
    })

    const beforeAccount = (await search(running)).find((item) => item.plugin === enabled.id)
    await saveGrafanaAccount(running, enabled.id)
    const afterAccount = (await search(running)).find((item) => item.plugin === enabled.id)

    expect([disabledReady, beforeAccount?.ready, afterAccount?.ready]).toEqual([false, false, true])
    expect(afterAccount).toMatchObject({ accounts: ["grafana.example.com"] })
  })

  it("treats MCP sign-in plugins as ready while connected", async () => {
    const running = await startPluginApp()
    await savePluginRow(running.services.db, "Signed In", { authType: "oauth" })
    await savePluginRow(running.services.db, "Signed Out", {
      authType: "oauth",
      connectionState: "needsAuthorization"
    })

    const items = await search(running, "signed")

    expect(items.map((item) => [item.name, item.auth, item.ready])).toEqual([
      ["Signed In", "mcpOAuth", true],
      ["Signed Out", "mcpOAuth", false]
    ])
  })
})

describe("describing a plugin", () => {
  it("describes an installed plugin by name with its live tools and event types", async () => {
    const running = await startPluginServer()
    const testEvents = await installTestEvents(running)

    const described = await describePlugin(running, "test events")

    expect(described.body).toMatchObject({
      plugin: testEvents.id,
      installed: true,
      toolDetails: expect.arrayContaining([
        expect.objectContaining({
          name: "emit",
          inputSchema: expect.objectContaining({ type: "object" })
        })
      ]),
      eventDetails: [
        expect.objectContaining({ name: "test.ping", plugin: testEvents.id }),
        expect.objectContaining({ name: "test.counter", plugin: testEvents.id })
      ]
    })
    expect(described.body).not.toHaveProperty("accountSpec")
  })

  it("describes a catalog plugin's account needs without exposing its OAuth endpoints", async () => {
    const running = await startPluginApp()

    const grafana = await describePlugin(running, "dev.codevisor/grafana")
    const gmail = await describePlugin(running, "Gmail")

    expect(grafana.body).toMatchObject({
      installed: false,
      accountSpec: {
        label: "Grafana instance",
        fields: [
          { key: "url", label: "Grafana URL", type: "url", required: true },
          { key: "token", label: "Service account token", type: "secret", required: true },
          { key: "webhookSecret", label: "Webhook secret", type: "secret", required: true }
        ]
      },
      toolDetails: [
        { name: "list_alerts", description: "List firing and pending alerts", inputSchema: {} },
        expect.any(Object),
        expect.any(Object)
      ],
      eventDetails: []
    })
    expect(gmail.body).toMatchObject({
      accountSpec: {
        oauth: {
          provider: "google",
          scopes: ["https://www.googleapis.com/auth/gmail.modify", "openid", "email"]
        }
      }
    })
    expect(JSON.stringify(gmail.body)).not.toContain("oauth2.googleapis.com")
  })

  it("falls back to the saved tool digest when a plugin can't be reached or is off", async () => {
    const running = await startPluginApp()
    const tools = [{ name: "lookup", description: "Look something up" }, { name: "plain" }]
    const capabilities = { tools, events: [], skills: [], panes: [], ingress: [] }
    await savePluginRow(running.services.db, "Broken", { command: "/usr/bin/false", capabilities })
    await savePluginRow(running.services.db, "Switched Off", { enabled: false, capabilities })
    await savePluginRow(running.services.db, "Undiscovered", { enabled: false, capabilities: null })

    const broken = await describePlugin(running, "Broken")
    const off = await describePlugin(running, "Switched Off")
    const undiscovered = await describePlugin(running, "Undiscovered")

    const digest = [
      { name: "lookup", description: "Look something up", inputSchema: {} },
      { name: "plain", inputSchema: {} }
    ]
    expect([broken.body, off.body]).toEqual([
      expect.objectContaining({ toolDetails: digest }),
      expect.objectContaining({ toolDetails: digest })
    ])
    expect(undiscovered.body).toMatchObject({ tools: [], toolDetails: [], events: [] })
  })

  it("looks plugins up in the registry and explains unknown ones", async () => {
    const registry = await catalogFixture()
    const running = await startPluginApp({ catalog: registry.options })

    const weather = await describePlugin(running, "io.example/weather")
    const unknown = await describePlugin(running, "io.example/nope")

    expect(weather.body).toMatchObject({
      plugin: "io.example/weather",
      name: "Weather",
      installed: false
    })
    expect([unknown.status, unknown.body]).toEqual([
      404,
      { error: 'No plugin named "io.example/nope". Search with plugins.search.' }
    ])
  })

  it("lists accounts without the plugin platform as none", async () => {
    const running = await startPluginApp({ withoutPlatform: true })
    await savePluginRow(running.services.db, "Grafana", { catalogId: "dev.codevisor/grafana" })

    const grafana = (await search(running, "grafana")).find((item) => item.installed)

    expect(grafana).toMatchObject({ accounts: [], ready: false })
  })

  it("answers 501 when this server has no plugin catalog", async () => {
    const server = await startWithoutPlugins()

    const searched = await jsonRequest(server, "/v1/plugins/search")
    const unrouted = await jsonRequest(server, "/v1/plugins/setup-requests")

    expect([searched.status, searched.body]).toEqual([501, { error: "Plugins unavailable" }])
    expect(unrouted.status).toBe(404)
  })
})
