import { describe, expect, it } from "vitest"

import {
  appTools,
  capturedView,
  launch,
  post,
  secured,
  shell
} from "../plugins/apps/plugin-app-route-support.js"
import { alertsHtml, boardHtml, zillowPlugin } from "../plugins/apps/plugin-app-test-support.js"
import { jsonRequest, start, startWithApp } from "../test-support.js"

describe("plugin app views", () => {
  it("issues view links only to authorized clients", async () => {
    const setup = await secured()
    const viewId = await capturedView(setup)

    const anonymous = await jsonRequest(setup.server, `/v1/plugins/apps/${viewId}/token`, {
      method: "POST"
    })
    const missing = await jsonRequest(
      setup.server,
      "/v1/plugins/apps/0b9a8f8e-5d1c-4f43-9f53-3e1c2c7f2a10/token",
      { method: "POST", headers: setup.authorized }
    )

    expect(anonymous.status).toBe(401)
    expect(missing).toEqual({
      status: 404,
      body: { error: "This app view is no longer available" }
    })
    expect(await launch(setup, `/v1/plugins/apps/${viewId}/token`)).toMatch(
      new RegExp(`^/v1/plugins/apps/${viewId}\\?token=[\\w-]+\\.[\\w-]+$`)
    )
  })

  it("serves the shell with the view's tool data under a strict CSP", async () => {
    const setup = await secured()
    const viewId = await capturedView(setup)
    const url = await launch(setup, `/v1/plugins/apps/${viewId}/token`)

    const loaded = await shell(setup, `${url}&theme=dark&platform=mobile&locale=en-US`)

    expect(loaded.status).toBe(200)
    expect(loaded.policy).toContain("connect-src 'self' https://grafana.example;")
    expect(loaded.policy).not.toContain("javascript:")
    expect(loaded.html).toContain('sandbox="allow-scripts allow-forms"')
    expect(loaded.boot).toMatchObject({
      allow: "clipboard-write",
      hostContext: {
        theme: "dark",
        displayMode: "inline",
        availableDisplayModes: ["inline"],
        platform: "mobile",
        locale: "en-US"
      },
      hostCapabilities: {
        sandbox: {
          permissions: { clipboardWrite: {} },
          csp: { connectDomains: ["https://grafana.example"] }
        }
      },
      toolInput: { range: "1h" },
      toolResult: { content: [{ type: "text", text: "done" }] }
    })
    expect(loaded.boot?.html).toContain(
      `<head><meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' https://cdn.example;`
    )
    expect(loaded.boot?.html).toContain(alertsHtml.slice(alertsHtml.indexOf("<title>")))
  })

  it("defaults the display and rejects links for other views or without a token", async () => {
    const setup = await secured()
    const viewId = await capturedView(setup)
    const url = await launch(setup, `/v1/plugins/apps/${viewId}/token`)
    const token = new URL(url, setup.server.url).searchParams.get("token")!

    const defaults = await shell(setup, `${url}&displayMode=fullscreen&locale=x`)
    const other = await shell(
      setup,
      `/v1/plugins/apps/0b9a8f8e-5d1c-4f43-9f53-3e1c2c7f2a10?token=${token}`
    )
    const bare = await shell(setup, `/v1/plugins/apps/${viewId}`)

    expect(defaults.boot?.hostContext).toEqual({
      theme: "light",
      displayMode: "fullscreen",
      availableDisplayModes: ["fullscreen"],
      platform: "desktop"
    })
    expect(other.status).toBe(401)
    expect(bare.status).toBe(401)
  })

  it("proxies the app's tool calls and resource reads to its own plugin", async () => {
    const setup = await secured()
    const viewId = await capturedView(setup)
    const { boot } = await shell(setup, await launch(setup, `/v1/plugins/apps/${viewId}/token`))

    const refreshed = await post(setup, boot!.endpoints.toolsCall, {
      name: "refresh",
      arguments: { all: true }
    })
    const modelOnly = await post(setup, boot!.endpoints.toolsCall, { name: "summarize" })
    const read = await post(setup, boot!.endpoints.resourcesRead, { uri: "ui://grafana/data.json" })
    const malformed = await post(setup, boot!.endpoints.toolsCall, { arguments: {} })
    const unknown = await post(setup, boot!.endpoints.resourcesRead, { uri: "ui://grafana/x" })

    expect(refreshed).toEqual({
      status: 200,
      body: {
        content: [{ type: "text", text: "done" }],
        structuredContent: { params: { name: "refresh", arguments: { all: true } } }
      }
    })
    expect(modelOnly.status).toBe(500)
    expect(modelOnly.body).toEqual({ error: "summarize isn't available to this app" })
    expect(read.body).toEqual({
      contents: [{ uri: "ui://grafana/data.json", mimeType: "application/json", text: "{}" }]
    })
    expect(malformed.status).toBe(400)
    expect(unknown.status).toBe(500)
  })
})

describe("Zillow's recorded app", () => {
  it("captures and serves the areas widget with Zillow's own tool data and CSP", async () => {
    const setup = await secured(zillowPlugin(), "Zillow")
    const listed = await jsonRequest(setup.server, "/v1/mcps", { headers: setup.authorized })
    const viewId = await capturedView(
      setup,
      "zillow_city_neighborhood_real_estate_information",
      '{ request: { areaSearchRegionFiltersRequests: [{ name: "Capitol Hill, Seattle, WA" }] } }'
    )

    const loaded = await shell(setup, await launch(setup, `/v1/plugins/apps/${viewId}/token`))

    expect(appTools(listed.body, "Zillow")).toEqual([
      { name: "zillow_property_search", app: true },
      { name: "zillow_city_neighborhood_real_estate_information", app: true },
      { name: "get_zestimate" }
    ])
    expect(loaded.policy).toContain(
      "connect-src 'self' https://www.zillow.com https://mcp.zillow.com"
    )
    expect(loaded.policy).toContain("script-src 'unsafe-inline' https://www.zillowstatic.com")
    expect(loaded.boot?.html).toMatch(/^<meta http-equiv="Content-Security-Policy"/)
    expect(loaded.boot?.html).toContain('<div id="zillow-sub-app-root"></div>')
    expect(loaded.boot?.toolResult).toMatchObject({
      _meta: { "zillow.com/data": { widget: "areas", env: { googleApiKey: "recorded-key" } } }
    })
  })
})

describe("plugin app panes", () => {
  it("serves declared panes from a pane link, without tool data", async () => {
    const setup = await secured()
    const url = await launch(setup, `/v1/plugins/${setup.serverId}/panes/dashboard/token`)

    const loaded = await shell(setup, url)
    const called = await post(setup, loaded.boot!.endpoints.toolsCall, { name: "refresh" })
    const read = await post(setup, loaded.boot!.endpoints.resourcesRead, {
      uri: "ui://grafana/board.html"
    })

    expect(url).toMatch(/^\/v1\/plugins\/panes\/[\w-]+\.[\w-]+\/$/)
    expect(loaded.policy).toContain("connect-src 'self';")
    expect(loaded.boot).not.toHaveProperty("toolInput")
    expect(loaded.boot).toMatchObject({ allow: "", hostContext: { displayMode: "fullscreen" } })
    expect(loaded.boot?.html).toContain(boardHtml)
    expect(called.status).toBe(200)
    expect(read.status).toBe(200)
  })

  it("refuses unknown panes, non-HTML panes, and view links on pane paths", async () => {
    const setup = await secured()
    const viewId = await capturedView(setup)
    const viewToken = new URL(
      await launch(setup, `/v1/plugins/apps/${viewId}/token`),
      setup.server.url
    ).searchParams.get("token")!

    const unknown = await jsonRequest(
      setup.server,
      `/v1/plugins/${setup.serverId}/panes/missing/token`,
      { method: "POST", headers: setup.authorized }
    )
    const broken = await shell(
      setup,
      await launch(setup, `/v1/plugins/${setup.serverId}/panes/broken/token`)
    )
    const crossed = await shell(setup, `/v1/plugins/panes/${viewToken}/`)
    const forged = await shell(setup, "/v1/plugins/panes/forged/")

    expect(unknown).toEqual({ status: 404, body: { error: "No missing pane for this plugin" } })
    expect(broken.status).toBe(502)
    expect(crossed.status).toBe(401)
    expect(forged.status).toBe(401)
  })

  it("leaves other plugin requests to the rest of the router", async () => {
    const setup = await secured()

    const listed = await jsonRequest(setup.server, `/v1/plugins/${setup.serverId}/panes/x/other`, {
      method: "POST",
      headers: setup.authorized
    })
    const fetched = await jsonRequest(setup.server, "/v1/plugins/apps/x/token", {
      headers: setup.authorized
    })

    expect(listed.status).toBe(404)
    expect(fetched.status).toBe(404)
  })
})

describe("plugin apps without MCP", () => {
  it("reports plugins as unavailable", async () => {
    const { services } = await start()
    const { mcp: _mcp, ...withoutMcp } = services
    const server = await startWithApp(withoutMcp)

    const response = await jsonRequest(server, "/v1/plugins/apps/x/token", { method: "POST" })

    expect(response).toEqual({ status: 501, body: { error: "Plugins unavailable" } })
  })
})
