import { createServer } from "node:http"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { boundedMcpTimerDelay, NodeStreamableHttpTransport } from "@codevisor/mcp"
import { Client as McpClient } from "@modelcontextprotocol/sdk/client/index.js"
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js"
import type { Transport as McpTransport } from "@modelcontextprotocol/sdk/shared/transport.js"
import { ToolListChangedNotificationSchema } from "@modelcontextprotocol/sdk/types.js"
import { jsonRequest, start, tempDirs, waitFor } from "../test-support.js"

describe("mcp routes", () => {
  it("bounds long-lived OAuth refresh timers to Node's supported range", () => {
    expect(boundedMcpTimerDelay(2_591_232_324)).toBe(2_147_000_000)
    expect(boundedMcpTimerDelay(3_480_000)).toBe(3_480_000)
  })

  it("loads a large SSE tool catalog without opening the optional notification stream", async () => {
    const receivedHeaders: Array<string | undefined> = []
    const upstream = createServer(async (request, response) => {
      const workspace = request.headers["x-workspace"]
      receivedHeaders.push(Array.isArray(workspace) ? workspace.join(",") : workspace)
      if (request.method === "GET") {
        response.writeHead(500)
        response.end()
        return
      }
      const chunks: Buffer[] = []
      for await (const chunk of request) chunks.push(Buffer.from(chunk))
      const message = JSON.parse(Buffer.concat(chunks).toString("utf8")) as {
        id?: string | number
        method: string
      }
      if (message.method === "notifications/initialized") {
        response.writeHead(202)
        response.end()
        return
      }
      const result =
        message.method === "initialize"
          ? {
              protocolVersion: "2025-11-25",
              capabilities: { tools: { listChanged: true } },
              serverInfo: { name: "large-catalog", version: "1" }
            }
          : {
              tools: [
                {
                  name: "large_tool",
                  description: "x".repeat(30_000),
                  inputSchema: { type: "object" }
                }
              ]
            }
      response.writeHead(200, { "content-type": "text/event-stream" })
      response.end(
        `event: message\ndata: ${JSON.stringify({ jsonrpc: "2.0", id: message.id, result })}\n\n`
      )
    })
    await new Promise<void>((resolve) => upstream.listen(0, "127.0.0.1", resolve))
    const address = upstream.address()
    if (address === null || typeof address === "string") throw new Error("Missing upstream port")
    const transport = new NodeStreamableHttpTransport(
      new URL(`http://127.0.0.1:${address.port}/mcp`),
      undefined,
      { "X-Workspace": "emojis" }
    )
    const client = new McpClient({ name: "node-transport-test", version: "1" })
    try {
      await client.connect(transport)
      expect((await client.listTools()).tools).toHaveLength(1)
      expect(receivedHeaders).not.toContain(undefined)
      expect(receivedHeaders).toContain("emojis")
    } finally {
      await client.close()
      await new Promise<void>((resolve, reject) =>
        upstream.close((error) => (error === undefined ? resolve() : reject(error)))
      )
    }
  })

  it("serves the fixed session-scoped MCP gateway surface", async () => {
    const { server, services } = await start()
    await services.mcp.create({
      authType: "none",
      command: "codevisor-missing-posthog-mcp",
      name: "PostHog",
      transport: "stdio"
    })
    const firstGateway = await services.mcp.issueGateway("session-1")
    const gateway = await services.mcp.issueGateway("session-1")
    const otherSessionGateway = await services.mcp.issueGateway("session-2")
    expect(gateway).toEqual(firstGateway)
    expect(otherSessionGateway.bearerToken).toBe(gateway.bearerToken)
    expect(otherSessionGateway.url).not.toBe(gateway.url)
    const client = new McpClient({ name: "gateway-test", version: "1" })
    await client.connect(
      new StreamableHTTPClientTransport(new URL(gateway.url), {
        requestInit: { headers: { Authorization: `Bearer ${gateway.bearerToken}` } }
      }) as unknown as McpTransport
    )
    const listed = await client.listTools()
    expect(listed.tools.map((tool) => tool.name)).toEqual(["execute"])
    expect(listed.tools.find((tool) => tool.name === "execute")?.description).toContain("PostHog")
    expect(listed.tools.find((tool) => tool.name === "execute")?.description).toContain(
      "Primary Codevisor tool interface"
    )
    let toolListChanges = 0
    client.setNotificationHandler(ToolListChangedNotificationSchema, () => {
      toolListChanges += 1
    })
    await services.mcp.create({
      authType: "none",
      command: "codevisor-missing-linear-mcp",
      name: "Linear",
      transport: "stdio"
    })
    await waitFor(() => toolListChanges > 0)
    expect(
      (await client.listTools()).tools.find((tool) => tool.name === "execute")?.description
    ).toContain("Linear")
    const executed = await client.callTool({
      name: "execute",
      arguments: { code: "async () => 6 * 7" }
    })
    expect(executed.isError).not.toBe(true)
    expect(JSON.stringify(executed.content)).toContain("42")
    const searchedInCode = await client.callTool({
      name: "execute",
      arguments: { code: 'async () => await tools.search({ query: "missing" })' }
    })
    expect(searchedInCode.isError).not.toBe(true)
    expect(JSON.stringify(searchedInCode.content)).toContain('\\"total\\":0')
    const codevisorSearch = await client.callTool({
      name: "execute",
      arguments: { code: 'async () => await tools.search({ query: "Codevisor sessions" })' }
    })
    expect(codevisorSearch.isError).not.toBe(true)
    expect(JSON.stringify(codevisorSearch.content)).toContain("codevisor.sessions.list")
    const codevisorProjects = await client.callTool({
      name: "execute",
      arguments: { code: 'async () => await tools["codevisor.projects.list"]({})' }
    })
    expect(codevisorProjects.isError).not.toBe(true)
    expect(JSON.stringify(codevisorProjects.content)).toContain('\\"result\\":[]')
    const controlledFolder = mkdtempSync(join(tmpdir(), "codevisor-mcp-control-"))
    tempDirs.push(controlledFolder)
    const controlled = await client.callTool({
      name: "execute",
      arguments: {
        code: `async () => {
          const project = await tools["codevisor.projects.create"]({
            id: "controlled-project",
            folderPath: ${JSON.stringify(controlledFolder)},
            name: "Controlled"
          });
          const workspace = await tools["codevisor.workspaces.upsert"]({
            workspaceId: "controlled-workspace",
            projectId: project.id,
            name: "Controlled workspace",
            hasCustomName: true
          });
          const session = await tools["codevisor.sessions.create"]({
            id: "controlled-session",
            projectId: project.id,
            workspaceId: workspace.id,
            harnessId: "codex",
            deferAgentSession: true
          });
          return { projectId: project.id, workspaceId: workspace.id, sessionId: session.id };
        }`
      }
    })
    expect(controlled.isError).not.toBe(true)
    expect(JSON.stringify(controlled.content)).toContain("controlled-session")
    expect(await jsonRequest(server, "/v1/sessions/controlled-session")).toMatchObject({
      status: 200,
      body: {
        session: {
          projectId: "controlled-project",
          workspaceId: "controlled-workspace"
        }
      }
    })
    const codevisorTools = await services.mcp.tools("codevisor")
    expect(codevisorTools.map((tool) => tool.name)).toEqual(
      expect.arrayContaining([
        "projects.create",
        "workspaces.upsert",
        "sessions.create",
        "sessions.prompt",
        "mcps.create",
        "skills.create",
        "harnesses.list",
        "machines.cloud_status"
      ])
    )
    await client.close()

    const unauthorized = await fetch(`${server.url}/mcp/gateway`, { method: "POST" })
    expect(unauthorized.status).toBe(401)
  })

  it("authenticates Codevisor control tools against token-protected server routes", async () => {
    const { services } = await start({
      allowLocalhostWithoutAuth: false,
      requireBearerToken: true
    })
    const gateway = await services.mcp.issueGateway("protected-session")
    const client = new McpClient({ name: "protected-gateway-test", version: "1" })
    await client.connect(
      new StreamableHTTPClientTransport(new URL(gateway.url), {
        requestInit: { headers: { Authorization: `Bearer ${gateway.bearerToken}` } }
      }) as unknown as McpTransport
    )
    const result = await client.callTool({
      name: "execute",
      arguments: { code: 'async () => await tools["codevisor.projects.list"]({})' }
    })
    expect(result.isError).not.toBe(true)
    expect(JSON.stringify(result.content)).toContain('\\"result\\":[]')
    await client.close()
  })
})
