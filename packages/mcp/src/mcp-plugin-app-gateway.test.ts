import type { RuntimeEvent } from "@codevisor/agent-runtime"
import { afterEach, describe, expect, it } from "vitest"
import { z } from "zod"

import {
  cleanupMcpManagerTests,
  executeResultValue,
  executionOf
} from "./mcp-manager-test-support.js"
import type { PluginAccountSource } from "./mcp-plugin-accounts.js"
import {
  closeFakePlugins,
  pluginGatewaySession,
  type FakePluginOptions,
  type FakeRequest
} from "./mcp-plugin-test-support.js"

afterEach(async () => {
  await closeFakePlugins()
  await cleanupMcpManagerTests()
})

const appPlugin: FakePluginOptions = {
  tools: [
    {
      name: "show_alerts",
      inputSchema: { type: "object", properties: { range: { type: "string" } } },
      _meta: { ui: { resourceUri: "ui://grafana/alerts.html" } }
    },
    {
      name: "refresh_alerts",
      inputSchema: { type: "object" },
      _meta: { ui: { visibility: ["app"] } }
    },
    {
      name: "summarize",
      inputSchema: { type: "object" },
      _meta: { ui: { visibility: ["model"] } }
    }
  ]
}

const accountSource = (labels: ReadonlyArray<string>): PluginAccountSource => ({
  list: async () => labels.map((label) => ({ id: `id-${label}`, label })),
  meta: async (_serverId, accountId) => ({ id: accountId })
})

const ExecutionAppsSchema = z.object({
  apps: z
    .array(
      z.object({
        viewId: z.string(),
        machineId: z.string(),
        serverId: z.string(),
        serverName: z.string(),
        toolName: z.string(),
        resourceUri: z.string()
      })
    )
    .optional()
})

const toolCalls = (requests: ReadonlyArray<FakeRequest>) =>
  requests.filter((request) => request.method === "tools/call").map((request) => request.params)

describe("plugin app views", () => {
  it("records a view for app tool calls and lists it on the execution", async () => {
    const events: Array<RuntimeEvent> = []
    const { client, execute, manager, server, session } = await pluginGatewaySession(
      appPlugin,
      accountSource(["work", "home"]),
      (event) => void events.push(event)
    )
    const path = JSON.stringify(`${server.id}.show_alerts`)

    await execute(`async () => machines.current.tools[${path}]({ range: "1h", account: "home" })`)

    const finished = ExecutionAppsSchema.parse(executionOf(events.at(-1)!))
    const [app] = finished.apps ?? []
    expect(app).toEqual({
      viewId: expect.stringMatching(/^[0-9a-f-]{36}$/),
      machineId: "local",
      serverId: server.id,
      serverName: "Grafana",
      toolName: "show_alerts",
      resourceUri: "ui://grafana/alerts.html"
    })
    expect(await manager.appView(app!.viewId)).toEqual({
      ...app,
      sessionId: session.id,
      accountId: "id-home",
      toolInput: { range: "1h" },
      toolResult: {
        content: [
          {
            type: "text",
            text: JSON.stringify({
              _meta: { "dev.codevisor/account": { id: "id-home" } },
              name: "show_alerts",
              arguments: { range: "1h" }
            })
          }
        ]
      },
      createdAt: expect.any(String)
    })
    await client.close()
  })

  it("records no view for plain tools", async () => {
    const events: Array<RuntimeEvent> = []
    const { client, execute, server } = await pluginGatewaySession(
      appPlugin,
      undefined,
      (event) => void events.push(event)
    )

    await execute(
      `async () => machines.current.tools[${JSON.stringify(`${server.id}.summarize`)}]({})`
    )

    expect(ExecutionAppsSchema.parse(executionOf(events.at(-1)!)).apps).toBeUndefined()
    await client.close()
  })

  it("keeps app-only tools away from the model", async () => {
    const { client, execute, plugin, server } = await pluginGatewaySession(appPlugin)
    const path = JSON.stringify(`${server.id}.refresh_alerts`)

    const searched = JSON.stringify(
      executeResultValue(
        await execute(`async () => machines.current.tools.search({ query: "alerts" })`)
      )
    )
    const called = JSON.stringify(await execute(`async () => machines.current.tools[${path}]({})`))

    expect(searched).toContain("show_alerts")
    expect(searched).not.toContain("refresh_alerts")
    expect(called).toContain("is only available to the Grafana app")
    expect(toolCalls(plugin.requests)).toEqual([])
    await client.close()
  })

  it("lets apps call their plugin's app tools with the view's account", async () => {
    const { client, manager, plugin, server } = await pluginGatewaySession(
      appPlugin,
      accountSource(["work", "home"])
    )

    const result = await manager.callAppTool(server.id, "refresh_alerts", { all: true }, "id-home")

    expect(result.content).toHaveLength(1)
    expect(toolCalls(plugin.requests)).toEqual([
      {
        name: "refresh_alerts",
        arguments: { all: true },
        _meta: { "dev.codevisor/account": { id: "id-home" } }
      }
    ])
    await expect(manager.callAppTool(server.id, "summarize", {})).rejects.toThrow(
      "summarize isn't available to this app"
    )
    await expect(manager.callAppTool(server.id, "missing", {})).rejects.toThrow(
      "missing isn't available to this app"
    )
    await client.close()
  })

  it("calls app tools without account context when the plugin has no accounts", async () => {
    const { client, manager, plugin, server } = await pluginGatewaySession(appPlugin)

    await manager.callAppTool(server.id, "refresh_alerts", {})

    expect(toolCalls(plugin.requests)).toEqual([{ name: "refresh_alerts", arguments: {} }])
    await client.close()
  })
})
