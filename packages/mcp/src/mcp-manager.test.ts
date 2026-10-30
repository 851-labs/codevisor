import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { createServer } from "node:http"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js"
import { CallToolResultSchema } from "@modelcontextprotocol/sdk/types.js"
import { afterEach, describe, expect, it } from "vitest"
import { z } from "zod"

import {
  cleanupMcpManagerTests,
  run,
  directories,
  executeResultValue,
  listen,
  testManager,
  workingUpstream
} from "./mcp-manager-test-support.js"
import { automationSkillPath } from "./mcp-manager.js"
import { sdkTransport } from "./mcp-support.js"

afterEach(cleanupMcpManagerTests)

const BinaryArtifactsSchema = z.object({ artifacts: z.array(z.object({ path: z.string() })) })

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

  it("names the catalog entry an installed server came from in its icon sources", async () => {
    const { manager } = await testManager()

    const created = await manager.create({
      authType: "none",
      enabled: false,
      name: "Linear",
      transport: "http",
      url: "https://mcp.linear.app/mcp",
      catalogId: "app.linear/linear"
    })

    expect(await manager.iconSources(created.id)).toEqual({
      url: "https://mcp.linear.app/mcp",
      catalogId: "app.linear/linear"
    })
  })

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
        "codevisor",
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
      expect(await manager.iconSources(created.id)).toEqual({
        url: upstream.url,
        icons: [{ src: "https://tracker.example/icon.png", sizes: ["64x64"] }],
        websiteUrl: "https://tracker.example"
      })
      expect(await manager.iconSources("missing")).toBeUndefined()
      expect(await manager.iconSources("browser")).toEqual({})
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
        sdkTransport(
          new StreamableHTTPClientTransport(new URL(issued.url), {
            requestInit: { headers: { authorization: `Bearer ${issued.bearerToken}` } }
          })
        )
      )
      try {
        expect(client.getInstructions()).toBeUndefined()

        const codeResult = await client.callTool({
          name: "execute",
          arguments: {
            description: "Run test code",
            code: `async () => {
            const matches = await machines.current.tools.search({ query: "project", limit: 1 });
            const schema = await machines.current.tools.describe.tool({ path: matches.items[0].path });
            const called = await machines.current.tools[matches.items[0].path]({ name: "Rails" });
            const issues = await machines.current.tools.search({ query: "issues", limit: 1 });
            const issueCall = await machines.current.tools[issues.items[0].path]({});
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
            description: "Run test code",
            code: `async () => machines.current.tools["${created.id}.lookup_project"]({ binary: true })`
          }
        })
        expect(binaryCodeResult.content).toEqual(
          expect.arrayContaining([
            expect.objectContaining({ type: "image", mimeType: "image/png" })
          ])
        )
        const binaryContent = CallToolResultSchema.parse(binaryCodeResult).content
        expect(JSON.stringify(binaryContent)).toContain("artifact_ref")
        const artifact = BinaryArtifactsSchema.parse(executeResultValue(binaryCodeResult))
          .artifacts[0]!
        expect(artifact.path.endsWith(".png")).toBe(true)
        expect(readFileSync(artifact.path).toString()).toBe("gateway-binary-image")
        const textBlocks = JSON.stringify(binaryContent.filter((block) => block.type === "text"))
        expect(textBlocks).not.toContain("showToUser")
        expect(textBlocks).not.toContain(Buffer.from("gateway-binary-image").toString("base64"))
        for (const code of [
          `async () => machines.current.tools.describe.tool({})`,
          `async () => machines.current.tools.describe.tool("invalid")`,
          `async () => machines.current.tools.describe.tool({ path: "invalid" })`,
          `async () => machines.current.tools.describe.tool({ path: "${created.id}.missing_tool" })`,
          `async () => machines.current.tools["invalid"]({})`
        ]) {
          expect(
            (
              await client.callTool({
                name: "execute",
                arguments: { description: "Run test code", code }
              })
            ).isError
          ).toBe(true)
        }
        const caughtAutomationError = await client.callTool({
          name: "execute",
          arguments: {
            description: "Run test code",
            code: `async () => machines.current.tools["computer.select_text"]({
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
          `async () => machines.current.tools.search("issues")`,
          `async () => machines.current.tools.search({ query: 42, limit: "many" })`,
          `async () => machines.current.tools["${created.id}.lookup_project"]("primitive")`
        ]) {
          expect(
            (
              await client.callTool({
                name: "execute",
                arguments: { description: "Run test code", code }
              })
            ).isError
          ).not.toBe(true)
        }

        await manager.setSessionEnabled(session.id, created.id, false, project.id)
        expect(
          (
            await client.callTool({
              name: "execute",
              arguments: {
                description: "Run test code",
                code: `async () => machines.current.tools.describe.tool({ path: "${created.id}.lookup_project" })`
              }
            })
          ).isError
        ).toBe(true)
        expect(
          (
            await client.callTool({
              name: "execute",
              arguments: {
                description: "Run test code",
                code: `async () => machines.current.tools["${created.id}.lookup_project"]({})`
              }
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
      expect((await manager.list()).map((server) => server.id)).toEqual([
        "browser",
        "codevisor",
        "computer"
      ])
    }
  )
})
