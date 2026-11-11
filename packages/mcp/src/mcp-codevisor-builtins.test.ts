import { createServer } from "node:http"

import { Client, StreamableHTTPClientTransport } from "@modelcontextprotocol/client"
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

afterEach(cleanupMcpManagerTests)

const providers = {
  makeBrowserProvider: () => unavailableBrowserProvider("Not used in this test"),
  makeComputerProvider: () => unavailableComputerProvider("Not used in this test")
}

describe("Codevisor built-in tools", () => {
  it("offers bot tools and the messages skill only to a bot's own session", async () => {
    const { db, manager } = await testManager(providers)
    manager.setBaseUrl(await listen(createServer(manager.handleGatewayRequest)))
    const project = await run(db.createProject({ folderPath: "/tmp/mcp-bot-home" }))
    await run(
      db.createWorkspaceWithSession({
        workspace: { id: "ws-bot", projectId: project.id, name: "bot", hasCustomName: false },
        session: { id: "chat-bot", projectId: project.id, harnessId: "codex", title: "bot" }
      })
    )
    await run(
      db.createBot({
        id: "bot-1",
        name: "bot",
        symbolName: "sparkles",
        mascot: { color: "mint", hat: "none", eyewear: "none" },
        slug: "bot",
        projectId: project.id,
        sessionId: "chat-bot",
        workspaceId: "ws-bot",
        projects: []
      })
    )
    const agent = await run(
      db.createSession({ harnessId: "codex", projectId: project.id, title: "Agent" })
    )
    const view = async (sessionId: string) => {
      const issued = await manager.issueGateway(sessionId, project.id)
      const client = new Client({ name: "bot-tools-test", version: "1" })
      await client.connect(
        new StreamableHTTPClientTransport(new URL(issued.url), {
          requestInit: { headers: { authorization: `Bearer ${issued.bearerToken}` } }
        })
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
          list: await describes("codevisor.messages.list"),
          add: await describes("codevisor.bot.projects_add"),
          remove: await describes("codevisor.bot.projects_remove")
        }
      } finally {
        await client.close()
      }
    }

    expect(await view("chat-bot")).toEqual({
      skill: true,
      send: true,
      list: true,
      add: true,
      remove: true
    })
    expect(await view(agent.id)).toEqual({
      skill: false,
      send: false,
      list: false,
      add: false,
      remove: false
    })
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
      new StreamableHTTPClientTransport(new URL(issued.url), {
        requestInit: { headers: { authorization: `Bearer ${issued.bearerToken}` } }
      })
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

  it("lists its tools in settings and turns back on when an older version left it off", async () => {
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

    await manager.close()
    await run(
      db.saveMcpServer({
        id: "codevisor",
        name: "Codevisor",
        kind: "codevisor",
        transport: "stdio",
        enabled: false,
        authType: "none",
        connectionState: "disconnected",
        toolCount: tools.length
      })
    )
    const restarted = makeMcpManager({
      db,
      dataDir: directory,
      baseUrl: TEST_BASE_URL,
      ...providers
    })
    managers.push(restarted)
    expect((await restarted.list()).find((server) => server.id === "codevisor")).toMatchObject({
      enabled: true,
      connectionState: "connected",
      toolCount: tools.length
    })
    expect(
      (await restarted.tools(undefined)).filter((tool) => tool.serverId === "codevisor")
    ).toHaveLength(tools.length)
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
        new StreamableHTTPClientTransport(new URL(gateway.url), {
          requestInit: { headers: { authorization: `Bearer ${gateway.bearerToken}` } }
        })
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
        expect.arrayContaining(["tool:agents.start", "skill:codevisor-agents", "global:agents"])
      )
    } finally {
      await client.close()
    }
  })

  it.each(["global", "machine", "project", "session"] as const)(
    "keeps its tools on a live gateway when a %s disable is attempted",
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
          new StreamableHTTPClientTransport(new URL(gateway.url), {
            requestInit: { headers: { authorization: `Bearer ${gateway.bearerToken}` } }
          })
        )
        const execute = (code: string) =>
          client.callTool({ name: "execute", arguments: { description: "Run test code", code } })
        const search = async () =>
          executeResultValue(
            await execute(
              'async () => (await machines.current.tools.search({ query: "agents.start" })).items.map((item) => item.path ?? item.name)'
            )
          )
        const describeTool = () =>
          execute('async () => machines.current.tools.describe.tool({ path: "agents.start" })')
        const call = () => execute("async () => context.current()")
        const inventory = async () => (await client.listTools()).tools[0]?.description
        const attemptDisable = async () => {
          switch (scope) {
            case "global":
              return manager.update("codevisor", { enabled: false })
            case "machine":
              return manager.setLocalSuppression(new Set(["Codevisor"]))
            case "project":
              return manager.setProjectEnabled(project.id, "codevisor", false)
            case "session":
              return manager.setSessionEnabled(session.id, "codevisor", false, project.id)
          }
        }

        if (scope === "machine") await attemptDisable()
        else await expect(attemptDisable()).rejects.toThrow("Codevisor can’t be turned off")

        expect(await inventory()).toContain("\n- Codevisor")
        expect(await search()).toContain("agents.start")
        expect((await describeTool()).isError).not.toBe(true)
        expect((await call()).isError).not.toBe(true)
      } finally {
        await client.close()
      }
    }
  )
})
