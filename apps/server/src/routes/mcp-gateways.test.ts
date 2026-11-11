import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { Client as McpClient } from "@modelcontextprotocol/client"
import { describe, expect, it, onTestFinished } from "vitest"

import { run } from "../server-context.js"
import { start, tempDirs } from "../test-support.js"
import { gatewayTransport } from "./gateway-test-support.js"

const openGateway = (url: string, body: unknown) =>
  fetch(`${url}/v1/mcp-gateways`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body)
  })

describe("POST /v1/mcp-gateways", () => {
  it("opens a gateway for an MCP client outside Codevisor, scoped to the project it names", async () => {
    const { server, services } = await start()
    const folder = mkdtempSync(join(tmpdir(), "codevisor-mcp-gateway-project-"))
    tempDirs.push(folder)
    const project = await run(services.db.createProject({ folderPath: folder, name: "Widget" }))

    const opened = await openGateway(server.url, { clientName: "Grok", project: "widget" })
    expect(opened.status).toBe(201)
    const client = new McpClient({ name: "Grok", version: "1" })
    await client.connect(gatewayTransport(await opened.json()))
    onTestFinished(() => client.close())
    const current = await client.callTool({
      name: "execute",
      arguments: {
        description: "Where am I",
        code: "async () => context.current()"
      }
    })

    const [block] = current.content
    expect(block?.type === "text" ? JSON.parse(block.text) : undefined).toMatchObject({
      result: { externalClient: { name: "Grok" }, projectId: project.id }
    })
  })

  it("names the projects it knows when the requested one doesn't exist", async () => {
    const { server, services } = await start()
    const folder = mkdtempSync(join(tmpdir(), "codevisor-mcp-gateway-project-"))
    tempDirs.push(folder)
    await run(services.db.createProject({ folderPath: folder, name: "Widget" }))

    const refused = await openGateway(server.url, { project: "gadget" })

    expect(refused.status).toBe(404)
    expect(await refused.json()).toMatchObject({
      error: "No project named gadget. Projects: Widget"
    })
  })
})
