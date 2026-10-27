import { createServer } from "node:http"

import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js"
import { ToolListChangedNotificationSchema } from "@modelcontextprotocol/sdk/types.js"
import { afterEach, describe, expect, it } from "vitest"

import {
  cleanupMcpManagerTests,
  run,
  listen,
  testManager,
  workingUpstream
} from "./mcp-manager-test-support.js"
import { sdkTransport } from "./mcp-support.js"

afterEach(cleanupMcpManagerTests)

describe("MCP manager gateway", () => {
  it("accepts harness redials: fresh initialize handshakes reuse the same gateway", async () => {
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
      await client.connect(sdkTransport(transport))
      return { client, transport }
    }

    const first = await connect()
    try {
      expect(
        JSON.stringify(
          (
            await first.client.callTool({
              name: "execute",
              arguments: {
                description: "Run test code",
                code: 'async () => machines.current.tools.search({ query: "project" })'
              }
            })
          ).content
        )
      ).toContain("lookup_project")

      const second = await connect()
      try {
        expect(
          JSON.stringify(
            (
              await second.client.callTool({
                name: "execute",
                arguments: {
                  description: "Run test code",
                  code: 'async () => machines.current.tools.search({ query: "issues" })'
                }
              })
            ).content
          )
        ).toContain("list_issues")
        expect(
          (
            await first.client.callTool({
              name: "execute",
              arguments: {
                description: "Run test code",
                code: 'async () => machines.current.tools.search({ query: "project" })'
              }
            })
          ).isError
        ).not.toBe(true)

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
              arguments: {
                description: "Run test code",
                code: 'async () => machines.current.tools.search({ query: "project" })'
              }
            })
          ).isError
        ).not.toBe(true)
      } finally {
        await second.client.close().catch(() => undefined)
      }

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

  it("serves skills next to execute and refreshes them when the store changes", async () => {
    let saved = [{ description: "Ships it", directoryName: "deploy", name: "Deploy" }]
    const listeners: Array<() => void> = []
    const { db, manager } = await testManager({
      packagedSkills: [
        { name: "attaching-files", path: "/missing/SKILL.md", summary: "send files to the user" }
      ],
      skillSource: {
        document: async (directoryName) =>
          directoryName === "deploy"
            ? { content: "---\nname: Deploy\n---\nRun deploy.sh", files: [], path: "/store/deploy" }
            : undefined,
        list: async () => ({ skills: saved }),
        subscribe: (listener) => {
          listeners.push(listener)
          return () => listeners.splice(0)
        }
      }
    })
    manager.setBaseUrl(await listen(createServer(manager.handleGatewayRequest)))
    const project = await run(db.createProject({ folderPath: "/tmp/mcp-skills-project" }))
    const session = await run(
      db.createSession({ harnessId: "claude-code", projectId: project.id, title: "Skills" })
    )
    const issued = await manager.issueGateway(session.id, project.id)
    const client = new Client({ name: "skills-test", version: "1" })
    await client.connect(
      sdkTransport(
        new StreamableHTTPClientTransport(new URL(issued.url), {
          requestInit: { headers: { authorization: `Bearer ${issued.bearerToken}` } }
        })
      )
    )
    try {
      const tools = (await client.listTools()).tools
      expect(tools.map((tool) => tool.name)).toEqual(["execute", "skills"])
      const skills = tools.find((tool) => tool.name === "skills")
      expect(skills?.description).toContain("- browser-use — ")
      expect(skills?.description).toContain("- attaching-files — send files to the user")
      expect(skills?.description).toContain("- deploy — Ships it")
      const read = await client.callTool({ name: "skills", arguments: { name: "deploy" } })
      expect(read.content).toEqual([{ type: "text", text: "Run deploy.sh" }])

      const builtinChanged = Promise.withResolvers<void>()
      client.setNotificationHandler(ToolListChangedNotificationSchema, () => {
        builtinChanged.resolve()
      })
      await manager.update("browser", { enabled: false })
      await builtinChanged.promise
      const withoutBrowser = (await client.listTools()).tools.find((tool) => tool.name === "skills")
      expect(withoutBrowser?.description).not.toContain("browser-use")
      expect(
        (await client.callTool({ name: "skills", arguments: { name: "browser-use" } })).isError
      ).toBe(true)

      const storeChanged = Promise.withResolvers<void>()
      client.setNotificationHandler(ToolListChangedNotificationSchema, () => {
        storeChanged.resolve()
      })
      saved = [...saved, { description: "Reviews code", directoryName: "review", name: "Review" }]
      for (const listener of listeners) listener()
      await storeChanged.promise
      const refreshed = (await client.listTools()).tools.find((tool) => tool.name === "skills")
      expect(refreshed?.description).toContain("- review — Reviews code")
    } finally {
      await client.close()
    }
  })
})
