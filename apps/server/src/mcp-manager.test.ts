import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import { makeDatabase, type HerdManDatabaseService } from "@herdman/db"
import { Effect } from "effect"
import { createServer, type Server } from "node:http"
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it, vi } from "vitest"
import { makeMcpManager, NodeStreamableHttpTransport, type McpManager } from "./mcp-manager.js"

const run = <A, E>(effect: Effect.Effect<A, E>): Promise<A> => Effect.runPromise(effect)

const directories: string[] = []
const databases: HerdManDatabaseService[] = []
const managers: McpManager[] = []
const servers: Server[] = []

afterEach(async () => {
  vi.restoreAllMocks()
  vi.unstubAllGlobals()
  vi.unstubAllEnvs()
  await Promise.all(managers.splice(0).map((manager) => manager.close()))
  await Promise.all(databases.splice(0).map((database) => run(database.close)))
  await Promise.all(
    servers
      .splice(0)
      .map(
        (server) =>
          new Promise<void>((resolve, reject) =>
            server.close((error) => (error === undefined ? resolve() : reject(error)))
          )
      )
  )
  for (const directory of directories.splice(0)) {
    rmSync(directory, { force: true, recursive: true })
  }
})

const listen = async (server: Server): Promise<string> => {
  servers.push(server)
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  const address = server.address()
  if (address === null || typeof address === "string") throw new Error("Missing test port")
  return `http://127.0.0.1:${address.port}`
}

const testManager = async (): Promise<{ db: HerdManDatabaseService; manager: McpManager }> => {
  const directory = mkdtempSync(join(tmpdir(), "herdman-mcp-manager-"))
  directories.push(directory)
  const db = await run(
    makeDatabase({ filename: join(directory, "herdman.sqlite"), serverId: "test" })
  )
  databases.push(db)
  const manager = makeMcpManager({ db, dataDir: directory })
  managers.push(manager)
  return { db, manager }
}

const workingUpstream = async () => {
  const requests: Array<{
    headers: Record<string, string | string[] | undefined>
    method: string
  }> = []
  const calls: Array<{ name: string; arguments?: Record<string, unknown> }> = []
  const server = createServer(async (request, response) => {
    const chunks: Buffer[] = []
    for await (const chunk of request) chunks.push(Buffer.from(chunk))
    const message = JSON.parse(Buffer.concat(chunks).toString("utf8")) as {
      id?: string | number
      method: string
      params?: Record<string, unknown>
    }
    requests.push({ headers: request.headers, method: message.method })
    if (message.method === "notifications/initialized") {
      response.writeHead(202)
      response.end()
      return
    }
    let result: unknown
    if (message.method === "initialize") {
      result = {
        protocolVersion: "2025-11-25",
        capabilities: { tools: {} },
        serverInfo: { name: "working-upstream", version: "1" }
      }
    } else if (message.method === "tools/list") {
      const cursor = (message.params as { cursor?: string } | undefined)?.cursor
      result =
        cursor === undefined
          ? {
              nextCursor: "page-2",
              tools: [
                {
                  name: "lookup_project",
                  title: "Look up project",
                  description: "Find a project by name",
                  inputSchema: {
                    type: "object",
                    properties: { name: { type: "string" } },
                    required: ["name"]
                  }
                }
              ]
            }
          : {
              tools: [
                {
                  name: "list_issues",
                  inputSchema: { type: "object", properties: {} }
                }
              ]
            }
    } else if (message.method === "tools/call") {
      const params = message.params as {
        name: string
        arguments?: Record<string, unknown>
      }
      calls.push(params)
      result = { content: [{ type: "text", text: JSON.stringify(params) }] }
    } else {
      response.writeHead(400, { "content-type": "text/plain" })
      response.end("unexpected method")
      return
    }
    response.writeHead(200, {
      "content-type": "application/json",
      "mcp-session-id": "upstream-session"
    })
    response.end(JSON.stringify({ jsonrpc: "2.0", id: message.id, result }))
  })
  return { calls, requests, url: `${await listen(server)}/mcp` }
}

describe("MCP manager", () => {
  it("handles the Streamable HTTP response variants and transport lifecycle", async () => {
    const responses = [
      new Response(
        JSON.stringify([
          { jsonrpc: "2.0", id: 1, result: {} },
          { jsonrpc: "2.0", method: "notifications/tools/list_changed" }
        ]),
        {
          headers: { "content-type": "application/json", "mcp-session-id": "session-1" }
        }
      ),
      new Response(null, { status: 202 }),
      new Response("upstream failed", { status: 500, statusText: "Failure" }),
      new Response("unexpected", { headers: { "content-type": "text/plain" } }),
      new Response("missing content type"),
      new Response(
        `event: message\ndata: ${JSON.stringify({ jsonrpc: "2.0", id: 5, result: {} })}\n\n`,
        { headers: { "content-type": "text/event-stream" } }
      ),
      new Response(
        `event: message\ndata: ${JSON.stringify({ jsonrpc: "2.0", method: "notifications/tools/list_changed" })}\n\n`,
        { headers: { "content-type": "text/event-stream" } }
      ),
      new Response(
        `event: message\ndata: ${JSON.stringify([{ jsonrpc: "2.0", id: 8, result: {} }])}\n\n`,
        { headers: { "content-type": "text/event-stream" } }
      ),
      new Response("event: message\ndata: not-json\n\n", {
        headers: { "content-type": "text/event-stream" }
      }),
      new Response(null, { headers: { "content-type": "text/event-stream" } })
    ]
    const fetchMock = vi.fn<typeof fetch>(async () => responses.shift()!)
    vi.stubGlobal("fetch", fetchMock)
    const errors = vi.spyOn(console, "error").mockImplementation(() => undefined)
    const transport = new NodeStreamableHttpTransport(
      new URL("https://example.test/mcp"),
      "access-token",
      { "X-Workspace": "emojis" }
    )
    const messages: unknown[] = []
    let closed = false
    transport.onmessage = (message) => messages.push(message)
    transport.onclose = () => {
      closed = true
    }
    transport.setProtocolVersion("2025-11-25")
    await transport.start()
    await expect(transport.start()).rejects.toThrow("already started")
    await transport.send({ jsonrpc: "2.0", id: 1, method: "ping" })
    await transport.send({ jsonrpc: "2.0", method: "notifications/initialized" })
    await expect(transport.send({ jsonrpc: "2.0", id: 3, method: "ping" })).rejects.toThrow(
      "Streamable HTTP error 500: upstream failed"
    )
    await expect(transport.send({ jsonrpc: "2.0", id: 4, method: "ping" })).rejects.toThrow(
      "Unexpected MCP response content type"
    )
    await expect(transport.send({ jsonrpc: "2.0", id: 4.5, method: "ping" })).rejects.toThrow(
      "Unexpected MCP response content type"
    )
    await transport.send({ jsonrpc: "2.0", id: 5, method: "ping" })
    await transport.send({ jsonrpc: "2.0", method: "notifications/initialized" })
    await transport.send({ jsonrpc: "2.0", id: 8, method: "ping" })
    await transport.send({ jsonrpc: "2.0", id: 9, method: "ping" })
    await transport.send({ jsonrpc: "2.0", id: 10, method: "ping" })
    expect(messages).toHaveLength(5)
    expect(errors).toHaveBeenCalledWith(expect.stringContaining("Unable to decode MCP SSE event"))
    const firstHeaders = fetchMock.mock.calls[0]?.[1]?.headers as Headers
    expect(firstHeaders.get("authorization")).toBe("Bearer access-token")
    expect(firstHeaders.get("mcp-protocol-version")).toBe("2025-11-25")
    expect(firstHeaders.get("x-workspace")).toBe("emojis")
    expect(
      ((fetchMock.mock.calls[1]?.[1]?.headers as Headers) ?? new Headers()).get("mcp-session-id")
    ).toBe("session-1")
    await transport.close()
    expect(closed).toBe(true)

    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response(null, { status: 202 }))
    )
    await new NodeStreamableHttpTransport(new URL("https://example.test/mcp")).send({
      jsonrpc: "2.0",
      method: "notifications/initialized"
    })
  })

  it("connects a working upstream and exposes its tools through every gateway surface", async () => {
    const upstream = await workingUpstream()
    const { db, manager } = await testManager()
    const gatewayBase = await listen(createServer(manager.handleGatewayRequest))
    manager.setBaseUrl(gatewayBase)

    const created = await manager.create({
      authType: "none",
      enabled: true,
      headers: { "X-Workspace": "emojis" },
      name: "Project Tracker",
      transport: "http",
      url: upstream.url
    })
    expect(created).toMatchObject({
      connectionState: "connected",
      enabled: true,
      headerNames: ["X-Workspace"],
      toolCount: 2
    })
    expect(upstream.requests.some((request) => request.headers["x-workspace"] === "emojis")).toBe(
      true
    )
    expect((await manager.list()).map((server) => server.id)).toEqual([created.id])
    expect(await manager.tools(created.id)).toHaveLength(2)
    expect(await manager.tools()).toHaveLength(2)

    const project = await run(db.createProject({ folderPath: "/tmp/mcp-manager-project" }))
    const session = await run(
      db.createSession({ harnessId: "codex", projectId: project.id, title: "Gateway" })
    )
    expect((await manager.setProjectEnabled(project.id, created.id, true))[0]?.enabled).toBe(true)
    expect(
      (await manager.setSessionEnabled(session.id, created.id, true, project.id))[0]?.enabled
    ).toBe(true)

    const issued = await manager.issueGateway(session.id, project.id)
    expect(
      await fetch(`${gatewayBase}/mcp/gateway?gateway=missing`, {
        method: "POST",
        headers: { authorization: `Bearer ${issued.bearerToken}` }
      }).then((response) => response.status)
    ).toBe(404)
    expect(
      await fetch(`${gatewayBase}/mcp/gateway`, {
        method: "POST",
        headers: { authorization: `Bearer ${"x".repeat(issued.bearerToken.length)}` }
      }).then((response) => response.status)
    ).toBe(401)
    const client = new Client({ name: "manager-test", version: "1" })
    await client.connect(
      new StreamableHTTPClientTransport(new URL(issued.url), {
        requestInit: { headers: { authorization: `Bearer ${issued.bearerToken}` } }
      }) as unknown as Transport
    )
    try {
      const search = await client.callTool({
        name: "search",
        arguments: { query: "project", limit: 1 }
      })
      expect(JSON.stringify(search.content)).toContain("lookup_project")

      const described = await client.callTool({
        name: "describe",
        arguments: { server: created.id, tool: "lookup_project" }
      })
      expect(JSON.stringify(described.content)).toContain("Find a project")
      expect(
        (
          await client.callTool({
            name: "describe",
            arguments: { server: created.id, tool: "missing_tool" }
          })
        ).isError
      ).toBe(true)

      const executed = await client.callTool({
        name: "execute",
        arguments: { server: created.id, tool: "lookup_project", arguments: { name: "Rails" } }
      })
      expect(executed.isError).not.toBe(true)

      const codeResult = await client.callTool({
        name: "run_code",
        arguments: {
          code: `async () => {
            const matches = await tools.search({ query: "issues", limit: 1 });
            const schema = await tools.describe.tool({ path: matches.items[0].path });
            const called = await tools[matches.items[0].path]({});
            return { called, schema };
          }`
        }
      })
      expect(codeResult.isError).not.toBe(true)
      expect(JSON.stringify(codeResult.content)).toContain("list_issues")
      for (const code of [
        `async () => tools.describe.tool({})`,
        `async () => tools.describe.tool("invalid")`,
        `async () => tools.describe.tool({ path: "invalid" })`,
        `async () => tools.describe.tool({ path: "${created.id}.missing_tool" })`,
        `async () => tools["invalid"]({})`
      ]) {
        expect((await client.callTool({ name: "run_code", arguments: { code } })).isError).toBe(
          true
        )
      }
      for (const code of [
        `async () => tools.search("issues")`,
        `async () => tools.search({ query: 42, limit: "many" })`,
        `async () => tools["${created.id}.lookup_project"]("primitive")`
      ]) {
        expect((await client.callTool({ name: "run_code", arguments: { code } })).isError).not.toBe(
          true
        )
      }

      await manager.setSessionEnabled(session.id, created.id, false, project.id)
      expect(
        (
          await client.callTool({
            name: "describe",
            arguments: { server: created.id, tool: "lookup_project" }
          })
        ).isError
      ).toBe(true)
      expect(
        (
          await client.callTool({
            name: "run_code",
            arguments: {
              code: `async () => tools.describe.tool({ path: "${created.id}.lookup_project" })`
            }
          })
        ).isError
      ).toBe(true)
      expect(
        (
          await client.callTool({
            name: "execute",
            arguments: { server: created.id, tool: "lookup_project", arguments: {} }
          })
        ).isError
      ).toBe(true)
      expect(
        (
          await client.callTool({
            name: "run_code",
            arguments: { code: `async () => tools["${created.id}.lookup_project"]({})` }
          })
        ).isError
      ).toBe(true)
    } finally {
      await client.close()
    }
    expect(upstream.calls).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ name: "lookup_project", arguments: { name: "Rails" } }),
        expect.objectContaining({ name: "list_issues" })
      ])
    )

    const updated = await manager.update(created.id, {
      enabled: false,
      headers: { Authorization: "Bearer replacement" },
      name: "Renamed Tracker",
      removeHeaders: ["X-Workspace"]
    })
    expect(updated).toMatchObject({
      enabled: false,
      headerNames: ["Authorization"],
      name: "Renamed Tracker"
    })
    await expect(manager.tools(created.id)).rejects.toThrow("is disabled")
    expect(
      (
        await manager.update(created.id, {
          args: ["unused"],
          bearerToken: "replacement-token",
          headers: { "X-Only": "value" },
          oauthClientId: "client-id",
          oauthScope: "project:read"
        })
      ).headerNames
    ).toEqual(["Authorization", "X-Only"])
    expect(
      (
        await manager.update(created.id, {
          authType: "oauth",
          enabled: true,
          oauthClientSecret: "client-secret",
          removeHeaders: ["Authorization", "X-Only"]
        })
      ).connectionState
    ).toBe("needsAuthorization")
    await manager.update(created.id, { authType: "none", enabled: false })
    await manager.remove(created.id)
    expect(await manager.list()).toEqual([])
  })

  it("rejects transport-specific configuration before persisting it", async () => {
    const { db, manager } = await testManager()
    const create = (overrides: Record<string, unknown>) =>
      manager.create({ name: "Invalid", transport: "stdio", command: "mcp", ...overrides })

    await expect(create({ command: undefined })).rejects.toThrow("requires a command")
    await expect(create({ command: " " })).rejects.toThrow("requires a command")
    await expect(create({ headers: { Authorization: "secret" } })).rejects.toThrow(
      "only supported for HTTP"
    )
    await expect(create({ authType: "oauth" })).rejects.toThrow(
      "Authorization is only supported for HTTP"
    )
    await expect(create({ bearerToken: "secret" })).rejects.toThrow(
      "Authorization credentials are only supported for HTTP"
    )
    await expect(manager.create({ name: "Invalid", transport: "http" })).rejects.toThrow(
      "requires a URL"
    )
    await expect(
      manager.create({ name: "Invalid", transport: "http", url: "file:///tmp/mcp" })
    ).rejects.toThrow("must use HTTP or HTTPS")
    await expect(
      manager.create({ name: "Invalid", transport: "http", url: "https://example.test", env: {} })
    ).rejects.toThrow("only supported for stdio")
    await expect(manager.connect("missing-mcp")).rejects.toThrow("MCP server not found")

    vi.stubGlobal(
      "fetch",
      vi.fn(async () => new Response("{}", { headers: { "content-type": "application/json" } }))
    )
    expect((await manager.detectAuth("https://mcp.api")).suggestedName).toBe("Mcp")

    const oauthConfigured = await manager.create({
      authType: "oauth",
      name: "OAuth configured",
      oauthClientId: "client-id",
      oauthClientSecret: "client-secret",
      oauthScope: "read",
      transport: "http",
      url: "https://example.test/mcp"
    })
    expect(oauthConfigured).toMatchObject({
      authType: "oauth",
      connectionState: "needsAuthorization",
      enabled: false,
      oauthScope: "read"
    })
    await manager.remove(oauthConfigured.id)

    const disconnected = await manager.create({
      authType: "none",
      command: "herdman-missing-mcp",
      enabled: false,
      name: "Disconnected",
      transport: "stdio"
    })
    const failed = await manager.update(disconnected.id, { enabled: true })
    expect(failed.connectionState).toBe("error")

    await run(
      db.saveMcpServer({
        authType: "none",
        connectionState: "disconnected",
        enabled: false,
        name: "No secrets",
        toolCount: 0,
        transport: "stdio"
      })
    )
    expect((await manager.list()).some((server) => server.name === "No secrets")).toBe(true)

    const invalidKeyDirectory = mkdtempSync(join(tmpdir(), "herdman-invalid-mcp-key-"))
    directories.push(invalidKeyDirectory)
    writeFileSync(join(invalidKeyDirectory, "mcp-secret-key"), "short")
    expect(() => makeMcpManager({ db, dataDir: invalidKeyDirectory })).toThrow(
      "Invalid MCP secret key"
    )

    vi.stubEnv("HERDMAN_MCP_SECRET_KEY", "invalid")
    expect(() => makeMcpManager({ db, dataDir: invalidKeyDirectory })).toThrow("must be 32 bytes")
    vi.stubEnv("HERDMAN_MCP_SECRET_KEY", Buffer.alloc(32, 7).toString("base64"))
    const configuredKeyDirectory = join(invalidKeyDirectory, "configured")
    mkdirSync(configuredKeyDirectory)
    const configuredDb = await run(
      makeDatabase({
        filename: join(configuredKeyDirectory, "herdman.sqlite"),
        serverId: "configured-key"
      })
    )
    databases.push(configuredDb)
    const configuredManager = makeMcpManager({ db: configuredDb, dataDir: configuredKeyDirectory })
    managers.push(configuredManager)
    expect(await configuredManager.list()).toBeDefined()

    await run(
      db.saveMcpServer({
        authType: "none",
        connectionState: "disconnected",
        enabled: false,
        name: "Invalid secrets",
        secretCipher: "bad",
        toolCount: 0,
        transport: "stdio"
      })
    )
    await expect(manager.list()).rejects.toThrow("Invalid encrypted MCP credentials")
  })
})
