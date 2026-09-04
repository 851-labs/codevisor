import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js"
import type { Transport } from "@modelcontextprotocol/sdk/shared/transport.js"
import { createServer } from "node:http"
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { automationSkillPath, NodeStreamableHttpTransport } from "./mcp-manager.js"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  cleanupMcpManagerTests,
  run,
  directories,
  listen,
  testManager,
  workingUpstream
} from "./mcp-manager-test-support.js"

afterEach(cleanupMcpManagerTests)

describe("MCP manager", () => {
  it("finds managed skills from a packaged runtime launched outside its directory", () => {
    const root = mkdtempSync(join(tmpdir(), "codevisor-packaged-skills-"))
    directories.push(root)
    const runtime = join(root, "darwin-arm64")
    const browserSkill = join(
      runtime,
      "packages",
      "automation",
      "resources",
      "automation-skills",
      "browser-use",
      "SKILL.md"
    )
    mkdirSync(join(browserSkill, ".."), { recursive: true })
    writeFileSync(browserSkill, "# Browser Use")

    expect(
      automationSkillPath("browser", {
        moduleDirectory: join(runtime, "packages", "automation", "dist"),
        workingDirectory: "/"
      })
    ).toBe(browserSkill)
  })

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

  // Spawns a real stdio upstream plus an HTTP gateway — comfortably fast on
  // dev machines but past the 5s default on slower CI runners.

  it(
    "connects a working upstream and exposes its tools through execute",
    { timeout: 20_000 },
    async () => {
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
      expect((await manager.list()).map((server) => server.id)).toEqual([
        "browser",
        "computer",
        created.id
      ])
      expect(await manager.list()).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ id: "browser", kind: "browserUse", canRemove: false }),
          expect.objectContaining({ id: "computer", kind: "computerUse", canEdit: false })
        ])
      )
      expect(await manager.tools(created.id)).toHaveLength(2)
      expect(await manager.tools()).toEqual(
        expect.arrayContaining([
          expect.objectContaining({ serverId: "browser", name: "snapshot" }),
          expect.objectContaining({ serverId: "computer", name: "get_app_state" }),
          expect.objectContaining({ serverId: created.id, name: "lookup_project" })
        ])
      )

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
        expect(client.getInstructions()).toBeUndefined()

        const codeResult = await client.callTool({
          name: "execute",
          arguments: {
            code: `async () => {
            const matches = await tools.search({ query: "project", limit: 1 });
            const schema = await tools.describe.tool({ path: matches.items[0].path });
            const called = await tools[matches.items[0].path]({ name: "Rails" });
            const issues = await tools.search({ query: "issues", limit: 1 });
            const issueCall = await tools[issues.items[0].path]({});
            return { called, issueCall, schema };
          }`
          }
        })
        expect(codeResult.isError).not.toBe(true)
        expect(JSON.stringify(codeResult.content)).toContain("Find a project")
        expect(JSON.stringify(codeResult.content)).toContain("list_issues")
        const binaryCodeResult = await client.callTool({
          name: "execute",
          arguments: {
            code: `async () => tools["${created.id}.lookup_project"]({ binary: true })`
          }
        })
        expect(binaryCodeResult.content).toEqual(
          expect.arrayContaining([
            expect.objectContaining({ type: "image", mimeType: "image/png" })
          ])
        )
        const binaryContent = binaryCodeResult.content as Array<{ readonly type: string }>
        expect(JSON.stringify(binaryContent)).toContain("artifact_ref")
        const resultText = (
          binaryCodeResult.content as Array<{ type: string; text?: string }>
        ).find((block) => block.type === "text")?.text
        const artifact = (
          JSON.parse(resultText!) as { result: { artifacts: Array<{ path: string }> } }
        ).result.artifacts[0]!
        expect(artifact.path.endsWith(".png")).toBe(true)
        expect(readFileSync(artifact.path).toString()).toBe("gateway-binary-image")
        expect(resultText).not.toContain("showToUser")
        expect(
          JSON.stringify(binaryContent.filter((block) => block.type === "text"))
        ).not.toContain(Buffer.from("gateway-binary-image").toString("base64"))
        for (const code of [
          `async () => tools.describe.tool({})`,
          `async () => tools.describe.tool("invalid")`,
          `async () => tools.describe.tool({ path: "invalid" })`,
          `async () => tools.describe.tool({ path: "${created.id}.missing_tool" })`,
          `async () => tools["invalid"]({})`
        ]) {
          expect((await client.callTool({ name: "execute", arguments: { code } })).isError).toBe(
            true
          )
        }
        const caughtAutomationError = await client.callTool({
          name: "execute",
          arguments: {
            code: `async () => tools["computer.select_text"]({
            app: "com.apple.Notes",
            element_index: 1,
            text: "story",
            mode: "all"
          }).catch(error => error.message)`
          }
        })
        expect(caughtAutomationError.isError).not.toBe(true)
        expect(JSON.stringify(caughtAutomationError.content)).toContain(
          "computer.select_text does not accept `mode`"
        )
        for (const code of [
          `async () => tools.search("issues")`,
          `async () => tools.search({ query: 42, limit: "many" })`,
          `async () => tools["${created.id}.lookup_project"]("primitive")`
        ]) {
          expect(
            (await client.callTool({ name: "execute", arguments: { code } })).isError
          ).not.toBe(true)
        }

        await manager.setSessionEnabled(session.id, created.id, false, project.id)
        expect(
          (
            await client.callTool({
              name: "execute",
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
      expect((await manager.list()).map((server) => server.id)).toEqual(["browser", "computer"])
    }
  )
})
