import { createServer } from "node:http"

import { Client } from "@modelcontextprotocol/sdk/client/index.js"
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js"
import { ToolListChangedNotificationSchema } from "@modelcontextprotocol/sdk/types.js"
import { afterEach, describe, expect, it } from "vitest"

import {
  unavailableBrowserProvider,
  unavailableComputerProvider
} from "./mcp-automation-builtins.js"
import {
  cleanupMcpManagerTests,
  executeResultValue,
  listen,
  managers,
  run,
  testManager,
  TEST_BASE_URL
} from "./mcp-manager-test-support.js"
import { makeMcpManager } from "./mcp-manager.js"
import { sdkTransport } from "./mcp-support.js"

afterEach(cleanupMcpManagerTests)

const providers = {
  makeBrowserProvider: () => unavailableBrowserProvider("Not used in this test"),
  makeComputerProvider: () => unavailableComputerProvider("Not used in this test")
}

describe("Codevisor built-in tools", () => {
  it("offers bot tools only to a bot's own session, and messages.send only when it converses", async () => {
    const { db, manager } = await testManager(providers)
    manager.setBaseUrl(await listen(createServer(manager.handleGatewayRequest)))
    const project = await run(db.createProject({ folderPath: "/tmp/mcp-bot-home" }))
    for (const [id, conversational] of [
      ["chatty", true],
      ["plain", false]
    ] as const) {
      await run(
        db.createWorkspaceWithSession({
          workspace: { id: `ws-${id}`, projectId: project.id, name: id, hasCustomName: false },
          session: { id: `chat-${id}`, projectId: project.id, harnessId: "codex", title: id }
        })
      )
      await run(
        db.createBot({
          id: `bot-${id}`,
          name: id,
          symbolName: "sparkles",
          slug: id,
          projectId: project.id,
          sessionId: `chat-${id}`,
          workspaceId: `ws-${id}`,
          mode: conversational ? "conversation" : "transcript",
          projects: []
        })
      )
    }
    const agent = await run(
      db.createSession({ harnessId: "codex", projectId: project.id, title: "Agent" })
    )
    const view = async (sessionId: string) => {
      const issued = await manager.issueGateway(sessionId, project.id)
      const client = new Client({ name: "bot-tools-test", version: "1" })
      await client.connect(
        sdkTransport(
          new StreamableHTTPClientTransport(new URL(issued.url), {
            requestInit: { headers: { authorization: `Bearer ${issued.bearerToken}` } }
          })
        )
      )
      const describes = async (path: string) =>
        (
          await client.callTool({
            name: "execute",
            arguments: {
              description: "Describe a bot tool",
              code: `async () => machines.current.tools.describe.tool({ path: ${JSON.stringify(path)} })`
            }
          })
        ).isError !== true
      try {
        const skills = (await client.listTools()).tools.find((tool) => tool.name === "skills")
        return {
          skill: skills?.description?.includes("- codevisor-messages — ") === true,
          send: await describes("codevisor.messages.send"),
          add: await describes("codevisor.bot.projects_add"),
          remove: await describes("codevisor.bot.projects_remove")
        }
      } finally {
        await client.close()
      }
    }

    expect(await view("chat-chatty")).toEqual({ skill: true, send: true, add: true, remove: true })
    expect(await view("chat-plain")).toEqual({ skill: false, send: false, add: true, remove: true })
    expect(await view(agent.id)).toEqual({ skill: false, send: false, add: false, remove: false })
  })

  it("still finds plugin tools by their old mcps.* names", async () => {
    const { db, manager } = await testManager(providers)
    manager.setBaseUrl(await listen(createServer(manager.handleGatewayRequest)))
    const project = await run(db.createProject({ folderPath: "/tmp/mcp-legacy-names" }))
    const agent = await run(
      db.createSession({ harnessId: "codex", projectId: project.id, title: "Agent" })
    )
    const issued = await manager.issueGateway(agent.id, project.id)
    const client = new Client({ name: "legacy-names-test", version: "1" })
    await client.connect(
      sdkTransport(
        new StreamableHTTPClientTransport(new URL(issued.url), {
          requestInit: { headers: { authorization: `Bearer ${issued.bearerToken}` } }
        })
      )
    )
    const describedName = async (path: string) =>
      executeResultValue(
        await client.callTool({
          name: "execute",
          arguments: {
            description: "Describe a tool by its old name",
            code: `async () => (await machines.current.tools.describe.tool({ path: ${JSON.stringify(path)} })).name`
          }
        })
      )

    try {
      expect(await describedName("codevisor.mcps.list")).toBe("plugins.list")
      expect(await describedName("codevisor.mcps.create")).toBe("plugins.add_custom")
    } finally {
      await client.close()
    }
  })

  it("lists its tools in settings and preserves a disabled provider across restarts", async () => {
    const { db, manager, directory } = await testManager(providers)
    const tools = await manager.tools("codevisor")
    expect(tools).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ serverId: "codevisor", name: "agents.start" })
      ])
    )
    expect((await manager.list()).find((server) => server.id === "codevisor")).toMatchObject({
      name: "Codevisor",
      kind: "codevisor",
      enabled: true,
      connectionState: "connected",
      canEdit: false,
      canRemove: false,
      toolCount: tools.length
    })
    const catalog = (await manager.tools(undefined)).filter((tool) => tool.serverId === "codevisor")
    expect(catalog).toHaveLength(tools.length)
    expect(new Set(catalog.map((tool) => tool.name)).size).toBe(tools.length)

    await manager.update("codevisor", { enabled: false })
    await manager.close()
    const restarted = makeMcpManager({
      db,
      dataDir: directory,
      baseUrl: TEST_BASE_URL,
      ...providers
    })
    managers.push(restarted)
    expect((await restarted.list()).find((server) => server.id === "codevisor")).toMatchObject({
      enabled: false,
      connectionState: "disconnected",
      toolCount: tools.length
    })
    expect((await restarted.tools(undefined)).some((tool) => tool.serverId === "codevisor")).toBe(
      false
    )
    expect(await restarted.tools("codevisor")).toEqual(tools)
    expect(await restarted.update("codevisor", { enabled: true })).toMatchObject({
      enabled: true,
      connectionState: "connected"
    })
  })

  it("finds skills and sandbox globals next to tools in search", async () => {
    const { db, manager } = await testManager(providers)
    manager.setBaseUrl(await listen(createServer(manager.handleGatewayRequest)))
    const project = await run(db.createProject({ folderPath: "/tmp/codevisor-search-test" }))
    const session = await run(db.createSession({ harnessId: "codex", projectId: project.id }))
    const gateway = await manager.issueGateway(session.id, project.id)
    const client = new Client({ name: "codevisor-search-test", version: "1" })
    try {
      await client.connect(
        sdkTransport(
          new StreamableHTTPClientTransport(new URL(gateway.url), {
            requestInit: { headers: { authorization: `Bearer ${gateway.bearerToken}` } }
          })
        )
      )
      const searched = await client.callTool({
        name: "execute",
        arguments: {
          description: "Search for agent tooling",
          code: 'async () => (await machines.current.tools.search({ query: "start agents", limit: 50 })).items.map((item) => item.kind + ":" + (item.path ?? item.name))'
        }
      })

      const found = executeResultValue(searched)
      expect(found).toEqual(
        expect.arrayContaining([
          "tool:codevisor.agents.start",
          "skill:codevisor-agents",
          "global:machine.agents"
        ])
      )
    } finally {
      await client.close()
    }
  })

  it.each(["global", "machine", "project", "session"] as const)(
    "enforces a %s disable in discovery, descriptions, and direct calls on a live gateway",
    async (scope) => {
      const { db, manager } = await testManager(providers)
      const base = await listen(createServer(manager.handleGatewayRequest))
      manager.setBaseUrl(base)
      const project = await run(db.createProject({ folderPath: "/tmp/codevisor-toggle-test" }))
      const session = await run(db.createSession({ harnessId: "codex", projectId: project.id }))
      const gateway = await manager.issueGateway(session.id, project.id)
      const client = new Client({ name: "codevisor-toggle-test", version: "1" })
      try {
        await client.connect(
          sdkTransport(
            new StreamableHTTPClientTransport(new URL(gateway.url), {
              requestInit: { headers: { authorization: `Bearer ${gateway.bearerToken}` } }
            })
          )
        )
        const execute = (code: string) =>
          client.callTool({ name: "execute", arguments: { description: "Run test code", code } })
        const search = () =>
          execute('async () => machines.current.tools.search({ query: "agents.start" })')
        const describeTool = () =>
          execute(
            'async () => machines.current.tools.describe.tool({ path: "codevisor.agents.start" })'
          )
        const call = () =>
          execute('async () => machines.current.tools["codevisor.context.current"]({})')
        const inventory = async () => (await client.listTools()).tools[0]?.description
        const setEnabled = async (enabled: boolean) => {
          const changed = Promise.withResolvers<void>()
          client.setNotificationHandler(ToolListChangedNotificationSchema, () => changed.resolve())
          switch (scope) {
            case "global":
              await manager.update("codevisor", { enabled })
              break
            case "machine":
              await manager.setLocalSuppression(new Set(enabled ? [] : ["Codevisor"]))
              break
            case "project":
              await manager.setProjectEnabled(project.id, "codevisor", enabled)
              break
            case "session":
              await manager.setSessionEnabled(session.id, "codevisor", enabled, project.id)
              break
          }
          await changed.promise
        }

        expect(await inventory()).toContain("\n- Codevisor")
        expect(JSON.stringify((await search()).content)).toContain("codevisor.agents.start")
        expect((await describeTool()).isError).not.toBe(true)
        expect((await call()).isError).not.toBe(true)

        await setEnabled(false)
        expect(await inventory()).not.toContain("\n- Codevisor")
        expect(JSON.stringify((await search()).content)).not.toContain("codevisor.agents.start")
        expect((await describeTool()).isError).toBe(true)
        expect(await call()).toMatchObject({
          isError: true,
          content: [
            expect.objectContaining({ text: expect.stringContaining("disabled for this session") })
          ]
        })

        await setEnabled(true)
        expect(await inventory()).toContain("\n- Codevisor")
        expect(JSON.stringify((await search()).content)).toContain("codevisor.agents.start")
        expect((await describeTool()).isError).not.toBe(true)
        expect((await call()).isError).not.toBe(true)
      } finally {
        await client.close()
      }
    }
  )
})
