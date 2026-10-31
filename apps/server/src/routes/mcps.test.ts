import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { Client as McpClient } from "@modelcontextprotocol/sdk/client/index.js"
import { ToolListChangedNotificationSchema } from "@modelcontextprotocol/sdk/types.js"
import { describe, expect, it } from "vitest"

import { start, tempDirs } from "../test-support.js"
import { gatewayTransport } from "./gateway-test-support.js"

describe("mcp routes", () => {
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
    await client.connect(gatewayTransport(gateway))
    const listed = await client.listTools()
    expect(listed.tools.map((tool) => tool.name)).toEqual(["execute", "skills"])
    expect(listed.tools.find((tool) => tool.name === "execute")?.description).toContain("PostHog")
    expect(listed.tools.find((tool) => tool.name === "execute")?.description).toContain(
      "Sandboxed TypeScript runtime for using tools like:"
    )
    const toolsChanged = Promise.withResolvers<void>()
    let toolListChanges = 0
    client.setNotificationHandler(ToolListChangedNotificationSchema, () => {
      toolListChanges += 1
      toolsChanged.resolve()
    })
    await services.mcp.create({
      authType: "none",
      command: "codevisor-missing-linear-mcp",
      name: "Linear",
      transport: "stdio"
    })
    await toolsChanged.promise
    expect(toolListChanges).toBeGreaterThan(0)
    expect(
      (await client.listTools()).tools.find((tool) => tool.name === "execute")?.description
    ).toContain("Linear")
    const executed = await client.callTool({
      name: "execute",
      arguments: { description: "Test workflow", code: "async () => 6 * 7" }
    })
    expect(executed.isError).not.toBe(true)
    expect(JSON.stringify(executed.content)).toContain("42")
    const searchedInCode = await client.callTool({
      name: "execute",
      arguments: {
        description: "Test workflow",
        code: 'async () => await machines.current.tools.search({ query: "missing" })'
      }
    })
    expect(searchedInCode.isError).not.toBe(true)
    expect(JSON.stringify(searchedInCode.content)).toContain('\\"total\\":0')
    const codevisorSearch = await client.callTool({
      name: "execute",
      arguments: {
        description: "Test workflow",
        code: 'async () => await machines.current.tools.search({ query: "Codevisor agents list" })'
      }
    })
    expect(codevisorSearch.isError).not.toBe(true)
    expect(JSON.stringify(codevisorSearch.content)).toContain("codevisor.agents.list")
    const codevisorProjects = await client.callTool({
      name: "execute",
      arguments: {
        description: "Test workflow",
        code: 'async () => await machines.current.tools["codevisor.projects.list"]({})'
      }
    })
    expect(codevisorProjects.isError).not.toBe(true)
    expect(JSON.stringify(codevisorProjects.content)).toContain('\\"result\\":{\\"items\\":[]}')
    const controlledFolder = mkdtempSync(join(tmpdir(), "codevisor-mcp-control-"))
    tempDirs.push(controlledFolder)
    const controlled = await client.callTool({
      name: "execute",
      arguments: {
        description: "Test workflow",
        code: `async () => {
          const codevisor = machines.current.tools.codevisor;
          const project = await codevisor.projects.create({
            id: "controlled-project",
            folderPath: ${JSON.stringify(controlledFolder)},
            name: "Controlled"
          });
          const workspace = await codevisor.workspaces.upsert({
            workspaceId: "controlled-workspace",
            projectId: project.projectId,
            name: "Controlled workspace",
            hasCustomName: true
          });
          const listed = await codevisor.projects.list({});
          return { projectId: project.projectId, workspaceId: workspace.workspaceId, listed: listed.items.map((item) => item.projectId) };
        }`
      }
    })
    expect(controlled.isError).not.toBe(true)
    expect(JSON.stringify(controlled.content)).toContain(
      '{\\"projectId\\":\\"controlled-project\\",\\"workspaceId\\":\\"controlled-workspace\\",\\"listed\\":[\\"controlled-project\\"]}'
    )
    const codevisorTools = await services.mcp.tools("codevisor")
    expect(codevisorTools.map((tool) => tool.name)).toEqual(
      expect.arrayContaining([
        "projects.create",
        "workspaces.upsert",
        "agents.start",
        "agents.message",
        "agents.status",
        "agents.debug.search",
        "plugins.add_custom",
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
    await client.connect(gatewayTransport(gateway))
    const result = await client.callTool({
      name: "execute",
      arguments: {
        description: "Test workflow",
        code: 'async () => await machines.current.tools["codevisor.projects.list"]({})'
      }
    })
    expect(result.isError).not.toBe(true)
    expect(JSON.stringify(result.content)).toContain('\\"result\\":{\\"items\\":[]}')
    await client.close()
  })
})
