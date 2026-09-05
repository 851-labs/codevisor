import { ToolListChangedNotificationSchema } from "@modelcontextprotocol/sdk/types.js"
import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import { createServer } from "node:http"
import { afterEach, describe, expect, it } from "vitest"
import {
  cleanupMcpManagerTests,
  run,
  listen,
  testManager,
  workingUpstream
} from "./mcp-manager-test-support.js"

afterEach(cleanupMcpManagerTests)

describe("MCP manager gateway", () => {
  it("accepts harness redials: fresh initialize handshakes reuse the same gateway", async () => {
    // codex 0.145+ tears down and re-initializes its MCP connections on
    // mid-session events. The gateway must accept the redial instead of
    // rejecting the second initialize (the pre-fix behavior, which made the
    // harness silently drop every gateway tool).
    const upstream = await workingUpstream()
    const { db, manager } = await testManager()
    const gatewayBase = await listen(createServer(manager.handleGatewayRequest))
    manager.setBaseUrl(gatewayBase)
    const created = await manager.create({
      authType: "none",
      enabled: true,
      name: "Redial Tracker",
      transport: "http",
      url: upstream.url
    })
    const project = await run(db.createProject({ folderPath: "/tmp/mcp-manager-redial" }))
    const session = await run(
      db.createSession({ harnessId: "codex", projectId: project.id, title: "Redial" })
    )
    const issued = await manager.issueGateway(session.id, project.id)
    const authorization = { authorization: `Bearer ${issued.bearerToken}` }

    const connect = async () => {
      const transport = new StreamableHTTPClientTransport(new URL(issued.url), {
        requestInit: { headers: authorization }
      })
      const client = new Client({ name: "redial-test", version: "1" })
      await client.connect(transport as unknown as Transport)
      return { client, transport }
    }

    const first = await connect()
    try {
      expect(
        JSON.stringify(
          (
            await first.client.callTool({
              name: "execute",
              arguments: { code: 'async () => tools.search({ query: "project" })' }
            })
          ).content
        )
      ).toContain("lookup_project")

      // The redial: a brand-new initialize against the same gateway URL.
      const second = await connect()
      try {
        expect(
          JSON.stringify(
            (
              await second.client.callTool({
                name: "execute",
                arguments: { code: 'async () => tools.search({ query: "issues" })' }
              })
            ).content
          )
        ).toContain("list_issues")
        // The first connection keeps working alongside the second.
        expect(
          (
            await first.client.callTool({
              name: "execute",
              arguments: { code: 'async () => tools.search({ query: "project" })' }
            })
          ).isError
        ).not.toBe(true)

        // Terminating one MCP session leaves the other connected and makes
        // the terminated session id unknown to the gateway.
        const secondSessionId = second.transport.sessionId
        await second.transport.terminateSession()
        expect(
          await fetch(issued.url, {
            method: "POST",
            headers: {
              ...authorization,
              "content-type": "application/json",
              "mcp-session-id": secondSessionId ?? ""
            },
            body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" })
          }).then((response) => response.status)
        ).toBe(404)
        expect(
          (
            await first.client.callTool({
              name: "execute",
              arguments: { code: 'async () => tools.search({ query: "project" })' }
            })
          ).isError
        ).not.toBe(true)
      } finally {
        await second.client.close().catch(() => undefined)
      }

      // Session-less requests that are not an initialize are rejected.
      expect(
        await fetch(issued.url, { method: "GET", headers: authorization }).then(
          (response) => response.status
        )
      ).toBe(405)
      expect(
        await fetch(issued.url, {
          method: "POST",
          headers: { ...authorization, "content-type": "application/json" },
          body: "{ not json"
        }).then((response) => response.status)
      ).toBe(400)
      expect(
        await fetch(issued.url, {
          method: "POST",
          headers: { ...authorization, "content-type": "application/json" },
          body: JSON.stringify({ jsonrpc: "2.0", id: 2, method: "tools/list" })
        }).then((response) => response.status)
      ).toBe(400)
      // Batches count as an initialize when any entry is one.
      expect(
        await fetch(issued.url, {
          method: "POST",
          headers: {
            ...authorization,
            accept: "application/json, text/event-stream",
            "content-type": "application/json"
          },
          body: JSON.stringify([
            {
              jsonrpc: "2.0",
              id: 3,
              method: "initialize",
              params: {
                protocolVersion: "2025-03-26",
                capabilities: {},
                clientInfo: { name: "batch", version: "1" }
              }
            }
          ])
        }).then((response) => response.status)
      ).not.toBe(400)
      void created
    } finally {
      await first.client.close().catch(() => undefined)
    }
  })

  // Same real-HTTP gateway harness as the upstream test above; the plugin
  // tool source is the structural seam the server wires the plugins manager
  // into.

  it(
    "exposes plugin tools through the gateway and refreshes on installed-set changes",
    { timeout: 20_000 },
    async () => {
      const listeners: Array<() => void> = []
      let installedTools: Array<{
        pluginId: string
        name: string
        description: string
        inputSchema?: unknown
      }> = [
        {
          pluginId: "owner.notes",
          name: "notes_add",
          description: "Append a note",
          inputSchema: {
            type: "object",
            properties: { text: { type: "string" } },
            required: ["text"]
          }
        }
      ]
      const invocations: Array<ReadonlyArray<unknown>> = []
      const { db, manager } = await testManager(undefined, {
        pluginTools: {
          listTools: async () => installedTools,
          invokeTool: async (pluginId, toolName, args, context) => {
            invocations.push([pluginId, toolName, args, context])
            return { ok: true, tool: toolName }
          },
          subscribeInstalled: (listener) => {
            listeners.push(listener)
            return () => listeners.splice(0)
          }
        }
      })
      const gatewayBase = await listen(createServer(manager.handleGatewayRequest))
      manager.setBaseUrl(gatewayBase)
      const project = await run(db.createProject({ folderPath: "/tmp/mcp-plugin-project" }))
      const session = await run(
        db.createSession({ harnessId: "codex", projectId: project.id, title: "Plugin tools" })
      )
      const sessionCwd = (await run(db.getSessionSummary(session.id))).cwd
      const issued = await manager.issueGateway(session.id, project.id)
      const client = new Client({ name: "plugin-tools-test", version: "1" })
      await client.connect(
        new StreamableHTTPClientTransport(new URL(issued.url), {
          requestInit: { headers: { authorization: `Bearer ${issued.bearerToken}` } }
        }) as unknown as Transport
      )
      try {
        // The advertised inventory names the plugin tool path outright, so
        // agents can call it without a search round-trip.
        const advertised = (await client.listTools()).tools.find((tool) => tool.name === "execute")
        expect(advertised?.description).toContain("plugin.owner.notes.notes_add — Append a note")

        const viaCode = await client.callTool({
          name: "execute",
          arguments: {
            code: `async () => {
            const matches = await tools.search({ query: "note", limit: 5 });
            const path = matches.items[0].path;
            const schema = await tools.describe.tool({ path });
            const result = await tools[path]({ text: "from code" });
            return { matches, result, schema };
          }`
          }
        })
        expect(viaCode.isError).not.toBe(true)
        expect(JSON.stringify(viaCode.content)).toContain("plugin.owner.notes.notes_add")
        expect(JSON.stringify(viaCode.content)).toContain("Append a note")
        expect(JSON.stringify(viaCode.content)).toContain('\\"ok\\":true')
        expect(invocations.at(-1)).toEqual([
          "owner.notes",
          "notes_add",
          { text: "from code" },
          sessionCwd === undefined ? {} : { cwd: sessionCwd }
        ])

        // Remainders that cannot split into <pluginId>.<toolName> are refused.
        expect(
          (
            await client.callTool({
              name: "execute",
              arguments: { code: `async () => tools["plugin.owner.notes."]({})` }
            })
          ).isError
        ).toBe(true)
        expect(
          (
            await client.callTool({
              name: "execute",
              arguments: {
                code: `async () => tools.describe.tool({ path: "plugin.owner.notes.missing" })`
              }
            })
          ).isError
        ).toBe(true)

        // An install changes the set: the subscription refreshes the
        // advertised inventory on every live connection.
        const inventoryChanged = Promise.withResolvers<void>()
        client.setNotificationHandler(ToolListChangedNotificationSchema, () => {
          inventoryChanged.resolve()
        })
        installedTools = [
          ...installedTools,
          { pluginId: "owner.notes", name: "notes_list", description: "List notes" }
        ]
        for (const listener of listeners) listener()
        await inventoryChanged.promise
        const refreshed = (await client.listTools()).tools.find((tool) => tool.name === "execute")
        expect(refreshed?.description).toContain("plugin.owner.notes.notes_list — List notes")
      } finally {
        await client.close()
      }
    }
  )

  it("refuses plugin tool calls when no plugin source is wired", async () => {
    const { db, manager } = await testManager()
    const gatewayBase = await listen(createServer(manager.handleGatewayRequest))
    manager.setBaseUrl(gatewayBase)
    const project = await run(db.createProject({ folderPath: "/tmp/mcp-no-plugins" }))
    const session = await run(
      db.createSession({ harnessId: "codex", projectId: project.id, title: "No plugins" })
    )
    const issued = await manager.issueGateway(session.id, project.id)
    const client = new Client({ name: "no-plugins-test", version: "1" })
    await client.connect(
      new StreamableHTTPClientTransport(new URL(issued.url), {
        requestInit: { headers: { authorization: `Bearer ${issued.bearerToken}` } }
      }) as unknown as Transport
    )
    try {
      const executed = await client.callTool({
        name: "execute",
        arguments: { code: 'async () => tools["plugin.owner.notes.notes_add"]({})' }
      })
      expect(executed.isError).toBe(true)
      expect(JSON.stringify(executed.content)).toContain("unavailable on this server")
      const described = await client.callTool({
        name: "execute",
        arguments: {
          code: 'async () => tools.describe.tool({ path: "plugin.owner.notes.notes_add" })'
        }
      })
      expect(described.isError).toBe(true)
      expect(JSON.stringify(described.content)).toContain("Tool not found")
    } finally {
      await client.close()
    }
  })
})
