import type { McpServer } from "@codevisor/api"
import { createServer } from "node:http"
import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it, vi } from "vitest"
import { boundedMcpTimerDelay, NativeMcpError, NodeStreamableHttpTransport } from "@codevisor/mcp"
import { Client as McpClient } from "@modelcontextprotocol/sdk/client/index.js"
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js"
import type { Transport as McpTransport } from "@modelcontextprotocol/sdk/shared/transport.js"
import { ToolListChangedNotificationSchema } from "@modelcontextprotocol/sdk/types.js"
import {
  jsonRequest,
  makeServices,
  nativeMcpRemoval,
  nativeMcpScan,
  nativeMcpStub,
  run,
  runningServers,
  skillsScan,
  skillsStub,
  start,
  startWithApp,
  tempDirs,
  waitFor
} from "../test-support.js"

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
    expect(listed.tools.map((tool) => tool.name)).toEqual([
      "search",
      "describe",
      "execute",
      "run_code"
    ])
    expect(listed.tools.find((tool) => tool.name === "search")?.description).toContain("PostHog")
    expect(listed.tools.find((tool) => tool.name === "run_code")?.description).toContain("PostHog")
    expect(listed.tools.find((tool) => tool.name === "run_code")?.description).toContain(
      "Primary Codevisor tool interface"
    )
    expect(listed.tools.find((tool) => tool.name === "execute")?.description).toContain(
      "Compatibility wrapper"
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
      (await client.listTools()).tools.find((tool) => tool.name === "search")?.description
    ).toContain("Linear")
    const executed = await client.callTool({
      name: "run_code",
      arguments: { code: "async () => 6 * 7" }
    })
    expect(executed.isError).not.toBe(true)
    expect(JSON.stringify(executed.content)).toContain("42")
    const searchedInCode = await client.callTool({
      name: "run_code",
      arguments: { code: 'async () => await tools.search({ query: "missing" })' }
    })
    expect(searchedInCode.isError).not.toBe(true)
    expect(JSON.stringify(searchedInCode.content)).toContain('\\"total\\":0')
    const codevisorSearch = await client.callTool({
      name: "run_code",
      arguments: { code: 'async () => await tools.search({ query: "Codevisor sessions" })' }
    })
    expect(codevisorSearch.isError).not.toBe(true)
    expect(JSON.stringify(codevisorSearch.content)).toContain("codevisor.sessions.list")
    const codevisorProjects = await client.callTool({
      name: "run_code",
      arguments: { code: 'async () => await tools["codevisor.projects.list"]({})' }
    })
    expect(codevisorProjects.isError).not.toBe(true)
    expect(JSON.stringify(codevisorProjects.content)).toContain('\\"result\\":[]')
    const controlledFolder = mkdtempSync(join(tmpdir(), "codevisor-mcp-control-"))
    tempDirs.push(controlledFolder)
    const controlled = await client.callTool({
      name: "run_code",
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
      name: "run_code",
      arguments: { code: 'async () => await tools["codevisor.projects.list"]({})' }
    })
    expect(result.isError).not.toBe(true)
    expect(JSON.stringify(result.content)).toContain('\\"result\\":[]')
    await client.close()
  })

  it("detects MCP authorization challenges", async () => {
    const detector = createServer((request, response) => {
      if (request.url === "/oauth") {
        response.writeHead(401, {
          "www-authenticate": 'Bearer resource_metadata="https://auth.example.test/resource"'
        })
      } else if (request.url === "/bearer") {
        response.writeHead(401, { "www-authenticate": "Bearer" })
      } else if (request.url === "/metadata") {
        response.writeHead(401)
      } else if (request.url === "/required") {
        response.writeHead(401)
      } else if (request.url === "/.well-known/oauth-protected-resource/metadata") {
        response.writeHead(200, { "content-type": "application/json" })
        response.end(
          JSON.stringify({
            authorization_servers: ["https://auth.example.test"],
            resource: `http://${request.headers.host}/metadata`
          })
        )
        return
      } else if (request.url?.startsWith("/.well-known/")) {
        response.writeHead(404)
      } else {
        response.writeHead(200, { "content-type": "application/json" })
      }
      response.end("{}")
    })
    await new Promise<void>((resolve) => detector.listen(0, "127.0.0.1", resolve))
    const address = detector.address()
    if (address === null || typeof address === "string") throw new Error("Missing detector port")
    const { server } = await start()
    try {
      for (const [path, authType] of [
        ["none", "none"],
        ["bearer", "bearer"],
        ["metadata", "oauth"],
        ["required", "bearer"],
        ["oauth", "oauth"]
      ] as const) {
        const detected = await jsonRequest(server, "/v1/mcps/detect-auth", {
          method: "POST",
          body: JSON.stringify({ url: `http://127.0.0.1:${address.port}/${path}` })
        })
        expect(detected.status).toBe(200)
        expect(detected.body).toMatchObject({ authType })
      }
      const created = await jsonRequest(server, "/v1/mcps", {
        method: "POST",
        body: JSON.stringify({
          enabled: false,
          name: "Auto OAuth",
          transport: "http",
          url: `http://127.0.0.1:${address.port}/oauth`
        })
      })
      expect(created.status).toBe(201)
      expect(created.body).toMatchObject({
        authType: "oauth",
        connectionState: "needsAuthorization",
        enabled: false
      })
    } finally {
      await new Promise<void>((resolve, reject) =>
        detector.close((error) => (error === undefined ? resolve() : reject(error)))
      )
    }
  })

  it("manages MCP installations without returning encrypted credentials", async () => {
    const { agents, server, services } = await start()
    const created = await jsonRequest(server, "/v1/mcps", {
      method: "POST",
      body: JSON.stringify({
        authType: "bearer",
        bearerToken: "secret-token",
        headers: { "X-Workspace": "emojis", Authorization: "secret-header" },
        enabled: false,
        name: "Example",
        transport: "http",
        url: "https://example.test/mcp"
      })
    })
    expect(created.status).toBe(201)
    expect(created.body).toMatchObject({
      authType: "bearer",
      enabled: false,
      name: "Example"
    })
    expect(JSON.stringify(created.body)).not.toContain("secret-token")
    expect(created.body).toMatchObject({ headerNames: ["Authorization", "X-Workspace"] })
    expect(JSON.stringify(created.body)).not.toContain("secret-header")
    expect(JSON.stringify(created.body)).not.toContain("secretCipher")

    const id = (created.body as { id: string }).id
    const updated = await jsonRequest(server, `/v1/mcps/${id}`, {
      method: "PATCH",
      body: JSON.stringify({ name: "Renamed" })
    })
    expect(updated.status).toBe(200)
    expect(updated.body).toMatchObject({ enabled: false, name: "Renamed" })

    const listed = await jsonRequest(server, "/v1/mcps")
    expect(listed.body).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ id, kind: "managed", name: "Renamed" }),
        expect.objectContaining({ id: "browser", canRemove: false, kind: "browserUse" }),
        expect.objectContaining({ id: "computer", canEdit: false, kind: "computerUse" })
      ])
    )
    expect((await jsonRequest(server, "/v1/mcps/browser", { method: "DELETE" })).status).toBe(409)
    expect(
      (
        await jsonRequest(server, "/v1/mcps/computer", {
          method: "PATCH",
          body: JSON.stringify({ name: "Renamed" })
        })
      ).status
    ).toBe(409)
    expect(
      (
        await jsonRequest(server, "/v1/mcps/computer", {
          method: "PATCH",
          body: JSON.stringify({ enabled: false })
        })
      ).status
    ).toBe(200)

    expect((await jsonRequest(server, `/v1/mcps/${id}`, { method: "DELETE" })).status).toBe(204)

    const local = await jsonRequest(server, "/v1/mcps", {
      method: "POST",
      body: JSON.stringify({
        authType: "none",
        command: "missing-local-mcp",
        enabled: false,
        env: { API_KEY: "local-secret", REGION: "us-west" },
        name: "Local",
        transport: "stdio"
      })
    })
    expect(local.status).toBe(201)
    expect(local.body).toMatchObject({ environmentNames: ["API_KEY", "REGION"] })
    expect(JSON.stringify(local.body)).not.toContain("local-secret")
    const localId = (local.body as { id: string }).id
    const changedLocal = await jsonRequest(server, `/v1/mcps/${localId}`, {
      method: "PATCH",
      body: JSON.stringify({ env: { ACCOUNT: "new-secret" }, removeEnv: ["REGION"] })
    })
    expect(changedLocal.body).toMatchObject({ environmentNames: ["ACCOUNT", "API_KEY"] })
    expect(JSON.stringify(changedLocal.body)).not.toContain("new-secret")

    const scopedProjectFolder = mkdtempSync(join(tmpdir(), "codevisor-mcp-route-scope-"))
    tempDirs.push(scopedProjectFolder)
    const project = await run(services.db.createProject({ folderPath: scopedProjectFolder }))
    const session = await run(
      services.db.createSession({ harnessId: "codex", projectId: project.id, title: "Scoped" })
    )
    expect(
      (
        await jsonRequest(server, `/v1/projects/${project.id}/mcps/${localId}`, {
          method: "PATCH",
          body: JSON.stringify({ enabled: false })
        })
      ).status
    ).toBe(200)
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/mcps/${localId}`, {
          method: "PATCH",
          body: JSON.stringify({ enabled: false })
        })
      ).status
    ).toBe(200)
    expect(
      (
        await jsonRequest(server, `/v1/projects/${project.id}/mcps/${localId}`, {
          method: "PATCH",
          body: JSON.stringify({})
        })
      ).status
    ).toBe(400)
    expect(
      (
        await jsonRequest(server, `/v1/sessions/${session.id}/mcps/${localId}`, {
          method: "PATCH",
          body: JSON.stringify({})
        })
      ).status
    ).toBe(400)

    const publicLocal = local.body as McpServer
    vi.spyOn(services.mcp, "connect").mockResolvedValue(publicLocal)
    vi.spyOn(services.mcp, "tools").mockResolvedValue([])
    vi.spyOn(services.mcp, "beginOAuth").mockResolvedValue("https://example.test/authorize")
    vi.spyOn(services.mcp, "disconnectOAuth").mockResolvedValue(publicLocal)
    const finishOAuth = vi.spyOn(services.mcp, "finishOAuth").mockResolvedValue(publicLocal)
    expect((await jsonRequest(server, `/v1/mcps/${localId}/tools`)).status).toBe(200)
    expect(
      (await jsonRequest(server, `/v1/mcps/${localId}/connect`, { method: "POST" })).status
    ).toBe(200)
    expect(
      (await jsonRequest(server, `/v1/mcps/${localId}/oauth-start`, { method: "POST" })).status
    ).toBe(201)
    expect(
      (await jsonRequest(server, `/v1/mcps/${localId}/oauth-disconnect`, { method: "POST" })).status
    ).toBe(200)
    expect(
      (await jsonRequest(server, `/v1/mcps/${localId}/unknown`, { method: "POST" })).status
    ).toBe(404)
    expect((await jsonRequest(server, "/v1/mcps", { method: "PUT" })).status).toBe(404)
    expect((await jsonRequest(server, `/v1/mcps/${localId}`)).status).toBe(404)
    expect(
      await fetch(`${server.url}/v1/mcps/oauth/callback?state=state-1&code=code-1`).then(
        (response) => response.status
      )
    ).toBe(200)
    expect(finishOAuth).toHaveBeenCalledWith("state-1", "code-1")
    expect(
      await fetch(`${server.url}/v1/mcps/oauth/callback?state=state-1`).then(
        (response) => response.status
      )
    ).toBe(400)
    expect(
      await fetch(`${server.url}/v1/mcps/oauth/complete`).then((response) => response.status)
    ).toBe(200)

    expect((await jsonRequest(server, `/v1/mcps/${localId}`, { method: "DELETE" })).status).toBe(
      204
    )
    expect(
      ((await jsonRequest(server, "/v1/mcps")).body as ReadonlyArray<McpServer>).map(
        (candidate) => candidate.id
      )
    ).toEqual(["browser", "computer"])

    const automationAnswer = vi.spyOn(services.mcp, "answerQuestion").mockResolvedValueOnce(true)
    expect(
      (
        await jsonRequest(
          server,
          `/v1/sessions/${session.id}/questions/automation-question/answer`,
          {
            method: "POST",
            body: JSON.stringify({ outcome: "cancelled" })
          }
        )
      ).status
    ).toBe(202)
    expect(automationAnswer).toHaveBeenCalledWith(session.id, "automation-question", {
      outcome: "cancelled"
    })
    expect(agents.questionAnswers).toEqual([])

    const { mcp: _mcp, ...withoutMcp } = services
    const unavailable = await startWithApp(withoutMcp)
    runningServers.push(unavailable)
    expect((await jsonRequest(unavailable, "/v1/mcps")).status).toBe(501)
    expect(
      (
        await jsonRequest(unavailable, `/v1/projects/${project.id}/mcps/${localId}`, {
          method: "PATCH",
          body: JSON.stringify({ enabled: true })
        })
      ).status
    ).toBe(501)
    expect(
      (
        await jsonRequest(unavailable, `/v1/sessions/${session.id}/mcps/${localId}`, {
          method: "PATCH",
          body: JSON.stringify({ enabled: true })
        })
      ).status
    ).toBe(501)
    expect(
      await fetch(`${unavailable.url}/mcp/gateway`, { method: "POST" }).then((r) => r.status)
    ).toBe(501)
    const unavailableAnswer = await jsonRequest(
      unavailable,
      `/v1/sessions/${session.id}/questions/no-mcp-question/answer`,
      {
        method: "POST",
        body: JSON.stringify({ outcome: "cancelled" })
      }
    )
    expect(unavailableAnswer.status, JSON.stringify(unavailableAnswer.body)).toBe(202)
    expect(agents.questionAnswers.at(-1)).toEqual([
      expect.any(String),
      "no-mcp-question",
      { outcome: "cancelled" }
    ])
    expect(
      await fetch(`${unavailable.url}/v1/mcps/oauth/callback?state=x&code=y`).then(
        (response) => response.status
      )
    ).toBe(501)
  })
})

describe("native MCP and skills routes", () => {
  it("serves scans from the configured managers", async () => {
    const { services } = await makeServices("server-a")
    const server = await startWithApp({
      ...services,
      nativeMcp: nativeMcpStub([]),
      skills: skillsStub([])
    })
    runningServers.push(server)

    const nativeResponse = await jsonRequest(server, "/v1/native-mcps")
    expect(nativeResponse.status).toBe(200)
    expect(nativeResponse.body).toEqual(nativeMcpScan)

    const importResponse = await jsonRequest(server, "/v1/native-mcps/import", {
      body: JSON.stringify({ identities: ["docs-mcp"] }),
      method: "POST"
    })
    expect(importResponse.status).toBe(200)
    expect(importResponse.body).toEqual({
      outcomes: [{ identity: "docs-mcp", status: "imported", warnings: [] }],
      scan: nativeMcpScan
    })

    const skillsResponse = await jsonRequest(server, "/v1/skills")
    expect(skillsResponse.status).toBe(200)
    expect(skillsResponse.body).toEqual(skillsScan)

    // Unknown methods and subpaths fall through to 404.
    expect((await jsonRequest(server, "/v1/native-mcps", { method: "POST" })).status).toBe(404)
    expect((await jsonRequest(server, "/v1/native-mcps/unknown")).status).toBe(404)
    expect((await jsonRequest(server, "/v1/skills/unknown")).status).toBe(404)
    expect((await jsonRequest(server, "/v1/skills/unknown", { method: "PATCH" })).status).toBe(404)
    expect((await jsonRequest(server, "/v1/skills", { method: "PATCH" })).status).toBe(404)
  })

  it("routes native MCP destructive operations to the manager", async () => {
    const { services } = await makeServices("server-a")
    const calls: Array<unknown[]> = []
    const server = await startWithApp({ ...services, nativeMcp: nativeMcpStub(calls) })
    runningServers.push(server)

    const removeResponse = await jsonRequest(server, "/v1/native-mcps/remove", {
      body: JSON.stringify({ harnessId: "claude-code", serverName: "docs" }),
      method: "POST"
    })
    expect(removeResponse.status).toBe(200)
    expect(removeResponse.body).toEqual({ removal: nativeMcpRemoval, scan: nativeMcpScan })

    const removalsResponse = await jsonRequest(server, "/v1/native-mcps/removals")
    expect(removalsResponse.status).toBe(200)
    expect(removalsResponse.body).toEqual([nativeMcpRemoval])

    expect(
      (
        await jsonRequest(server, "/v1/native-mcps/removals/removal-1/restore", {
          method: "POST"
        })
      ).status
    ).toBe(200)
    expect(
      (
        await jsonRequest(server, "/v1/native-mcps/removals/removal-1/unknown", {
          method: "POST"
        })
      ).status
    ).toBe(404)

    expect(
      (
        await jsonRequest(server, "/v1/native-mcps/set-enabled", {
          body: JSON.stringify({ enabled: false, harnessId: "opencode", serverName: "local" }),
          method: "POST"
        })
      ).status
    ).toBe(200)

    expect(calls).toEqual([
      ["removeServer", "claude-code", "docs"],
      ["restoreRemoval", "removal-1"],
      ["setNativeEnabled", "opencode", "local", false]
    ])
  })

  it("maps NativeMcpError codes onto HTTP statuses", async () => {
    const { services } = await makeServices("server-a")
    const failing = {
      ...nativeMcpStub([]),
      removeServer: async () => {
        throw new NativeMcpError("can't edit safely", "unsupported")
      },
      restoreRemoval: async () => {
        throw new NativeMcpError("name in use", "conflict")
      },
      setNativeEnabled: async () => {
        throw new NativeMcpError("no such server", "notFound")
      }
    }
    const server = await startWithApp({ ...services, nativeMcp: failing })
    runningServers.push(server)

    const unsupported = await jsonRequest(server, "/v1/native-mcps/remove", {
      body: JSON.stringify({ harnessId: "goose", serverName: "docs" }),
      method: "POST"
    })
    expect(unsupported.status).toBe(422)
    expect(unsupported.body).toEqual({ code: "unsupported", error: "can't edit safely" })
    expect(
      (
        await jsonRequest(server, "/v1/native-mcps/removals/removal-1/restore", {
          method: "POST"
        })
      ).status
    ).toBe(409)
    expect(
      (
        await jsonRequest(server, "/v1/native-mcps/set-enabled", {
          body: JSON.stringify({ enabled: true, harnessId: "opencode", serverName: "ghost" }),
          method: "POST"
        })
      ).status
    ).toBe(404)
  })

  it("returns 501 when the host has no native MCP or skills managers", async () => {
    const { services } = await makeServices("server-a")
    const server = await startWithApp(services)
    runningServers.push(server)
    expect((await jsonRequest(server, "/v1/native-mcps")).status).toBe(501)
    expect((await jsonRequest(server, "/v1/skills")).status).toBe(501)
  })
})
