import { afterEach, describe, expect, it } from "vitest"

import { cleanupMcpManagerTests, testManager } from "./mcp-manager-test-support.js"
import type { PluginAccountSource } from "./mcp-plugin-accounts.js"
import {
  closeFakePlugins,
  pluginExtensions,
  startFakePlugin,
  SUBSCRIPTION_ID,
  type FakePluginOptions
} from "./mcp-plugin-test-support.js"

afterEach(async () => {
  await closeFakePlugins()
  await cleanupMcpManagerTests()
})

const accountSource = (labels: ReadonlyArray<string>): PluginAccountSource => ({
  list: async () => labels.map((label) => ({ id: `id-${label}`, label })),
  meta: async (_serverId, accountId) => ({ id: accountId, accessToken: `token-${accountId}` })
})

const installedPlugin = async (options: FakePluginOptions = {}, accounts?: PluginAccountSource) => {
  const plugin = await startFakePlugin(options)
  const { manager } = await testManager(accounts === undefined ? {} : { accounts })
  const server = await manager.create({
    authType: "none",
    enabled: true,
    name: "Grafana",
    transport: "http",
    url: plugin.url
  })
  return { manager, plugin, server }
}

const methods = (requests: ReadonlyArray<{ readonly method: string }>) =>
  requests.map((request) => request.method)

describe("plugin connections", () => {
  it("declares the plugin extensions and saves the capability digest on connect", async () => {
    const { manager, plugin, server } = await installedPlugin({
      tools: [
        {
          name: "show_alerts",
          description: "Chart the alerts",
          inputSchema: { type: "object" },
          annotations: { readOnlyHint: true },
          _meta: { ui: { resourceUri: "ui://grafana/alerts.html" } }
        },
        {
          name: "silence",
          inputSchema: { type: "object" },
          annotations: { openWorldHint: true }
        },
        { name: "annotate", inputSchema: { type: "object" }, annotations: {} },
        {
          name: "search_homes",
          inputSchema: { type: "object" },
          _meta: { "openai/outputTemplate": "ui://widget/zillow-property-search.html" }
        },
        { name: "plain", inputSchema: { type: "object" } }
      ]
    })

    await manager.connect(server.id)

    expect(plugin.clientCapabilities()?.extensions).toEqual({
      "io.modelcontextprotocol/events": {},
      "io.modelcontextprotocol/skills": {},
      "io.modelcontextprotocol/ui": { mimeTypes: ["text/html;profile=mcp-app"] },
      "dev.codevisor/panes": {},
      "dev.codevisor/webhooks": {}
    })
    const saved = (await manager.list()).find((candidate) => candidate.id === server.id)
    expect(saved?.capabilities).toEqual({
      tools: [
        { name: "show_alerts", description: "Chart the alerts", effects: "read", app: true },
        { name: "silence", effects: "external-write" },
        { name: "annotate", effects: "write" },
        { name: "search_homes", app: true },
        { name: "plain" }
      ],
      events: [
        { name: "alert.firing", description: "An alert started firing" },
        { name: "alert.resolved" }
      ],
      skills: [],
      panes: [{ type: "dashboard", title: "Alerts", resourceUri: "ui://grafana/alerts.html" }],
      ingress: [{ name: "alerts", title: "Grafana alert webhook" }, { name: "raw" }]
    })
  })

  it("keeps empty lists for servers that fail or skip the extension methods", async () => {
    const failing = await installedPlugin({
      failing: new Set(["events/list", "skills/list"])
    })
    await failing.manager.connect(failing.server.id)
    expect(
      (await failing.manager.list()).find((row) => row.id === failing.server.id)?.capabilities
    ).toMatchObject({ events: [], skills: [] })

    const bare = await installedPlugin({ capabilities: { tools: {} } })
    await bare.manager.connect(bare.server.id)
    expect(new Set(methods(bare.plugin.requests))).toEqual(new Set(["tools/list"]))
    expect(
      (await bare.manager.list()).find((row) => row.id === bare.server.id)?.capabilities
    ).toEqual({ tools: [], events: [], skills: [], panes: [], ingress: [] })
    expect((await bare.manager.pluginConnection(bare.server.id)).extensions).toEqual({})
  })

  it("sends requests and notifications with the chosen account's context", async () => {
    const { manager, plugin, server } = await installedPlugin({}, accountSource(["work", "home"]))
    const connection = await manager.pluginConnection(server.id)

    expect(connection).toMatchObject({ serverId: server.id, name: "Grafana" })
    expect(connection.extensions["dev.codevisor/panes"]).toEqual(
      pluginExtensions.extensions?.["dev.codevisor/panes"]
    )
    await connection.request("events/list", { cursor: "second" }, { accountId: "id-home" })
    await connection.request("events/list", { _meta: { trace: "t1" } }, { timeoutMs: 5_000 })
    await connection.notify("notifications/test/ping", { at: 1 })

    expect(plugin.requests.slice(-2).map((request) => request.params)).toEqual([
      {
        cursor: "second",
        _meta: { "dev.codevisor/account": { id: "id-home", accessToken: "token-id-home" } }
      },
      {
        _meta: {
          trace: "t1",
          "dev.codevisor/account": { id: "id-work", accessToken: "token-id-work" }
        }
      }
    ])
    expect(plugin.notifications).toContainEqual({
      method: "notifications/test/ping",
      params: { at: 1 }
    })
  })

  it("leaves account context out when the plugin has no accounts", async () => {
    const withoutSource = await installedPlugin()
    await (
      await withoutSource.manager.pluginConnection(withoutSource.server.id)
    ).request("events/list", {})
    expect(withoutSource.plugin.requests.at(-1)?.params).toEqual({})

    const noAccounts = await installedPlugin({}, accountSource([]))
    await (
      await noAccounts.manager.pluginConnection(noAccounts.server.id)
    ).request("events/list", {})
    expect(noAccounts.plugin.requests.at(-1)?.params).toEqual({})

    const noContext = await installedPlugin(
      {},
      { list: async () => [{ id: "a", label: "A" }], meta: async () => undefined }
    )
    await (await noContext.manager.pluginConnection(noContext.server.id)).request("events/list", {})
    expect(noContext.plugin.requests.at(-1)?.params).toEqual({})
  })

  it("delivers notifications to listeners until they unsubscribe", async () => {
    const { manager, server } = await installedPlugin()
    const connection = await manager.pluginConnection(server.id)
    const received: Array<Record<string, unknown>> = []
    const stop = connection.onNotification("notifications/events/list_changed", (params) =>
      received.push(params)
    )

    await connection.request("test/announce", {
      method: "notifications/events/list_changed",
      values: { round: 1 }
    })
    await connection.request(
      "test/announce",
      { method: "notifications/events/list_changed" },
      { signal: new AbortController().signal }
    )
    stop()
    await connection.request("test/announce", {
      method: "notifications/events/list_changed",
      values: { round: 2 }
    })

    expect(received).toEqual([{ round: 1 }, {}])
  })

  it("reads resources with account context", async () => {
    const { manager, plugin, server } = await installedPlugin(
      {
        resources: { "ui://grafana/alerts.html": { text: "<p>alerts</p>", mimeType: "text/html" } }
      },
      accountSource(["work"])
    )

    const result = await manager.readResource(server.id, "ui://grafana/alerts.html")

    expect(result.contents).toEqual([
      { uri: "ui://grafana/alerts.html", mimeType: "text/html", text: "<p>alerts</p>" }
    ])
    expect(plugin.requests.at(-1)?.params._meta).toEqual({
      "dev.codevisor/account": { id: "id-work", accessToken: "token-id-work" }
    })
  })

  it("reports connections opening and closing", async () => {
    const { manager, server } = await installedPlugin()
    const changes: Array<string> = []
    const stop = manager.subscribeConnections((id, state) => changes.push(`${id}:${state}`))

    await manager.connect(server.id)
    stop()
    await manager.connect(server.id)

    expect(changes).toEqual([`${server.id}:closed`, `${server.id}:connected`])
  })
})

describe("plugin event streams", () => {
  it("routes each stream's notifications to it and resolves when the server ends it", async () => {
    const { manager, plugin, server } = await installedPlugin({}, accountSource(["work"]))
    const connection = await manager.pluginConnection(server.id)
    const firstSeen: Array<string> = []
    const secondSeen: Array<string> = []

    const first = connection.openStream(
      "events/stream",
      { name: "alert.firing" },
      {
        signal: new AbortController().signal,
        onNotification: (method, params) => firstSeen.push(`${method}:${String(params.n)}`)
      }
    )
    const firstStream = await plugin.nextStream()
    const second = connection.openStream(
      "events/stream",
      { name: "alert.resolved" },
      {
        signal: new AbortController().signal,
        onNotification: (method, params) => secondSeen.push(`${method}:${String(params.n)}`)
      }
    )
    const secondStream = await plugin.nextStream()

    await firstStream.notify("notifications/events/active", { n: 1 })
    await secondStream.notify("notifications/events/event", { n: 2 })
    await firstStream.notify("notifications/events/heartbeat", { n: 3 })
    await connection.request("test/announce", {
      method: "notifications/events/event",
      values: { n: 4, _meta: { [SUBSCRIPTION_ID]: "someone-else" } }
    })
    await connection.request("test/announce", {
      method: "notifications/events/event",
      values: { n: 5, _meta: { [SUBSCRIPTION_ID]: { id: firstStream.id } } }
    })
    firstStream.end({ resultType: "complete", _meta: { [SUBSCRIPTION_ID]: firstStream.id } })
    secondStream.end({ resultType: "complete" })

    expect(await first).toEqual({
      resultType: "complete",
      _meta: { [SUBSCRIPTION_ID]: firstStream.id }
    })
    expect(await second).toEqual({ resultType: "complete" })
    expect(firstSeen).toEqual(["notifications/events/active:1", "notifications/events/heartbeat:3"])
    expect(secondSeen).toEqual(["notifications/events/event:2"])
    expect(firstStream.params).toEqual({
      name: "alert.firing",
      _meta: { "dev.codevisor/account": { id: "id-work", accessToken: "token-id-work" } }
    })
  })

  it("cancels the request and drops its HTTP response when aborted", async () => {
    const { manager, plugin, server } = await installedPlugin()
    const connection = await manager.pluginConnection(server.id)
    const controller = new AbortController()
    const stream = connection.openStream(
      "events/stream",
      {},
      {
        signal: controller.signal,
        onNotification: () => undefined
      }
    )
    const opened = await plugin.nextStream()

    controller.abort()

    await expect(stream).rejects.toMatchObject({ name: "AbortError" })
    await opened.cancelled
    await opened.responseClosed
  })

  it("rejects with an AbortError whatever the abort reason", async () => {
    const { manager, plugin, server } = await installedPlugin()
    const connection = await manager.pluginConnection(server.id)
    const controller = new AbortController()
    const stream = connection.openStream(
      "events/stream",
      {},
      {
        signal: controller.signal,
        onNotification: () => undefined
      }
    )
    await plugin.nextStream()

    controller.abort(new Error("subscription removed"))

    await expect(stream).rejects.toMatchObject({
      name: "AbortError",
      message: "The stream was cancelled"
    })
    await expect(
      connection.openStream(
        "events/stream",
        {},
        {
          signal: AbortSignal.abort(),
          onNotification: () => undefined
        }
      )
    ).rejects.toMatchObject({ name: "AbortError" })
  })

  it("passes on failures that aren't cancellations", async () => {
    const { manager, server } = await installedPlugin({ failing: new Set(["events/stream"]) })
    const connection = await manager.pluginConnection(server.id)

    await expect(
      connection.openStream(
        "events/stream",
        {},
        {
          signal: new AbortController().signal,
          onNotification: () => undefined
        }
      )
    ).rejects.toThrow("events/stream failed")

    await manager.close()
    await expect(
      connection.openStream(
        "events/stream",
        {},
        {
          signal: new AbortController().signal,
          onNotification: () => undefined
        }
      )
    ).rejects.toThrow("Not connected")
  })
})
