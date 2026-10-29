import { decode, McpServer, PluginCatalogResponse } from "@codevisor/api"
import { describe, expect, it } from "vitest"

import { jsonRequest } from "../test-support.js"
import {
  catalogFixture,
  openServer,
  ticketsServer,
  weatherServer
} from "./plugin-catalog-test-support.js"
import { makePluginCatalog } from "./plugin-catalog.js"
import { post, startPluginApp, startWithoutPlugins } from "./plugin-test-support.js"

const catalogApp = async () => {
  const fixture = await catalogFixture(undefined, [ticketsServer, weatherServer, openServer])
  const running = await startPluginApp({ catalog: fixture.options })
  return { ...running, fixture }
}

type CatalogApp = Awaited<ReturnType<typeof catalogApp>>

const install = (running: CatalogApp, id: string, values: Record<string, unknown> = {}) =>
  post(running, `/v1/plugins/catalog/${encodeURIComponent(id)}/install`, { values })

const installed = async (running: CatalogApp, id: string, values: Record<string, unknown> = {}) =>
  decode(McpServer)((await install(running, id, values)).body)

const entryIds = async (running: CatalogApp, path: string) =>
  decode(PluginCatalogResponse)((await jsonRequest(running.server, path)).body).entries.map(
    (entry) => entry.id
  )

describe("plugin catalog routes", () => {
  it("lists the curated catalog and narrows it to a query", async () => {
    const running = await catalogApp()

    const featured = await entryIds(running, "/v1/plugins/catalog")
    const searched = await entryIds(running, "/v1/plugins/catalog?query=weather")

    expect(featured).toEqual([
      "dev.codevisor/alerts",
      "dev.codevisor/devtool",
      "io.example/tickets",
      "io.example/weather",
      "io.example/open"
    ])
    expect(searched).toEqual(["io.example/weather"])
  })

  it("describes one catalog plugin", async () => {
    const running = await catalogApp()

    const alerts = await jsonRequest(
      running.server,
      `/v1/plugins/catalog/${encodeURIComponent("dev.codevisor/alerts")}`
    )
    const weather = await jsonRequest(
      running.server,
      `/v1/plugins/catalog/${encodeURIComponent("io.example/weather")}`
    )
    const unknown = await jsonRequest(
      running.server,
      `/v1/plugins/catalog/${encodeURIComponent("io.example/nope")}`
    )

    expect(alerts.body).toMatchObject({ id: "dev.codevisor/alerts", install: { kind: "bundled" } })
    expect(weather.body).toMatchObject({ id: "io.example/weather", source: "popular" })
    expect([unknown.status, unknown.body]).toEqual([
      404,
      { error: "Unknown plugin: io.example/nope" }
    ])
  })

  it("installs a bundled plugin once, launched by the catalog", async () => {
    const running = await catalogApp()

    const first = await installed(running, "dev.codevisor/alerts")
    const second = await installed(running, "dev.codevisor/alerts")

    expect(second.id).toBe(first.id)
    expect(first).toMatchObject({
      name: "Alerts",
      catalogId: "dev.codevisor/alerts",
      catalogVersion: "2.0.0",
      transport: "stdio",
      command: "codevisor-plugin",
      args: ["dev.codevisor/alerts"]
    })
  })

  it("installs a package plugin with its arguments and environment filled in", async () => {
    const running = await catalogApp()

    const weather = await installed(running, "io.example/weather", {
      "env:WEATHER_KEY": "secret-key",
      "arg:0": "/tmp/weather"
    })

    expect(weather).toMatchObject({
      catalogId: "io.example/weather",
      catalogVersion: "1.2.0",
      transport: "stdio",
      command: "/usr/bin/false",
      args: ["-y", "@example/weather@1.2.0", "/tmp/weather", "--units", "metric"],
      environmentNames: ["WEATHER_KEY", "WEATHER_REGION"]
    })
    expect(JSON.stringify(weather)).not.toContain("secret-key")
  })

  it("installs remote plugins with their headers, and asks for required ones", async () => {
    const running = await catalogApp()

    const missing = await install(running, "io.example/tickets")
    const tickets = await installed(running, "io.example/tickets", {
      "header:Authorization": "Bearer token"
    })
    const open = await installed(running, "io.example/open")

    expect([missing.status, missing.body]).toEqual([400, { error: "Authorization is required" }])
    expect(tickets).toMatchObject({
      transport: "http",
      url: `${running.fixture.remoteUrl}/tickets`,
      headerNames: ["Authorization"]
    })
    expect(open).toMatchObject({
      transport: "http",
      url: `${running.fixture.remoteUrl}/open`,
      headerNames: []
    })
    expect(JSON.stringify(tickets)).not.toContain("Bearer token")
  })

  it("explains unknown plugins and leaves other methods to the router", async () => {
    const running = await catalogApp()

    const unknown = await install(running, "io.example/nope")
    const wrongMethod = await jsonRequest(
      running.server,
      `/v1/plugins/catalog/${encodeURIComponent("dev.codevisor/alerts")}/install`
    )

    expect([unknown.status, unknown.body]).toEqual([
      404,
      { error: "Unknown plugin: io.example/nope" }
    ])
    expect(wrongMethod.status).toBe(404)
  })

  it("answers 501 without a catalog or without MCP", async () => {
    const bare = await startWithoutPlugins()
    const catalogOnly = await startWithoutPlugins({
      pluginCatalog: makePluginCatalog({ dev: false, ...(await catalogFixture()).options })
    })

    const responses = await Promise.all([
      jsonRequest(bare, "/v1/plugins/catalog"),
      post(
        { server: catalogOnly },
        `/v1/plugins/catalog/${encodeURIComponent("dev.codevisor/alerts")}/install`
      )
    ])

    expect(responses.map((response) => [response.status, response.body])).toEqual([
      [501, { error: "Plugins unavailable" }],
      [501, { error: "Plugins unavailable" }]
    ])
  })
})
